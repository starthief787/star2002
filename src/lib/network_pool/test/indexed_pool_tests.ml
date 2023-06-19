(** Testing
    -------
    Component:  Network pool
    Invocation: dune exec src/lib/network_pool/test/main.exe -- \
                  test '^indexed pool$'
    Subject:    Test the indexed pool.
 *)

open Core_kernel
open Currency
open Mina_base
open Mina_numbers
open Mina_transaction
open Signature_lib
open Network_pool
open Indexed_pool
open For_tests

let test_keys = Array.init 10 ~f:(fun _ -> Keypair.create ())

let gen_cmd ?(keys = test_keys) ?sign_type ?nonce () =
  User_command.Valid.Gen.payment_with_random_participants ~keys ~max_amount:1000
    ~fee_range:100 ?sign_type ?nonce ()
  |> Quickcheck.Generator.map
       ~f:Transaction_hash.User_command_with_valid_signature.create

(* The [key] is sending money to itself, because the interface provided by
   existing generators does not allow specifying only one of them. Fortunately
   this does not really matter for these tests. *)
let gen_successive_fees ~key ?(nonce = Account_nonce.zero) len =
  let open Quickcheck.Generator.Let_syntax in
  let rec gen_list acc nonce =
    if List.length acc < len then
      let%bind cmd = gen_cmd ~keys:[| key |] ~nonce () in
      gen_list (cmd :: acc) (Account_nonce.succ nonce)
    else return (List.rev acc)
  in
  gen_list [] nonce

let precomputed_values = Lazy.force Precomputed_values.for_unit_tests

let constraint_constants = precomputed_values.constraint_constants

let consensus_constants = precomputed_values.consensus_constants

let logger = Logger.null ()

let time_controller = Block_time.Controller.basic ~logger

let empty = empty ~constraint_constants ~consensus_constants ~time_controller

let empty_invariants () = assert_invariants empty

