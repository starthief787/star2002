open Async
open Core

type node_status_data =
  { block_height_at_best_tip: int
  ; max_observed_block_height: int
  ; max_observed_unvalidated_block_height: int }
[@@deriving to_yojson]

let send_node_status_data ~logger ~url node_status_data =
  let node_status_json = node_status_data_to_yojson node_status_data in
  let json = `Assoc [("data", node_status_json)] in
  let headers = Cohttp.Header.of_list [("Content-Type", "application/json")] in
  match%map
    Cohttp_async.Client.post ~headers
      ~body:(Yojson.Safe.to_string json |> Cohttp_async.Body.of_string)
      url
  with
  | {status; _}, body ->
      let metadata =
        [("data", node_status_json); ("url", `String (Uri.to_string url))]
      in
      if Cohttp.Code.code_of_status status = 200 then
        [%log info] "Sent node status data to URL $url" ~metadata
      else
        let extra_metadata =
          match body with
          | `String s ->
              [("error", `String s)]
          | `Strings ss ->
              [("error", `List (List.map ss ~f:(fun s -> `String s)))]
          | `Empty | `Pipe _ ->
              []
        in
        [%log error] "Failed to send node status data to URL $url"
          ~metadata:(metadata @ extra_metadata)

let start ~logger ~node_status_url =
  let url_string = Option.value ~default:"127.0.0.1" node_status_url in
  [%log info] "Starting node status service using URL $url"
    ~metadata:[("URL", `String url_string)] ;
  let _data = Prometheus.CollectorRegistry.(collect default) in
  let node_status_data =
    { block_height_at_best_tip= 1
    ; max_observed_block_height= 2
    ; max_observed_unvalidated_block_height= 3 }
  in
  don't_wait_for
  @@ send_node_status_data ~logger ~url:(Uri.of_string url_string)
       node_status_data
