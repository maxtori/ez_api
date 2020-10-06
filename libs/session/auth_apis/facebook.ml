module Types = struct
  type info = {
    app_id : int64;
    token_type : string;
    app_name : string;
    token_exp : int64;
    token_valid : bool;
    token_iss : int64;
    token_meta : Json_repr.any;
    token_scopes : string list;
    user_id : string;
  }
end

module Encoding = struct
  open Types
  open Json_encoding

  let encoding = obj1 @@ req "data" @@
    EzEncoding.ignore_enc @@ conv
      (fun {app_id; token_type; app_name; token_exp; token_valid; token_iss;
            token_meta; token_scopes; user_id}
        -> (app_id, token_type, app_name, token_exp, token_valid, token_iss,
            token_meta, token_scopes, user_id))
      (fun (app_id, token_type, app_name, token_exp, token_valid, token_iss,
            token_meta, token_scopes, user_id)
        -> {app_id; token_type; app_name; token_exp; token_valid; token_iss;
            token_meta; token_scopes; user_id}) @@
    obj9
      (req "app_id" int53)
      (req "type" string)
      (req "application" string)
      (req "expires_at" int53)
      (req "is_valid" bool)
      (req "issued_at" int53)
      (req "metadata" any_value)
      (req "scopes" (list string))
      (req "user_id" string)
end

module Services = struct
  let arg_user_id = EzAPI.arg_string "user_id" "68746545"

  let input_token_param = EzAPI.Param.string ~descr:"input token" "input_token"
  let access_token_param = EzAPI.Param.string ~descr:"access token" "access_token"
  let fields_param = EzAPI.Param.string ~descr:"output fields" "fields"

  let facebook_auth = EzAPI.TYPES.BASE "https://graph.facebook.com/"

  let debug_token : (Types.info, exn, EzAPI.no_security) EzAPI.service0 =
    EzAPI.service
      ~register:false
      ~name:"debug_token"
      ~params:[input_token_param; access_token_param]
      ~output:Encoding.encoding
      EzAPI.Path.(root // "debug_token")

  let nodes ?name output : (string, 'a, exn, EzAPI.no_security) EzAPI.service1 =
    EzAPI.service
      ~register:false
      ?name
      ~params:[access_token_param; fields_param]
      ~output
      EzAPI.Path.(root /: arg_user_id)

  let edges ?name output : (string, 'a, exn, EzAPI.no_security) EzAPI.service1 =
    EzAPI.service
      ~register:false
      ?name
      ~params:[access_token_param; fields_param]
      ~output
      EzAPI.Path.(root /: arg_user_id)

end

open Types
open Services
open EzRequest_lwt
open Lwt.Infix

let handle_error e = Error (handle_error (fun exn -> Some (Printexc.to_string exn)) e)

let check_token ~app_token ~app_id input_token =
  let params = [
    access_token_param, EzAPI.TYPES.S app_token;
    input_token_param, EzAPI.TYPES.S input_token] in
  ANY.get0 ~params facebook_auth debug_token >|= function
  | Error e -> handle_error e
  | Ok token ->
    if token.app_id = app_id && token.token_valid then Ok token.user_id
    else Error (400, Some "Invalid facebook token")

let get_address ~user_id user_access_token =
  let params = [
    access_token_param, EzAPI.TYPES.S user_access_token;
    fields_param, EzAPI.TYPES.S "email"
  ] in
  let output = Json_encoding.(obj1 (req "email" string)) in
  ANY.get1 ~params facebook_auth (nodes ~name:"email" output) user_id >|= function
  | Error e -> handle_error e
  | Ok email -> Ok email