let singleton_properties () =
  Quickcheck.test (gen_cmd ()) ~f:(fun cmd ->
      let pool = empty in
      let add_res =
        add_from_gossip_exn pool cmd Account_nonce.zero
          (Amount.of_nanomina_int_exn 500)
      in
      if
        Option.value_exn (currency_consumed ~constraint_constants cmd)
        |> Amount.to_nanomina_int > 500
      then
        match add_res with
        | Error (Insufficient_funds _) ->
            ()
        | _ ->
            failwith "should've returned insufficient_funds"
      else
        match add_res with
        | Ok (_, pool', dropped) ->
            assert_invariants pool' ;
            assert (Sequence.is_empty dropped) ;
            [%test_eq: int] (size pool') 1 ;
            [%test_eq:
              Transaction_hash.User_command_with_valid_signature.t option]
              (get_highest_fee pool') (Some cmd) ;
            let dropped', pool'' = remove_lowest_fee pool' in
            [%test_eq:
              Transaction_hash.User_command_with_valid_signature.t Sequence.t]
              dropped' (Sequence.singleton cmd) ;
            [%test_eq: t] ~equal pool pool''
        | _ ->
            failwith "should've succeeded" )

let sequential_adds_all_valid () =
  let gen :
      ( Mina_ledger.Ledger.init_state
      * Transaction_hash.User_command_with_valid_signature.t list )
      Quickcheck.Generator.t =
    let open Quickcheck.Generator.Let_syntax in
    let%bind ledger_init = Mina_ledger.Ledger.gen_initial_ledger_state in
    let%map cmds = User_command.Valid.Gen.sequence ledger_init in
    ( ledger_init
    , List.map ~f:Transaction_hash.User_command_with_valid_signature.create cmds
    )
  in
  let shrinker :
      ( Mina_ledger.Ledger.init_state
      * Transaction_hash.User_command_with_valid_signature.t list )
      Quickcheck.Shrinker.t =
    Quickcheck.Shrinker.create (fun (init_state, cmds) ->
        Sequence.singleton (init_state, List.take cmds (List.length cmds - 1)) )
  in
  Quickcheck.test gen ~trials:1000
    ~sexp_of:
      [%sexp_of:
        Mina_ledger.Ledger.init_state
        * Transaction_hash.User_command_with_valid_signature.t list]
    ~shrinker ~shrink_attempts:`Exhaustive ~seed:(`Deterministic "d")
    ~sizes:(Sequence.repeat 10) ~f:(fun (ledger_init, cmds) ->
      let account_init_states_seq = Array.to_sequence ledger_init in
      let balances = Hashtbl.create (module Public_key.Compressed) in
      let nonces = Hashtbl.create (module Public_key.Compressed) in
      Sequence.iter account_init_states_seq ~f:(fun (kp, balance, nonce, _) ->
          let compressed = Public_key.compress kp.public_key in
          Hashtbl.add_exn balances ~key:compressed ~data:balance ;
          Hashtbl.add_exn nonces ~key:compressed ~data:nonce ) ;
      let pool = ref empty in
      let rec go cmds_acc =
        match cmds_acc with
        | [] ->
            ()
        | cmd :: rest -> (
            let unchecked =
              Transaction_hash.User_command_with_valid_signature.command cmd
            in
            let account_id = User_command.fee_payer unchecked in
            let pk = Account_id.public_key account_id in
            let add_res =
              add_from_gossip_exn !pool cmd
                (Hashtbl.find_exn nonces pk)
                (Hashtbl.find_exn balances pk)
            in
            match add_res with
            | Ok (_, pool', dropped) ->
                [%test_eq:
                  Transaction_hash.User_command_with_valid_signature.t
                  Sequence.t] dropped Sequence.empty ;
                assert_invariants pool' ;
                pool := pool' ;
                go rest
            | Error (Invalid_nonce (`Expected want, got)) ->
                failwithf
                  !"Bad nonce. Expected: %{sexp: Account.Nonce.t}. Got: \
                    %{sexp: Account.Nonce.t}"
                  want got ()
            | Error (Invalid_nonce (`Between (low, high), got)) ->
                failwithf
                  !"Bad nonce. Expected between %{sexp: Account.Nonce.t} and \
                    %{sexp:Account.Nonce.t}. Got: %{sexp: Account.Nonce.t}"
                  low high got ()
            | Error (Insufficient_funds (`Balance bal, amt)) ->
                failwithf
                  !"Insufficient funds. Balance: %{sexp: Amount.t}. Amount: \
                    %{sexp: Amount.t}"
                  bal amt ()
            | Error (Insufficient_replace_fee (`Replace_fee rfee, fee)) ->
                failwithf
                  !"Insufficient fee for replacement. Needed at least %{sexp: \
                    Fee.t} but got %{sexp:Fee.t}."
                  rfee fee ()
            | Error Overflow ->
                failwith "Overflow."
            | Error Bad_token ->
                failwith "Token is incompatible with the command."
            | Error (Unwanted_fee_token fee_token) ->
                failwithf
                  !"Bad fee token. The fees are paid in token %{sexp: \
                    Token_id.t}, which we are not accepting fees in."
                  fee_token ()
            | Error
                (Expired
                  ( `Valid_until valid_until
                  , `Global_slot_since_genesis global_slot_since_genesis ) ) ->
                failwithf
                  !"Expired user command. Current global slot is \
                    %{sexp:Mina_numbers.Global_slot_since_genesis.t} but user \
                    command is only valid until \
                    %{sexp:Mina_numbers.Global_slot_since_genesis.t}"
                  global_slot_since_genesis valid_until () )
      in
      go cmds )

let replacement () =
  let modify_payment (c : User_command.t) ~sender ~common:fc ~body:fb =
    let modified_payload : Signed_command.Payload.t =
      match c with
      | Signed_command
          { payload = { body = Payment payment_payload; common }; _ } ->
          { common = fc common
          ; body = Signed_command.Payload.Body.Payment (fb payment_payload)
          }
      | _ ->
          failwith "generated user command that wasn't a payment"
    in
    Signed_command (Signed_command.For_tests.fake_sign sender modified_payload)
    |> Transaction_hash.User_command_with_valid_signature.create
  in
  let gen :
      ( Account_nonce.t
      * Amount.t
      * Transaction_hash.User_command_with_valid_signature.t list
      * Transaction_hash.User_command_with_valid_signature.t )
      Quickcheck.Generator.t =
    let open Quickcheck.Generator.Let_syntax in
    let%bind sender_index = Int.gen_incl 0 9 in
    let sender = test_keys.(sender_index) in
    let%bind init_nonce =
      Quickcheck.Generator.map ~f:Account_nonce.of_int @@ Int.gen_incl 0 1000
    in
    let init_balance = Amount.of_mina_int_exn 100_000 in
    let%bind size = Quickcheck.Generator.size in
    let%bind amounts =
      Quickcheck.Generator.map ~f:Array.of_list
      @@ Quickcheck_lib.gen_division_currency init_balance (size + 1)
    in
    let rec go current_nonce current_balance n =
      if n > 0 then
        let%bind cmd =
          let key_gen =
            Quickcheck.Generator.tuple2 (return sender)
              (Quickcheck_lib.of_array test_keys)
          in
          Mina_generators.User_command_generators.payment ~sign_type:`Fake
            ~key_gen ~nonce:current_nonce ~max_amount:1 ~fee_range:0 ()
        in
        let cmd_currency = amounts.(n - 1) in
        let%bind fee =
          Amount.(gen_incl zero (min (of_nanomina_int_exn 10) cmd_currency))
        in
        let amount = Option.value_exn Amount.(cmd_currency - fee) in
        let cmd' =
          modify_payment cmd ~sender
            ~common:(fun c -> { c with fee = Amount.to_fee fee })
            ~body:(fun b -> { b with amount })
        in
        let consumed =
          Option.value_exn (currency_consumed ~constraint_constants cmd')
        in
        let%map rest =
          go
            (Account_nonce.succ current_nonce)
            (Option.value_exn Amount.(current_balance - consumed))
            (n - 1)
        in
        cmd' :: rest
      else return []
    in
    let%bind setup_cmds = go init_nonce init_balance (size + 1) in
    let init_nonce_int = Account.Nonce.to_int init_nonce in
    let%bind replaced_nonce =
      Int.gen_incl init_nonce_int (init_nonce_int + List.length setup_cmds - 1)
    in
    let%map replace_cmd_skeleton =
      let key_gen =
        Quickcheck.Generator.tuple2 (return sender)
          (Quickcheck_lib.of_array test_keys)
      in
      Mina_generators.User_command_generators.payment ~sign_type:`Fake ~key_gen
        ~nonce:(Account_nonce.of_int replaced_nonce)
        ~max_amount:(Amount.to_nanomina_int init_balance)
        ~fee_range:0 ()
    in
    let replace_cmd =
      modify_payment replace_cmd_skeleton ~sender ~body:Fn.id ~common:(fun c ->
          { c with fee = Fee.of_mina_int_exn (10 + (5 * (size + 1))) } )
    in
    (init_nonce, init_balance, setup_cmds, replace_cmd)
  in
  Quickcheck.test ~trials:20 gen
    ~sexp_of:
      [%sexp_of:
        Account_nonce.t
        * Amount.t
        * Transaction_hash.User_command_with_valid_signature.t list
        * Transaction_hash.User_command_with_valid_signature.t]
    ~f:(fun (init_nonce, init_balance, setup_cmds, replace_cmd) ->
      let t =
        List.fold_left setup_cmds ~init:empty ~f:(fun t cmd ->
            match add_from_gossip_exn t cmd init_nonce init_balance with
            | Ok (_, t', removed) ->
                [%test_eq:
                  Transaction_hash.User_command_with_valid_signature.t
                  Sequence.t] removed Sequence.empty ;
                t'
            | _ ->
                failwith
                @@ sprintf
                     !"adding command %{sexp: \
                       Transaction_hash.User_command_with_valid_signature.t} \
                       failed"
                     cmd )
      in
      let replaced_idx, _ =
        let replace_nonce =
          replace_cmd
          |> Transaction_hash.User_command_with_valid_signature.command
          |> User_command.applicable_at_nonce
        in
        List.findi setup_cmds ~f:(fun _i cmd ->
            let cmd_nonce =
              cmd |> Transaction_hash.User_command_with_valid_signature.command
              |> User_command.applicable_at_nonce
            in
            Account_nonce.compare replace_nonce cmd_nonce <= 0 )
        |> Option.value_exn
      in
      let currency_consumed_pre_replace =
        List.fold_left
          (List.take setup_cmds (replaced_idx + 1))
          ~init:Amount.zero
          ~f:(fun consumed_so_far cmd ->
            Option.value_exn
              Option.(
                currency_consumed ~constraint_constants cmd
                >>= fun consumed -> Amount.(consumed + consumed_so_far)) )
      in
      assert (Amount.(currency_consumed_pre_replace <= init_balance)) ;
      let currency_consumed_post_replace =
        Option.value_exn
          (let open Option.Let_syntax in
          let%bind replaced_currency_consumed =
            currency_consumed ~constraint_constants
            @@ List.nth_exn setup_cmds replaced_idx
          in
          let%bind replacer_currency_consumed =
            currency_consumed ~constraint_constants replace_cmd
          in
          let%bind a =
            Amount.(currency_consumed_pre_replace - replaced_currency_consumed)
          in
          Amount.(a + replacer_currency_consumed))
      in
      let add_res = add_from_gossip_exn t replace_cmd init_nonce init_balance in
      if Amount.(currency_consumed_post_replace <= init_balance) then
        match add_res with
        | Ok (_, t', dropped) ->
            assert (not (Sequence.is_empty dropped)) ;
            assert_invariants t'
        | Error _ ->
            failwith "adding command failed"
      else
        match add_res with
        | Error (Insufficient_funds _) ->
            ()
        | _ ->
            failwith "should've returned insufficient_funds" )

let remove_lowest_fee () =
  let cmds =
    gen_cmd () |> Quickcheck.random_sequence |> Fn.flip Sequence.take 4
    |> Sequence.to_list
  in
  let compare cmd0 cmd1 : int =
    let open Transaction_hash.User_command_with_valid_signature in
    Fee_rate.compare
      (User_command.fee_per_wu @@ command cmd0)
      (User_command.fee_per_wu @@ command cmd1)
  in
  let cmds_sorted_by_fee_per_wu = List.sort ~compare cmds in
  let cmd_lowest_fee, commands_to_keep =
    ( List.hd_exn cmds_sorted_by_fee_per_wu
    , List.tl_exn cmds_sorted_by_fee_per_wu )
  in
  let insert_cmd pool cmd =
    add_from_gossip_exn pool cmd Account_nonce.zero (Amount.of_mina_int_exn 5)
    |> Result.ok |> Option.value_exn
    |> fun (_, pool, _) -> pool
  in
  let cmd_equal = Transaction_hash.User_command_with_valid_signature.equal in
  let removed, pool =
    List.fold_left cmds ~init:empty ~f:insert_cmd |> remove_lowest_fee
  in
  (* check that the lowest fee per wu command is returned *)
  assert (Sequence.(equal cmd_equal removed @@ return cmd_lowest_fee))
  |> fun () ->
  (* check that the lowest fee per wu command is removed from
     applicable_by_fee *)
  applicable_by_fee pool |> Map.data
  |> List.concat_map ~f:Set.to_list
  |> fun applicable_by_fee_cmds ->
  assert (List.(equal cmd_equal applicable_by_fee_cmds commands_to_keep))
  |> fun () ->
  (* check that the lowest fee per wu command is removed from
     all_by_fee *)
  applicable_by_fee pool |> Map.data
  |> List.concat_map ~f:Set.to_list
  |> fun all_by_fee_cmds ->
  assert (List.(equal cmd_equal all_by_fee_cmds commands_to_keep))

let insert_cmd pool cmd =
  add_from_gossip_exn pool cmd Account_nonce.zero (Amount.of_mina_int_exn 5)
  |> Result.map_error ~f:(fun e ->
         let sexp = Command_error.sexp_of_t e in
         Failure (Sexp.to_string sexp) )
  |> Result.ok_exn
  |> fun (_, pool, _) -> pool

(** Picking a transaction to include in a block, choose the one with
    highest fee. *)
let pick_highest_fee_for_application () =
  Quickcheck.test
    (* This should be replaced with a proper generator, but for the moment it
       generates inputs which fail the test. *)
    ( gen_cmd () |> Quickcheck.random_sequence |> Fn.flip Sequence.take 4
    |> Sequence.to_list |> Quickcheck.Generator.return )
    ~f:(fun cmds ->
      let compare cmd0 cmd1 : int =
        let open Transaction_hash.User_command_with_valid_signature in
        Fee_rate.compare
          (User_command.fee_per_wu @@ command cmd0)
          (User_command.fee_per_wu @@ command cmd1)
      in
      let pool = List.fold_left cmds ~init:empty ~f:insert_cmd in
      [%test_eq: Transaction_hash.User_command_with_valid_signature.t option]
        (get_highest_fee pool)
        (List.max_elt ~compare cmds) )

let command_nonce (txn : Transaction_hash.User_command_with_valid_signature.t) =
  let open Transaction_hash.User_command_with_valid_signature in
  match (forget_check txn).data with
  | Signed_command sc ->
      Signed_command.nonce sc
  | Zkapp_command zk ->
      zk.fee_payer.body.nonce

let dummy_state_view =
  let state_body =
    let consensus_constants =
      let genesis_constants = Genesis_constants.for_unit_tests in
      Consensus.Constants.create ~constraint_constants
        ~protocol_constants:genesis_constants.protocol
    in
    let compile_time_genesis =
      (*not using Precomputed_values.for_unit_test because of dependency cycle*)
      Mina_state.Genesis_protocol_state.t
        ~genesis_ledger:Genesis_ledger.(Packed.t for_unit_tests)
        ~genesis_epoch_data:Consensus.Genesis_epoch_data.for_unit_tests
        ~genesis_body_reference:Staged_ledger_diff.genesis_body_reference
        ~constraint_constants ~consensus_constants
    in
    compile_time_genesis.data |> Mina_state.Protocol_state.body
  in
  { (Mina_state.Protocol_state.Body.view state_body) with
    global_slot_since_genesis = Mina_numbers.Global_slot_since_genesis.zero
  }

let add_to_pool ~nonce ~balance pool cmd =
  let _, pool', dropped =
    add_from_gossip_exn pool cmd nonce balance
    |> Result.map_error ~f:(Fn.compose Sexp.to_string Command_error.sexp_of_t)
    |> Result.ok_or_failwith
  in
  [%test_eq: Transaction_hash.User_command_with_valid_signature.t Sequence.t]
    dropped Sequence.empty ;
  assert_invariants pool' ;
  pool'

let init_permissionless_ledger ledger account_info =
  let open Mina_ledger.Ledger.Ledger_inner in
  List.iter account_info ~f:(fun (public_key, amount) ->
      let account_id =
        Account_id.create (Public_key.compress public_key) Token_id.default
      in
      let balance =
        Balance.of_nanomina_int_exn @@ Amount.to_nanomina_int amount
      in
      let _tag, account, location =
        Or_error.ok_exn (get_or_create ledger account_id)
      in
      set ledger location
        { account with balance; permissions = Permissions.empty } )

let apply_to_ledger ledger cmd =
  match Transaction_hash.User_command_with_valid_signature.command cmd with
  | User_command.Signed_command c ->
      let (`If_this_is_used_it_should_have_a_comment_justifying_it v) =
        Signed_command.to_valid_unsafe c
      in
      ignore
        ( Mina_ledger.Ledger.apply_user_command ~constraint_constants
            ~txn_global_slot:Mina_numbers.Global_slot_since_genesis.zero ledger
            v
          |> Or_error.ok_exn
          : Mina_transaction_logic.Transaction_applied.Signed_command_applied.t
          )
  | User_command.Zkapp_command p -> (
      let applied, _ =
        Mina_ledger.Ledger.apply_zkapp_command_unchecked ~constraint_constants
          ~global_slot:dummy_state_view.global_slot_since_genesis
          ~state_view:dummy_state_view ledger p
        |> Or_error.ok_exn
      in
      match With_status.status applied.command with
      | Transaction_status.Applied ->
          ()
      | Transaction_status.Failed failure ->
          failwithf "failed to apply zkapp_command transaction to ledger: [%s]"
            ( String.concat ~sep:", "
            @@ List.bind
                 ~f:(List.map ~f:Transaction_status.Failure.to_string)
                 failure )
            () )

let commit_to_pool ledger pool cmd expected_drops =
  apply_to_ledger ledger cmd ;
  let accounts_to_check =
    Transaction_hash.User_command_with_valid_signature.command cmd
    |> User_command.accounts_referenced |> Account_id.Set.of_list
  in
  let pool, dropped =
    revalidate pool ~logger (`Subset accounts_to_check) (fun sender ->
        match Mina_ledger.Ledger.location_of_account ledger sender with
        | None ->
            Account.empty
        | Some loc ->
            Option.value_exn
              ~message:"Somehow a public key has a location but no account"
              (Mina_ledger.Ledger.get ledger loc) )
  in
  let lower =
    List.map ~f:Transaction_hash.User_command_with_valid_signature.hash
  in
  [%test_eq: Transaction_hash.t list]
    (lower (Sequence.to_list dropped))
    (lower expected_drops) ;
  assert_invariants pool ;
  pool

let make_zkapp_command_payment ~(sender : Keypair.t) ~(receiver : Keypair.t)
    ~double_increment_sender ~increment_receiver ~amount ~fee nonce_int =
  let nonce = Account.Nonce.of_int nonce_int in
  let sender_pk = Public_key.compress sender.public_key in
  let receiver_pk = Public_key.compress receiver.public_key in
  let zkapp_command_wire : Zkapp_command.Stable.Latest.Wire.t =
    { fee_payer =
        { Account_update.Fee_payer.body =
            { public_key = sender_pk; fee; nonce; valid_until = None }
            (* Real signature added in below *)
        ; authorization = Signature.dummy
        }
    ; account_updates =
        Zkapp_command.Call_forest.of_account_updates
          ~account_update_depth:(Fn.const 0)
          [ { Account_update.body =
                { public_key = sender_pk
                ; update = Account_update.Update.noop
                ; token_id = Token_id.default
                ; balance_change = Amount.Signed.(negate @@ of_unsigned amount)
                ; increment_nonce = double_increment_sender
                ; events = []
                ; actions = []
                ; call_data = Snark_params.Tick.Field.zero
                ; preconditions =
                    { Account_update.Preconditions.network =
                        Zkapp_precondition.Protocol_state.accept
                    ; account =
                        Account_update.Account_precondition.Nonce
                          (Account.Nonce.succ nonce)
                    ; valid_while = Ignore
                    }
                ; may_use_token = No
                ; use_full_commitment = not double_increment_sender
                ; implicit_account_creation_fee = false
                ; authorization_kind = None_given
                }
            ; authorization = None_given
            }
          ; { Account_update.body =
                { public_key = receiver_pk
                ; update = Account_update.Update.noop
                ; token_id = Token_id.default
                ; balance_change = Amount.Signed.of_unsigned amount
                ; increment_nonce = increment_receiver
                ; events = []
                ; actions = []
                ; call_data = Snark_params.Tick.Field.zero
                ; preconditions =
                    { Account_update.Preconditions.network =
                        Zkapp_precondition.Protocol_state.accept
                    ; account = Account_update.Account_precondition.Accept
                    ; valid_while = Ignore
                    }
                ; may_use_token = No
                ; implicit_account_creation_fee = false
                ; use_full_commitment = not increment_receiver
                ; authorization_kind = None_given
                }
            ; authorization = None_given
            }
          ]
    ; memo = Signed_command_memo.empty
    }
  in
  let zkapp_command = Zkapp_command.of_wire zkapp_command_wire in
  (* We skip signing the commitment and updating the authorization as it is not necessary to have a valid transaction for these tests. *)
  let (`If_this_is_used_it_should_have_a_comment_justifying_it cmd) =
    User_command.to_valid_unsafe (User_command.Zkapp_command zkapp_command)
  in
  Transaction_hash.User_command_with_valid_signature.create cmd

let support_for_zkapp_command_commands () =
  let fee = Fee.minimum_user_command_fee in
  let amount = Amount.of_nanomina_int_exn @@ Fee.to_nanomina_int fee in
  let balance = Option.value_exn (Amount.scale amount 100) in
  let kp1 =
    Quickcheck.random_value ~seed:(`Deterministic "apple") Keypair.gen
  in
  let kp2 =
    Quickcheck.random_value ~seed:(`Deterministic "orange") Keypair.gen
  in
  let add_cmd = add_to_pool ~nonce:Account_nonce.zero ~balance in
  let make_cmd =
    make_zkapp_command_payment ~sender:kp1 ~receiver:kp2
      ~increment_receiver:false ~amount ~fee
  in
  Mina_ledger.Ledger.with_ledger ~depth:4 ~f:(fun ledger ->
      init_permissionless_ledger ledger
        [ (kp1.public_key, balance); (kp2.public_key, Amount.zero) ] ;
      let commit = commit_to_pool ledger in
      let cmd1 = make_cmd ~double_increment_sender:false 0 in
      let cmd2 = make_cmd ~double_increment_sender:false 1 in
      let cmd3 = make_cmd ~double_increment_sender:false 2 in
      let cmd4 = make_cmd ~double_increment_sender:false 3 in
      (* used to break the sequence *)
      let cmd3' = make_cmd ~double_increment_sender:true 2 in
      let pool =
        List.fold_left [ cmd1; cmd2; cmd3; cmd4 ] ~init:empty ~f:add_cmd
      in
      let pool = commit pool cmd1 [ cmd1 ] in
      let pool = commit pool cmd2 [ cmd2 ] in
      let _pool = commit pool cmd3' [ cmd3; cmd4 ] in
      () )

let nonce_increment_side_effects () =
  let fee = Fee.minimum_user_command_fee in
  let amount = Amount.of_nanomina_int_exn @@ Fee.to_nanomina_int fee in
  let balance = Option.value_exn (Amount.scale amount 100) in
  let kp1 =
    Quickcheck.random_value ~seed:(`Deterministic "apple") Keypair.gen
  in
  let kp2 =
    Quickcheck.random_value ~seed:(`Deterministic "orange") Keypair.gen
  in
  let add_cmd = add_to_pool ~nonce:Account_nonce.zero ~balance in
  let make_cmd = make_zkapp_command_payment ~amount ~fee in
  Mina_ledger.Ledger.with_ledger ~depth:4 ~f:(fun ledger ->
      init_permissionless_ledger ledger
        [ (kp1.public_key, balance); (kp2.public_key, balance) ] ;
      let kp1_cmd1 =
        make_cmd ~sender:kp1 ~receiver:kp2 ~double_increment_sender:false
          ~increment_receiver:true 0
      in
      let kp2_cmd1 =
        make_cmd ~sender:kp2 ~receiver:kp1 ~double_increment_sender:false
          ~increment_receiver:false 0
      in
      let kp2_cmd2 =
        make_cmd ~sender:kp2 ~receiver:kp1 ~double_increment_sender:false
          ~increment_receiver:false 1
      in
      let pool =
        List.fold_left [ kp1_cmd1; kp2_cmd1; kp2_cmd2 ] ~init:empty ~f:add_cmd
      in
      let _pool = commit_to_pool ledger pool kp1_cmd1 [ kp2_cmd1; kp1_cmd1 ] in
      () )

let nonce_invariant_violation () =
  let fee = Fee.minimum_user_command_fee in
  let amount = Amount.of_nanomina_int_exn @@ Fee.to_nanomina_int fee in
  let balance = Option.value_exn (Amount.scale amount 100) in
  let kp1 =
    Quickcheck.random_value ~seed:(`Deterministic "apple") Keypair.gen
  in
  let kp2 =
    Quickcheck.random_value ~seed:(`Deterministic "orange") Keypair.gen
  in
  let add_cmd = add_to_pool ~nonce:Account_nonce.zero ~balance in
  let make_cmd =
    make_zkapp_command_payment ~sender:kp1 ~receiver:kp2
      ~double_increment_sender:false ~increment_receiver:false ~amount ~fee
  in
  Mina_ledger.Ledger.with_ledger ~depth:4 ~f:(fun ledger ->
      init_permissionless_ledger ledger
        [ (kp1.public_key, balance); (kp2.public_key, Amount.zero) ] ;
      let cmd1 = make_cmd 0 in
      let cmd2 = make_cmd 1 in
      let pool = List.fold_left [ cmd1; cmd2 ] ~init:empty ~f:add_cmd in
      apply_to_ledger ledger cmd1 ;
      let _pool = commit_to_pool ledger pool cmd2 [ cmd1; cmd2 ] in
      () )

let get_nonce txn =
  let unchecked =
    Transaction_hash.User_command_with_valid_signature.forget_check txn
  in
  match unchecked.data with
  | Signed_command cmd ->
     cmd.payload.common.nonce
  | Zkapp_command cmd ->
     cmd.fee_payer.body.nonce

let sender_pk txn = 
  let unchecked =
    Transaction_hash.User_command_with_valid_signature.forget_check txn
  in
  match unchecked.data with
  | Signed_command cmd ->
     cmd.payload.common.fee_payer_pk
  | Zkapp_command cmd ->
     cmd.fee_payer.body.public_key

let rec rem_lowest_fee count pool =
  if count > 0 then
    rem_lowest_fee (count - 1) (Indexed_pool.remove_lowest_fee pool |> snd)
  else
    pool

module Stateful_gen = Monad_lib.State.Trans (Quickcheck.Generator)
module Stateful_gen_ext = Monad_lib.Make_ext2 (Stateful_gen)

let gen_amount =
  let open Stateful_gen in
  let open Let_syntax in
  let open Account.Poly in
  let%bind balance = getf (fun a -> a.balance) in
  let%bind amt = lift @@ Amount.(gen_incl zero @@ Balance.to_amount balance) in
  let%map () =
    modify ~f:(fun a ->
        { a with balance = Option.value_exn @@ Balance.sub_amount balance amt } )
  in
  Amount.to_uint64 amt

let rec gen_txns_from_single_sender_to receiver_public_key =
  let open Stateful_gen in
  let open Let_syntax in
  let open Account.Poly in
  let%bind sender = get in
  if Balance.(sender.balance = zero) then return []
  else
    let%bind () =
      modify ~f:(fun a -> { a with nonce = Account_nonce.succ a.nonce })
    in
    let%bind txn_amt = map ~f:Amount.of_uint64 gen_amount in
    let%bind txn_fee = map ~f:Fee.of_uint64 gen_amount in
    let cmd =
      let open Signed_command.Payload in
      Signed_command.Poly.
        { payload =
            Poly.
              { common =
                  Common.Poly.
                    { fee = txn_fee
                    ; fee_payer_pk = sender.public_key
                    ; nonce = sender.nonce
                    ; valid_until = Global_slot_since_genesis.max_value
                    ; memo = Signed_command_memo.dummy
                    }
              ; body =
                  Body.Payment
                    Payment_payload.Poly.
                      { receiver_pk = receiver_public_key; amount = txn_amt }
              }
        ; signer = Option.value_exn @@ Public_key.decompress sender.public_key
        ; signature = Signature.dummy
        }
    in
    let%map more = gen_txns_from_single_sender_to receiver_public_key in
    (* Signatures don't matter in these tests. *)
    let (`If_this_is_used_it_should_have_a_comment_justifying_it valid_cmd) =
      Signed_command.to_valid_unsafe cmd
    in
    valid_cmd :: more

(* Check that commands from a single sender, added into the mempool in a random
   order, are always returned for application in the order of increasing nonces
   without a gap. *)
let transactions_from_single_sender_ordered_by_nonce () =
  Quickcheck.test
    (let open Quickcheck.Generator.Let_syntax in
    let%bind s = Account.gen in
    let sender = { s with balance = Balance.max_int } in
    let%bind receiver = Account.gen in
    let%map txns =
      Stateful_gen.eval_state
        (gen_txns_from_single_sender_to receiver.public_key)
        sender
    in
    (sender, txns))
    ~f:(fun (sender, txns) ->
      let module Result_ext = Monad_lib.Make_ext2 (Result) in
      let pool =
        Result_ext.fold_m
          ~f:(fun (nonce, p) txn ->
            let open Result.Let_syntax in
            let t =
              Transaction_hash.User_command_with_valid_signature.create
                (User_command.Signed_command txn)
            in
            let%map _, p', _ =
              add_from_gossip_exn p t nonce (Balance.to_amount sender.balance)
            in
            (Account_nonce.succ nonce, p') )
          ~init:(sender.nonce, empty) txns
        |> Result.map_error ~f:(fun e ->
               Sexp.to_string @@ Command_error.sexp_of_t e )
        |> Result.ok_or_failwith |> snd |> Indexed_pool.remove_lowest_fee |> snd
      in
      let txns = Sequence.to_list @@ Indexed_pool.transactions ~logger pool in
      List.fold_left txns ~init:sender.nonce ~f:(fun nonce txn ->
          [%test_eq: Account_nonce.t] (get_nonce txn) nonce ;
          Account_nonce.succ nonce )
      |> ignore )

let rec interleave_at_random queues =
  let open Quickcheck in
  let open Generator.Let_syntax in
  if Array.is_empty queues then
    return []
  else
    let%bind i = Int.gen_incl 0 (Array.length queues - 1) in
    match queues.(i) with
    | [] ->
       Array.filter queues ~f:(fun q -> not @@ List.is_empty q)
       |> interleave_at_random
    | t :: ts ->
       Array.set queues i ts ;
       let%map more = interleave_at_random queues in
       t :: more

let transactions_from_many_senders_no_nonce_gaps () =
  Quickcheck.test
    (let open Quickcheck.Generator.Let_syntax in
     let module Gen_ext = Monad_lib.Make_ext(Quickcheck.Generator) in
     let%bind accounts = List.gen_non_empty Account.gen in
     let senders = List.map accounts  ~f:(fun s -> { s with balance = Balance.max_int }) in
     let%bind receiver = Account.gen in
     let%bind txns =
       List.map senders ~f:(Stateful_gen.eval_state (gen_txns_from_single_sender_to receiver.public_key))
       |> Gen_ext.sequence
     in
     let%map shuffled = interleave_at_random @@ Array.of_list txns in
    (senders, shuffled))
    ~f:(fun (senders, txns) ->
      let module Result_ext = Monad_lib.Make_ext2 (Result) in
      let module Pk_map = Public_key.Compressed.Map in
      let nonces =
        List.map senders ~f:(fun a -> (a.public_key, (a.balance, a.nonce)))
        |> Pk_map.of_alist_exn
      in
      let pool =
        Result_ext.fold_m
          ~f:(fun (nonces, p) txn ->
            let open Result.Let_syntax in
            let t =
              Transaction_hash.User_command_with_valid_signature.create
                (User_command.Signed_command txn)
            in
            let sender = sender_pk t in
            let (balance, nonce) = Pk_map.find_exn nonces sender in
            let%map _, p', _ =
              add_from_gossip_exn p t nonce (Balance.to_amount balance)
            in
            let nonces' =
              Pk_map.update nonces sender ~f:(function
                  | None -> (Balance.zero, Account_nonce.zero)
                  | Some (b, n) -> (b, Account_nonce.succ n) )
            in
            (nonces', p') )
          ~init:(nonces, empty) txns
        |> Result.map_error ~f:(fun e ->
               Sexp.to_string @@ Command_error.sexp_of_t e )
        |> Result.ok_or_failwith |> snd |> rem_lowest_fee 5
      in
      let txns = Sequence.to_list @@ Indexed_pool.transactions ~logger pool in
      List.fold_left txns ~init:nonces ~f:(fun nonces txn ->
          let sender = sender_pk txn in
          let nonce = Pk_map.find_exn nonces sender |> snd in
          [%test_eq: Account_nonce.t] (get_nonce txn) nonce ;
          Pk_map.update nonces sender ~f:(function
              | None -> (Balance.zero, Account_nonce.zero)
              | Some (b, n) -> (b, Account_nonce.succ n) ))
      |> ignore )
