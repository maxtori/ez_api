(**************************************************************************)
(*                                                                        *)
(*                 Copyright 2018-2023 OCamlPro                           *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open EzAPI
open Lwt.Infix

module StringMap = Map.Make(String)
module Timings = Timings
module Directory = Directory
module Answer = Answer
module Req = Req
module File = File
module GMTime = GMTime
module Ip = Ip

(** Server *)

type server_kind =
  | API of Directory.t
  | Root of string * string option

type server = {
  server_port : int;
  server_kind : server_kind;
}

(** Utils *)

let return ?code ?headers x = Answer.return ?code ?headers x
let return_ok ?code ?headers x = Answer.return ?code ?headers (Ok x)
let return_error ?content ?headers code = Answer.return ~code ?headers (Error content)

let verbose = match Sys.getenv_opt "EZAPISERVER" with
  | None -> ref 0
  | Some s -> match int_of_string_opt s with
    | None -> ref 1
    | Some i -> ref i

let set_verbose i = verbose := i

let pp_time () =
  GMTime.(date_of_tm @@ Unix.gmtime @@ time ())

let debug ?(v=0) fmt =
  if !verbose > v then EzDebug.printf fmt
  else Printf.ifprintf () fmt

let debugf ?(v=0) f =
  if !verbose > v then f ()

(** Register Handler *)

let empty = Directory.empty

let register_res service handler dir =
  let security = Service.security service.s in
  let path = Service.path service.s in
  let handler args input =
    let t0 = (Path.get_root path args).Req.req_time in
    let add_timing_wrap b =
      let t1 = GMTime.time () in
      Timings.add_timing (EzAPI.id service) b t0 (t1-.t0) in
    Lwt.catch
      (function () ->
         handler args security input >>= fun res ->
         add_timing_wrap true;
         Lwt.return res)
      (fun exn -> add_timing_wrap true; Lwt.fail exn) in
  let service = register service in
  Directory.register_http dir service handler

let register_ws_res service ~react ~bg ?onclose ?step dir =
  let security = Service.security service.s in
  let bg r send = bg r security send in
  let react r i = react r security i in
  let service = register service in
  Directory.register_ws dir ?onclose ?step ~react ~bg service

exception Conflict of (Directory.Step.t list * Directory.conflict)

let register service handler dir =
  match register_res service handler dir with
  | Ok dir -> dir
  | Error (steps, conflict) ->
    Format.eprintf "Conflict for %s: %s@."
      (Directory.Step.list_to_string steps)
      (Directory.conflict_to_string conflict);
    raise (Conflict (steps, conflict))

let register_ws service ?onclose ?step ~react ~bg dir =
  match register_ws_res service ?onclose ?step ~react ~bg dir with
  | Ok dir -> dir
  | Error (steps, conflict) ->
    Format.eprintf "Conflict for %s: %s@."
      (Directory.Step.list_to_string steps)
      (Directory.conflict_to_string conflict);
    raise (Conflict (steps, conflict))

module Legacy = struct

  open Lwt.Infix
  open EzAPI.Legacy

  let register (service : ('a, 'b, 'c, 'd) service) handler dir =
    let handler r sec b = handler r sec b >|= fun r ->
      {Answer.code=200; body=Ok r; headers=[]} in
    register service handler dir

end

let handle ?meth ?content_type ?ws s r path body =
  let r, body =
    if content_type = Some Url.content_type then
      Req.add_params r (Url.decode_args body), ""
    else r, body in
  match s with
  | Root (root, default) -> File.reply ?meth root ?default path >|= fun a -> `http a
  | API dir ->
    Directory.lookup ?meth ?content_type dir r path >>= function
    | Error `Not_found -> Answer.not_found () >|= fun a -> `http a
    | Error (`Cannot_parse a) -> Answer.cannot_parse a >|= fun a -> `http a
    | Error `Method_not_allowed -> Answer.method_not_allowed () >|= fun a -> `http a
    | Ok (`options headers) ->
      Lwt.return {Answer.code=200; body=""; headers} >|= fun a -> `http a
    | Ok `head -> Lwt.return {Answer.code=200; body=""; headers =[]} >|= fun a -> `http a
    | Ok (`http h) ->
      begin
        h body >>= function
        | Error (`destruct_exn exn) -> Answer.destruct_exception exn
        | Error (`unsupported c) -> Answer.unsupported_media_type c
        | Error (`handler_error s) ->
          EzDebug.printf "In %s: error %s" (String.concat "/" path) s;
          Answer.server_error (Failure s)
        | Error (`handler_exn exn) ->
          EzDebug.printf "In %s: exception %s" (String.concat "/" path) @@ Printexc.to_string exn;
          Answer.server_error exn
        | Ok a -> Lwt.return a
      end >|= fun a -> (`http a)
    | Ok (`ws (react, bg, onclose, step)) ->
      begin match ws with
        | None -> assert false
        | Some ws -> ws ?onclose ?step ~react ~bg r.Req.req_id
      end >|= fun ra -> `ws ra

(* Default access control headers *)
let default_access_control_headers = [
  "access-control-allow-origin", "*";
  "access-control-allow-headers", "accept, content-type" 
]

(* merge headers correctly with default one *)
let merge_headers_with_default headers : (string * string) list =
  (* combining existing headers *)
  let l = List.fold_left
      (fun acc ((hn,hv) as h) ->
         match List.assoc_opt hn default_access_control_headers with
         | None -> h::acc
         | Some _ when hn = "access-control-allow-origin" ->
           h::acc
         | Some v when hn = "access-control-allow-headers" ->
           (hn, hv ^ "," ^ v)::acc 
         | _ -> acc)
      []
      headers
  in
  (* Adding default if not present *)
  List.fold_left (fun acc ((hn,_) as h) ->
      match List.assoc_opt hn l with
      | None -> h::acc
      | _ -> acc    
    ) l default_access_control_headers