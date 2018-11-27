(*
 *
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Varstored_interface
open Lwt.Infix

module D = Debug.Make (struct
  let name = "varstored-guard"
end)

let ret v = v >>= Lwt.return_ok |> Rpc_lwt.T.put
let sockets = Hashtbl.create 127

(* caller here is trusted (xenopsd through message-switch *)
let depriv_create dbg vm_uuid gid path =
  if Hashtbl.mem sockets gid
  then
    Lwt.return_error
      (Varstore_privileged_interface.InternalError (Printf.sprintf "GID %d is already in use" gid))
    |> Rpc_lwt.T.put
  else
    ret
    @@
    let vm_uuid_str = Uuidm.to_string vm_uuid in
    D.debug
      "[%s] creating deprivileged socket for VM %s at %s, owned by group %d"
      dbg
      vm_uuid_str
      path
      gid;
    make_server_rpcfn path vm_uuid_str
    >>= fun stop_server ->
    Hashtbl.add sockets gid (stop_server, path);
    Lwt_unix.chmod path 0o660 >>= fun () -> Lwt_unix.chown path 0 gid

let safe_unlink path =
  Lwt.catch
    (fun () -> Lwt_unix.unlink path)
    (function Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit | e -> Lwt.fail e)

let depriv_destroy dbg gid =
  D.debug "[%s] stopping server for gid %d" dbg gid;
  ret
  @@
  match Hashtbl.find_opt sockets gid with
  | None ->
    D.warn "[%s] asked to stop server for gid %d, but it doesn't exist" dbg gid;
    Lwt.return_unit
  | Some (stop_server, path) ->
    let finally () = safe_unlink path >|= fun () -> Hashtbl.remove sockets gid in
    Lwt.finalize stop_server finally
    >>= fun () ->
    D.debug "[%s] stopped server for gid %d and removed socket" dbg gid;
    Lwt.return_unit

let rpc_fn =
  let module Server = Varstore_privileged_interface.RPC_API (Rpc_lwt.GenServer ()) in
  (* bind APIs *)
  Server.create depriv_create;
  Server.destroy depriv_destroy;
  Rpc_lwt.server Server.implementation

let process body =
  Dorpc.wrap_rpc Varstore_privileged_interface.E.error (fun () ->
      let call = Jsonrpc.call_of_string body in
      D.debug "Received request from message-switch, method %s" call.Rpc.name;
      rpc_fn call )
  >|= Jsonrpc.string_of_response

let make_message_switch_server () =
  let open Message_switch_lwt.Protocol_lwt in
  let wait_server, server_stopped = Lwt.task () in
  Server.listen
    ~process
    ~switch:!Xcp_client.switch_path
    ~queue:Varstore_privileged_interface.queue_name
    ()
  >>= fun result ->
  match Server.error_to_msg result with
  | `Ok t ->
    Lwt_switch.add_hook (Some shutdown) (fun () ->
        D.debug "Stopping message-switch queue server";
        Server.shutdown ~t () >|= Lwt.wakeup server_stopped );
    wait_server
  | `Error (`Msg m) ->
    Lwt.fail_with (Printf.sprintf "Failed to listen on message-switch queue: %s" m)

let () =
  let old_hook = !Lwt.async_exception_hook in
  Lwt.async_exception_hook := (fun exn ->
      D.log_backtrace ();
      D.error "Lwt caught async exception: %s" (Printexc.to_string exn);
      old_hook exn
    );
  let () = Lwt_main.run @@ make_message_switch_server () in
  D.debug "Exiting varstored-guard"
