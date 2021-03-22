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

let register_ws_res service ~react ~bg ?onclose dir =
  let security = Service.security service.s in
  let bg r send = bg r security send in
  let react r i = react r security i in
  let service = register service in
  Directory.register_ws dir ?onclose ~react ~bg service

exception Conflict of (Directory.Step.t list * Directory.conflict)

let register service handler dir =
  match register_res service handler dir with
  | Ok dir -> dir
  | Error e -> raise (Conflict e)

let register_ws service ?onclose ~react ~bg dir =
  match register_ws_res service ?onclose ~react ~bg dir with
  | Ok dir -> dir
  | Error e -> raise (Conflict e)

module Legacy = struct

  open Lwt.Infix
  open EzAPI.Legacy

  let register (service : ('a, 'b, 'c, 'd) service) handler dir =
    let handler r sec b = handler r sec b >|= fun r ->
      {Answer.code=200; body=Ok r; headers=[]} in
    register service handler dir

end

let handle ?meth ?content_type ?ws s r path body =
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
        | Error (`cannot_destruct a) -> Answer.cannot_destruct a
        | Error (`unexpected_field f) -> Answer.unexpected_field f
        | Error (`unsupported c) -> Answer.unsupported_media_type c
        | Error (`handler_error s) ->
          EzDebug.printf "In %s: error %s" (String.concat "/" path) s;
          Answer.server_error (Failure s)
        | Error (`handler_exn exn) ->
          EzDebug.printf "In %s: exception %s" (String.concat "/" path) @@ Printexc.to_string exn;
          Answer.server_error exn
        | Ok a -> Lwt.return a
      end >|= fun a -> (`http a)
    | Ok (`ws (react, bg, onclose)) ->
      begin match ws with
        | None -> assert false
        | Some ws -> ws ?onclose ~react ~bg ()
      end >|= fun ra -> `ws ra

let access_control_headers = [
  "access-control-allow-origin", "*";
  "access-control-allow-headers", "accept, content-type" ]
