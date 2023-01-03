open Core
open Async
open Integration_test_lib

module Make (Inputs : Intf.Test.Inputs_intf) = struct
  open Inputs
  open Engine
  open Dsl

  open Test_common.Make (Inputs)

  type network = Network.t

  type node = Network.Node.t

  type dsl = Dsl.t

  let initial_fee_payer_balance = Currency.Balance.of_mina_string_exn "8000000"

  let zkapp_target_balance = Currency.Balance.of_mina_string_exn "10"

  let config =
    let open Test_config in
    let open Test_config.Wallet in
    { default with
      requires_graphql = true
    ; block_producers =
        [ { balance = Currency.Balance.to_mina_string initial_fee_payer_balance
          ; timing = Untimed
          }
        ]
    ; extra_genesis_accounts = [ { balance = "10"; timing = Untimed } ]
    ; num_snark_workers = 0
    }

  let wait_and_stdout ~logger process =
    let open Deferred.Let_syntax in
    let%map output = Async_unix.Process.collect_output_and_wait process in
    let stdout = String.strip output.stdout in
    [%log info] "Stdout: $stdout" ~metadata:[ ("stdout", `String stdout) ] ;
    if not (String.is_empty output.stderr) then
      let () =
        [%log warn] "Stderr: $stderr"
          ~metadata:[ ("stderr", `String output.stderr) ]
      in
      failwith output.stderr
    else String.split stdout ~on:'\n' |> List.last_exn

  let run network t =
    let open Malleable_error.Let_syntax in
    let logger = Logger.create () in
    let block_producer_nodes = Network.block_producers network in
    let node = List.hd_exn block_producer_nodes in
    let graphql = Network.Node.graphql_uri node in
    let run_snarkyjs_integration_test =
      [%log info] "Running JS script with graphql endpoint $graphql"
        ~metadata:[ ("graphql", `String graphql) ] ;
      let%bind.Deferred zkapp_command_contract_str, unit_with_error =
        Deferred.both
          (let%bind.Deferred process =
             Async_unix.Process.create_exn
               ~prog:"./src/lib/snarky_js_bindings/test_module/node"
               ~args:
                 [ "src/lib/snarky_js_bindings/test_module/simple-zkapp.js"
                 ; graphql
                 ]
               ()
           in
           wait_and_stdout ~logger process )
          (wait_for t (Wait_condition.node_to_initialize node))
      in
      let zkapp_command_contract =
        Mina_base.Zkapp_command.of_json
          (Yojson.Safe.from_string zkapp_command_contract_str)
      in
      let%bind () = Deferred.return unit_with_error in
      (* TODO: switch to external sending script once the rest is working *)
      return zkapp_command_contract
    in
    return run_snarkyjs_integration_test
end
