open Core
open Async
open Signature_lib
open Command_spec


  type t = {
    graphql_client: Test_graphql.t
    ; logger: Logger.t
  }


  let of_graphql_client ~graphql_client ~logger = 
    {
      graphql_client;
      logger
    }
    
    let from_string ~endpoint ~logger = 
      of_graphql_client ~graphql_client:(Test_graphql.create_from_string_default ~endpoint ~logger) ~logger
    
    let pk_to_str pk =
      pk |> Public_key.compress |> Public_key.Compressed.to_base58_check

    let get_nonce t ~public_key = 
      let open Deferred.Let_syntax in
      let%bind {nonce; _} =
        let%bind querry_result =
          (Test_graphql.get_account_data_by_pk t.graphql_client ~public_key)
        in
        match querry_result with
        | Ok n ->
            return n
        | Error error ->
            [%log' error t.logger] "Could not get nonce of pk= %s, due to '%s'" (pk_to_str public_key) (Error.to_string_hum error);  
            Error.raise error
      in
      let nonce = (Mina_numbers.Account_nonce.to_uint32 nonce) in
      [%log' debug t.logger] "nonce obtained, nonce= %d" (Unsigned.UInt32.to_int nonce);
      Deferred.return nonce


    let send_unsigned_delegation t ~(spec:Command_spec.delegation) ~password =
      let open Deferred.Let_syntax in
      let sender_pub_key = Signature_lib.Public_key.compress spec.sender_pub_key in
      let receiver_pub_key =  Signature_lib.Public_key.compress spec.receiver_pub_key in
      let%bind _ = Test_graphql.unlock_account t.graphql_client ~password ~sender_pub_key in
      Test_graphql.send_unsigned_delegation t.graphql_client 
        ~sender_pub_key 
        ~receiver_pub_key
        ~fee:spec.fee

    let send_signed_payment t ~spec=
      let open Deferred.Let_syntax in
      let%bind nonce = match spec.tx.nonce with
        | Some nonce -> Deferred.return nonce;
        | None -> get_nonce t ~public_key:spec.tx.sender_pub_key in
      [%log' debug t.logger] "Sending tx from sender= %s (nonce=%d) to receiver= %s \
        with amount=%s and fee=%s"
        (pk_to_str spec.tx.sender_pub_key)
        (Unsigned.UInt32.to_int nonce)
        (pk_to_str spec.tx.receiver_pub_key)
        (Currency.Amount.to_string spec.tx.amount)
        (Currency.Fee.to_string spec.tx.fee);
      
      let sender_pub_key = Signature_lib.Public_key.compress spec.tx.sender_pub_key in
      let receiver_pub_key =  Signature_lib.Public_key.compress spec.tx.receiver_pub_key in
      let valid_until = Mina_numbers.Global_slot_since_genesis.max_value in
      let nonce = Mina_numbers.Account_nonce.of_uint32 nonce in
      let raw_signature = Command_spec.to_raw_signature spec in
      Test_graphql.send_payment_with_raw_sig t.graphql_client ~sender_pub_key ~nonce
          ~receiver_pub_key ~amount:spec.tx.amount ~fee:spec.tx.fee ~raw_signature ~memo:spec.tx.memo ~valid_until
          
    let send_unsigned_payment t ~(spec:Command_spec.tx) ~password =
      let open Deferred.Or_error.Let_syntax in
      let sender_pub_key = Signature_lib.Public_key.compress spec.sender_pub_key in
      let receiver_pub_key =  Signature_lib.Public_key.compress spec.receiver_pub_key in
       
      let%bind () = Test_graphql.unlock_account t.graphql_client ~sender_pub_key ~password in
      Test_graphql.send_unsigned_payment t.graphql_client ~sender_pub_key ~receiver_pub_key ~amount:spec.amount ~fee:spec.fee

    
    let send_zkapp_batch t ~zkapp_commands =
      let open Deferred.Or_error.Let_syntax in
      List.iter zkapp_commands ~f:(fun zkapp_command ->
        [%log' info t.logger]  "Sending zkApp"
            ~metadata:
              [ ("zkapp_command", Mina_base.Zkapp_command.to_yojson zkapp_command)
              ; ( "memo"
                , `String
                    (Mina_base.Signed_command_memo.to_string_hum
                      zkapp_command.memo ) )
              ] ) ;
      match%bind.Deferred
          Test_graphql.send_zkapp_batch t.graphql_client ~zkapp_commands
      with
      | Ok zkapp_ids ->
        [%log' info t.logger]  "ZkApp transactions sent" ;
          return zkapp_ids
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log' error t.logger]  "Error sending zkApp transactions"
            ~metadata:[ ("error", `String err_str) ] ;
          Error.raise err

    let send_zkapp t ~zkapp_command =
      let open Deferred.Or_error.Let_syntax in
      let%bind statuses = send_zkapp_batch t ~zkapp_commands:[ zkapp_command ] in
      return (List.nth_exn statuses 0)

    let send_invalid_zkapp t ~zkapp_command ~substring =
      [%log' info t.logger] "Sending zkApp, expected to fail" ;
      match%bind.Deferred
        Test_graphql.send_zkapp_batch t.graphql_client ~zkapp_commands:[ zkapp_command ]
      with
      | Ok _zkapp_ids ->
        [%log' error t.logger] "ZkApp transaction succeeded, expected error \"%s\""
            substring ;
          Malleable_error.hard_error_format
            "ZkApp transaction succeeded, expected error \"%s\"" substring
      | Error err ->
          let err_str = Error.to_string_mach err in
          if String.is_substring ~substring err_str then (
            [%log' info t.logger] "ZkApp transaction failed as expected"
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.return () )
          else (
            [%log' error t.logger]
              "Error sending zkApp, for a reason other than the expected \"%s\""
              substring
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.hard_error_format
              "ZkApp transaction failed: %s, but expected \"%s\"" err_str
              substring )

    let send_invalid_payment t ~spec ~expected_failure :
        unit Malleable_error.t =
        [%log' info t.logger] "Sending payment, expected to fail" ;
      let expected_failure = String.lowercase expected_failure in
      match%bind.Deferred send_signed_payment t ~spec
      with
      | Ok _ ->
        [%log' error t.logger] "Payment succeeded, expected error \"%s\"" expected_failure ;
          Malleable_error.hard_error_format
            "Payment transaction succeeded, expected error \"%s\""
            expected_failure
      | Error err ->
          let err_str = Error.to_string_mach err |> String.lowercase in
          if String.is_substring ~substring:expected_failure err_str then (
            [%log' info t.logger] "Payment failed as expected"
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.return () )
          else (
            [%log' error t.logger]
              "Error sending payment, for a reason other than the expected \"%s\""
              expected_failure
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.hard_error_format
              "Payment failed: %s, but expected \"%s\"" err_str expected_failure )