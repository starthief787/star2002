open Core
open Signature_lib
open Merkle_ledger

module Ledger_inner = struct
  module Location_at_depth : Merkle_ledger.Location_intf.S =
    Merkle_ledger.Location.T

  module Location_binable = struct
    module Arg = struct
      type t = Location_at_depth.t =
        | Generic of Location.Bigstring.Stable.Latest.t
        | Account of Location_at_depth.Addr.Stable.Latest.t
        | Hash of Location_at_depth.Addr.Stable.Latest.t
      [@@deriving bin_io_unversioned, hash, sexp, compare]
    end

    type t = Arg.t =
      | Generic of Location.Bigstring.t
      | Account of Location_at_depth.Addr.t
      | Hash of Location_at_depth.Addr.t
    [@@deriving hash, sexp, compare]

    include Hashable.Make_binable (Arg) [@@deriving sexp, compare, hash, yojson]
  end

  module Kvdb : Intf.Key_value_database with type config := string =
    Rocksdb.Database

  module Storage_locations : Intf.Storage_locations = struct
    let key_value_db_dir = "coda_key_value_db"
  end

  module Hash = struct
    module Arg = struct
      type t = Ledger_hash.Stable.Latest.t
      [@@deriving sexp, compare, hash, bin_io_unversioned]
    end

    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = Ledger_hash.Stable.V1.t
        [@@deriving sexp, compare, hash, equal, yojson]

        type _unused = unit constraint t = Arg.t

        let to_latest = Fn.id

        include Hashable.Make_binable (Arg)

        let to_string = Ledger_hash.to_string

        let merge = Ledger_hash.merge

        let hash_account = Fn.compose Ledger_hash.of_digest Account.digest

        let empty_account = Ledger_hash.of_digest Account.empty_digest
      end
    end]
  end

  module Account = struct
    [%%versioned
    module Stable = struct
      module V2 = struct
        type t = Account.Stable.V2.t [@@deriving equal, compare, sexp]

        let to_latest = Fn.id

        let identifier = Account.identifier

        let balance Account.Poly.{ balance; _ } = balance

        let token Account.Poly.{ token_id; _ } = token_id

        let empty = Account.empty

        let token_owner ({ token_permissions; _ } : t) =
          match token_permissions with
          | Token_owned _ ->
              true
          | Not_owned _ ->
              false
      end

      module V1 = struct
        type t = Account.Stable.V1.t [@@deriving equal, compare, sexp]

        let to_latest = Account.Stable.V1.to_latest
      end
    end]

    let empty = Stable.Latest.empty

    let initialize = Account.initialize
  end

  module Inputs = struct
    module Key = Public_key.Compressed
    module Token_id = Token_id
    module Account_id = Account_id
    module Balance = Currency.Balance
    module Account = Account.Stable.Latest
    module Hash = Hash.Stable.Latest
    module Kvdb = Kvdb
    module Location = Location_at_depth
    module Location_binable = Location_binable
    module Storage_locations = Storage_locations
  end

  module Db :
    Merkle_ledger.Database_intf.S
      with module Location = Location_at_depth
      with module Addr = Location_at_depth.Addr
      with type root_hash := Ledger_hash.t
       and type hash := Ledger_hash.t
       and type key := Public_key.Compressed.t
       and type token_id := Token_id.t
       and type token_id_set := Token_id.Set.t
       and type account := Account.t
       and type account_id_set := Account_id.Set.t
       and type account_id := Account_id.t =
    Database.Make (Inputs)

  module Null = Null_ledger.Make (Inputs)

  module Any_ledger :
    Merkle_ledger.Any_ledger.S
      with module Location = Location_at_depth
      with type account := Account.t
       and type key := Public_key.Compressed.t
       and type token_id := Token_id.t
       and type token_id_set := Token_id.Set.t
       and type account_id := Account_id.t
       and type account_id_set := Account_id.Set.t
       and type hash := Hash.t =
    Merkle_ledger.Any_ledger.Make_base (Inputs)

  module Mask :
    Merkle_mask.Masking_merkle_tree_intf.S
      with module Location = Location_at_depth
       and module Attached.Addr = Location_at_depth.Addr
      with type account := Account.t
       and type key := Public_key.Compressed.t
       and type token_id := Token_id.t
       and type token_id_set := Token_id.Set.t
       and type account_id := Account_id.t
       and type account_id_set := Account_id.Set.t
       and type hash := Hash.t
       and type location := Location_at_depth.t
       and type parent := Any_ledger.M.t =
  Merkle_mask.Masking_merkle_tree.Make (struct
    include Inputs
    module Base = Any_ledger.M
  end)

  module Maskable :
    Merkle_mask.Maskable_merkle_tree_intf.S
      with module Location = Location_at_depth
      with module Addr = Location_at_depth.Addr
      with type account := Account.t
       and type key := Public_key.Compressed.t
       and type token_id := Token_id.t
       and type token_id_set := Token_id.Set.t
       and type account_id := Account_id.t
       and type account_id_set := Account_id.Set.t
       and type hash := Hash.t
       and type root_hash := Hash.t
       and type unattached_mask := Mask.t
       and type attached_mask := Mask.Attached.t
       and type t := Any_ledger.M.t =
  Merkle_mask.Maskable_merkle_tree.Make (struct
    include Inputs
    module Base = Any_ledger.M
    module Mask = Mask

    let mask_to_base m = Any_ledger.cast (module Mask.Attached) m
  end)

  include Mask.Attached
  module Debug = Maskable.Debug

  type maskable_ledger = t

  let of_database db =
    let casted = Any_ledger.cast (module Db) db in
    let mask = Mask.create ~depth:(Db.depth db) () in
    Maskable.register_mask casted mask

  (* Mask.Attached.create () fails, can't create an attached mask directly
     shadow create in order to create an attached mask
  *)
  let create ?directory_name ~depth () =
    of_database (Db.create ?directory_name ~depth ())

  let create_ephemeral_with_base ~depth () =
    let maskable = Null.create ~depth () in
    let casted = Any_ledger.cast (module Null) maskable in
    let mask = Mask.create ~depth () in
    (casted, Maskable.register_mask casted mask)

  let create_ephemeral ~depth () =
    let _base, mask = create_ephemeral_with_base ~depth () in
    mask

  let with_ledger ~depth ~f =
    let ledger = create ~depth () in
    try
      let result = f ledger in
      close ledger ; result
    with exn -> close ledger ; raise exn

  let with_ephemeral_ledger ~depth ~f =
    let _base_ledger, masked_ledger = create_ephemeral_with_base ~depth () in
    try
      let result = f masked_ledger in
      let (_ : Mask.t) =
        Maskable.unregister_mask_exn ~loc:__LOC__ ~grandchildren:`Recursive
          masked_ledger
      in
      result
    with exn ->
      let (_ : Mask.t) =
        Maskable.unregister_mask_exn ~loc:__LOC__ ~grandchildren:`Recursive
          masked_ledger
      in
      raise exn

  let packed t = Any_ledger.cast (module Mask.Attached) t

  let register_mask t mask = Maskable.register_mask (packed t) mask

  let unregister_mask_exn ~loc mask = Maskable.unregister_mask_exn ~loc mask

  let remove_and_reparent_exn t t_as_mask =
    Maskable.remove_and_reparent_exn (packed t) t_as_mask

  type unattached_mask = Mask.t

  type attached_mask = Mask.Attached.t

  (* inside MaskedLedger, the functor argument has assigned to location, account, and path
     but the module signature for the functor result wants them, so we declare them here *)
  type location = Location.t

  (* TODO: Don't allocate: see Issue #1191 *)
  let fold_until t ~init ~f ~finish =
    let accounts = to_list t in
    List.fold_until accounts ~init ~f ~finish

  let create_new_account_exn t account_id account =
    let action, _ =
      get_or_create_account t account_id account |> Or_error.ok_exn
    in
    if [%equal: [ `Existed | `Added ]] action `Existed then
      failwith
        (sprintf
           !"Could not create a new account with pk \
             %{sexp:Public_key.Compressed.t}: Account already exists"
           (Account_id.public_key account_id))

  (* shadows definition in MaskedLedger, extra assurance hash is of right type  *)
  let merkle_root t =
    Ledger_hash.of_hash (merkle_root t :> Random_oracle.Digest.t)

  let get_or_create ledger account_id =
    let open Or_error.Let_syntax in
    let%bind action, loc =
      get_or_create_account ledger account_id (Account.initialize account_id)
    in
    let%map account =
      Result.of_option (get ledger loc)
        ~error:
          (Error.of_string
             "get_or_create: Account was not found in the ledger after creation")
    in
    (action, account, loc)

  let create_empty_exn ledger account_id =
    let start_hash = merkle_root ledger in
    match
      get_or_create_account ledger account_id Account.empty |> Or_error.ok_exn
    with
    | `Existed, _ ->
        failwith "create_empty for a key already present"
    | `Added, new_loc ->
        Debug_assert.debug_assert (fun () ->
            [%test_eq: Ledger_hash.t] start_hash (merkle_root ledger)) ;
        (merkle_path ledger new_loc, Account.empty)

  let _handler t =
    let open Snark_params.Tick in
    let path_exn idx =
      List.map (merkle_path_at_index_exn t idx) ~f:(function
        | `Left h ->
            h
        | `Right h ->
            h)
    in
    stage (fun (With { request; respond }) ->
        match request with
        | Ledger_hash.Get_element idx ->
            let elt = get_at_index_exn t idx in
            let path = (path_exn idx :> Random_oracle.Digest.t list) in
            respond (Provide (elt, path))
        | Ledger_hash.Get_path idx ->
            let path = (path_exn idx :> Random_oracle.Digest.t list) in
            respond (Provide path)
        | Ledger_hash.Set (idx, account) ->
            set_at_index_exn t idx account ;
            respond (Provide ())
        | Ledger_hash.Find_index pk ->
            let index = index_of_account_exn t pk in
            respond (Provide index)
        | _ ->
            unhandled)
end

include Ledger_inner
include Transaction_logic.Make (Ledger_inner)

type init_state =
  ( Signature_lib.Keypair.t
  * Currency.Amount.t
  * Mina_numbers.Account_nonce.t
  * Account_timing.t )
  array
[@@deriving sexp_of]

let gen_initial_ledger_state : init_state Quickcheck.Generator.t =
  let open Quickcheck.Generator.Let_syntax in
  let%bind n_accounts = Int.gen_incl 2 10 in
  let%bind keypairs = Quickcheck_lib.replicate_gen Keypair.gen n_accounts in
  let%bind balances =
    let gen_balance =
      let%map whole_balance = Int.gen_incl 500_000_000 1_000_000_000 in
      Currency.Amount.of_int (whole_balance * 1_000_000_000)
    in
    Quickcheck_lib.replicate_gen gen_balance n_accounts
  in
  let%bind nonces =
    Quickcheck_lib.replicate_gen
      ( Quickcheck.Generator.map ~f:Mina_numbers.Account_nonce.of_int
      @@ Int.gen_incl 0 1000 )
      n_accounts
  in
  let rec zip3_exn a b c =
    match (a, b, c) with
    | [], [], [] ->
        []
    | x :: xs, y :: ys, z :: zs ->
        (x, y, z, Account_timing.Untimed) :: zip3_exn xs ys zs
    | _ ->
        failwith "zip3 unequal lengths"
  in
  return @@ Array.of_list @@ zip3_exn keypairs balances nonces

let apply_initial_ledger_state : t -> init_state -> unit =
 fun t accounts ->
  Array.iter accounts ~f:(fun (kp, balance, nonce, timing) ->
      let pk_compressed = Public_key.compress kp.public_key in
      let account_id = Account_id.create pk_compressed Token_id.default in
      let account = Account.initialize account_id in
      let account' =
        { account with
          balance = Currency.Balance.of_int (Currency.Amount.to_int balance)
        ; nonce
        ; timing
        }
      in
      create_new_account_exn t account_id account')

module Snapp_generators = struct
  (* Ledger depends on Party, so Party generators can't refer back to Ledger
     so we put the generators that rely on a ledger here
  *)

  (* Account is shadowed in Ledger_inner, above *)
  module Account = Mina_base__Account

  let gen_predicate_from ?(succeed = true) ~pk ~ledger =
    (* construct predicate using pk and ledger
       don't return Accept, which would ignore those inputs
    *)
    let open Quickcheck.Let_syntax in
    let acct_id = Account_id.create pk Token_id.default in
    match location_of_account ledger acct_id with
    | None ->
        (* account not in the ledger, can't create a meaningful Full or Nonce *)
        if succeed then
          failwithf "gen_from: account with public key %s not in ledger"
            (Public_key.Compressed.to_base58_check pk)
            ()
        else
          (* nonce not connected with any particular account *)
          let%map nonce = Account.Nonce.gen in
          Party.Predicate.Nonce nonce
    | Some loc -> (
        match get ledger loc with
        | None ->
            failwith
              "gen_predicate_from: could not find account with known location"
        | Some account ->
            let%bind b = Quickcheck.Generator.bool in
            let { Account.Poly.public_key
                ; balance
                ; nonce
                ; receipt_chain_hash
                ; delegate
                ; snapp
                ; _
                } =
              account
            in
            (* choose constructor *)
            if b then
              (* Full *)
              let open Snapp_basic in
              let%bind (predicate_account : Snapp_predicate.Account.t) =
                let balance =
                  Or_ignore.Check
                    { Snapp_predicate.Closed_interval.lower = balance
                    ; upper = balance
                    }
                in
                let nonce =
                  Or_ignore.Check
                    { Snapp_predicate.Closed_interval.lower = nonce
                    ; upper = nonce
                    }
                in
                let receipt_chain_hash = Or_ignore.Check receipt_chain_hash in
                let public_key = Or_ignore.Check public_key in
                let delegate =
                  match delegate with
                  | None ->
                      Or_ignore.Ignore
                  | Some pk ->
                      Or_ignore.Check pk
                in
                let%bind state, rollup_state, proved_state =
                  match snapp with
                  | None ->
                      (* won't raise, correct length given *)
                      let state =
                        Snapp_state.V.of_list_exn
                          (List.init 8 ~f:(fun _ -> Or_ignore.Ignore))
                      in
                      let rollup_state = Or_ignore.Ignore in
                      let proved_state = Or_ignore.Ignore in
                      return (state, rollup_state, proved_state)
                  | Some { app_state; rollup_state; proved_state; _ } ->
                      let state =
                        Snapp_state.V.map app_state ~f:(fun field ->
                            Or_ignore.Check field)
                      in
                      let%bind rollup_state =
                        (* choose a value from account rollup state *)
                        let fields =
                          Pickles_types.Vector.Vector_5.to_list rollup_state
                        in
                        let%bind ndx =
                          Int.gen_uniform_incl 0 (List.length fields - 1)
                        in
                        return (Or_ignore.Check (List.nth_exn fields ndx))
                      in
                      let proved_state = Or_ignore.Check proved_state in
                      return (state, rollup_state, proved_state)
                in
                return
                  { Snapp_predicate.Account.Poly.balance
                  ; nonce
                  ; receipt_chain_hash
                  ; public_key
                  ; delegate
                  ; state
                  ; rollup_state
                  ; proved_state
                  }
              in
              if succeed then return (Party.Predicate.Full predicate_account)
              else
                let%bind faulty_predicate_account =
                  (* tamper with account using randomly chosen item *)
                  let tamperable =
                    [ "balance"
                    ; "nonce"
                    ; "receipt_chain_hash"
                    ; "delegate"
                    ; "state"
                    ; "rollup_state"
                    ; "proved_state"
                    ]
                  in
                  match%bind Quickcheck.Generator.of_list tamperable with
                  | "balance" ->
                      let new_balance =
                        if Currency.Balance.equal balance Currency.Balance.zero
                        then Currency.Balance.max_int
                        else Currency.Balance.zero
                      in
                      let%bind balance =
                        Snapp_predicate.Numeric.gen (return new_balance)
                          Currency.Balance.compare
                      in
                      return { predicate_account with balance }
                  | "nonce" ->
                      let new_nonce =
                        if Account.Nonce.equal nonce Account.Nonce.zero then
                          Account.Nonce.max_value
                        else Account.Nonce.zero
                      in
                      let%bind nonce =
                        Snapp_predicate.Numeric.gen (return new_nonce)
                          Account.Nonce.compare
                      in
                      return { predicate_account with nonce }
                  | "receipt_chain_hash" ->
                      let%bind new_receipt_chain_hash =
                        Receipt.Chain_hash.gen
                      in
                      let%bind receipt_chain_hash =
                        Or_ignore.gen (return new_receipt_chain_hash)
                      in
                      return { predicate_account with receipt_chain_hash }
                  | "delegate" ->
                      let%bind delegate =
                        Or_ignore.gen Public_key.Compressed.gen
                      in
                      return { predicate_account with delegate }
                  | "state" ->
                      (* TODO: replace one field, is that OK? *)
                      let fields =
                        Snapp_state.V.to_list predicate_account.state
                        |> Array.of_list
                      in
                      let%bind ndx = Int.gen_incl 0 (Array.length fields - 1) in
                      let%bind field = Snark_params.Tick.Field.gen in
                      fields.(ndx) <- Or_ignore.Check field ;
                      let state =
                        Snapp_state.V.of_list_exn (Array.to_list fields)
                      in
                      return { predicate_account with state }
                  | "rollup_state" ->
                      let%bind field = Snark_params.Tick.Field.gen in
                      let rollup_state = Or_ignore.Check field in
                      return { predicate_account with rollup_state }
                  | "proved_state" ->
                      let%bind proved_state =
                        match predicate_account.proved_state with
                        | Check b ->
                            return (Or_ignore.Check (not b))
                        | Ignore ->
                            let%bind b' = Quickcheck.Generator.bool in
                            return (Or_ignore.Check b')
                      in
                      return { predicate_account with proved_state }
                  | s ->
                      failwithf "gen_from: unknown account item %s" s ()
                in
                return (Party.Predicate.Full faulty_predicate_account)
            else
              (* Nonce *)
              let { Account.Poly.nonce; _ } = account in
              if succeed then return (Party.Predicate.Nonce nonce)
              else return (Party.Predicate.Nonce (Account.Nonce.succ nonce)) )

  let gen_predicated_from ?(succeed = true) ~ledger =
    let open Quickcheck.Let_syntax in
    let%bind body = Party.Body.gen () in
    let pk = body.Party.Body.Poly.pk in
    let%map predicate = gen_predicate_from ~succeed ~pk ~ledger in
    Party.Predicated.Poly.{ body; predicate }

  let gen_party_from ?(succeed = true) ~ledger =
    let open Quickcheck.Let_syntax in
    let%bind data = gen_predicated_from ~succeed ~ledger in
    let%map authorization = Control.gen_with_dummies in
    { Party.data; authorization }

  let gen_parties_from ?(succeed = true) ~(keypair : Keypair.t) ~ledger
      ~protocol_state =
    let max_parties = 6 in
    let open Quickcheck.Let_syntax in
    let pk = Signature_lib.Public_key.compress keypair.public_key in
    let%bind fee_payer = Party.Signed.gen ~pk () in
    (* at least 1 party, so that `succeed` affects at least one predicate *)
    let%bind num_parties = Int.gen_uniform_incl 1 max_parties in
    let%bind other_parties =
      Quickcheck.Generator.list_with_length num_parties
        (gen_party_from ~succeed ~ledger)
    in
    let parties : Parties.t = { fee_payer; other_parties; protocol_state } in
    (* replace dummy signature in fee payer *)
    let signature =
      Signature_lib.Schnorr.sign keypair.private_key
        (Random_oracle.Input.field
           ( Parties.commitment parties
           |> Parties.Transaction_commitment.with_fee_payer
                ~fee_payer_hash:
                  (Party.Predicated.digest
                     (Party.Predicated.of_signed parties.fee_payer.data)) ))
    in
    return
      { parties with
        fee_payer = { parties.fee_payer with authorization = signature }
      }
end

let%test_unit "parties payment test" =
  let open Transaction_logic.For_tests in
  let module L = Ledger_inner in
  Quickcheck.test ~trials:1 Test_spec.gen ~f:(fun { init_ledger; specs } ->
      let ts1 : Signed_command.t list = List.map specs ~f:command_send in
      let ts2 : Parties.t list = List.map specs ~f:party_send in
      L.with_ledger ~depth ~f:(fun l1 ->
          L.with_ledger ~depth ~f:(fun l2 ->
              Init_ledger.init (module L) init_ledger l1 ;
              Init_ledger.init (module L) init_ledger l2 ;
              let open Result.Let_syntax in
              let%bind () =
                iter_err ts1 ~f:(fun t ->
                    apply_user_command_unchecked l1 t ~constraint_constants
                      ~txn_global_slot)
              in
              let%bind () =
                iter_err ts2 ~f:(fun t ->
                    apply_parties_unchecked l2 t ~constraint_constants
                      ~state_view:view)
              in
              let accounts = List.concat_map ~f:Parties.accounts_accessed ts2 in
              test_eq (module L) accounts l1 l2))
      |> Or_error.ok_exn)
