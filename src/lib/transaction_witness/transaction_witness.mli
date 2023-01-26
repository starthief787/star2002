open Core_kernel

module Zkapp_command_segment_witness : sig
  open Mina_base
  open Mina_ledger
  open Currency

  [%%versioned:
  module Stable : sig
    module V1 : sig
      type t =
        { first_pass_global_ledger : Sparse_ledger.Stable.V2.t
        ; second_pass_global_ledger : Sparse_ledger.Stable.V2.t
        ; local_state_init :
            ( ( Token_id.Stable.V2.t
              , Zkapp_command.Call_forest.With_hashes.Stable.V1.t )
              Stack_frame.Stable.V1.t
            , ( ( ( Token_id.Stable.V2.t
                  , Zkapp_command.Call_forest.With_hashes.Stable.V1.t )
                  Stack_frame.Stable.V1.t
                , Stack_frame.Digest.Stable.V1.t )
                With_hash.t
              , Call_stack_digest.Stable.V1.t )
              With_stack_hash.Stable.V1.t
              list
            , Token_id.Stable.V2.t
            , (Amount.Stable.V1.t, Sgn.Stable.V1.t) Signed_poly.Stable.V1.t
            , Sparse_ledger.Stable.V2.t
            , bool
            , Kimchi_backend.Pasta.Basic.Fp.Stable.V1.t
            , Mina_numbers.Index.Stable.V1.t
            , Transaction_status.Failure.Collection.Stable.V1.t )
            Mina_transaction_logic.Zkapp_command_logic.Local_state.Stable.V1.t
        ; start_zkapp_command :
            ( Zkapp_command.Stable.V1.t
            , Kimchi_backend.Pasta.Basic.Fp.Stable.V1.t
            , bool )
            Mina_transaction_logic.Zkapp_command_logic.Start_data.Stable.V1.t
            list
        ; state_body : Mina_state.Protocol_state.Body.Value.Stable.V2.t
        ; init_stack : Pending_coinbase.Stack_versioned.Stable.V1.t
        ; block_global_slot : Mina_numbers.Global_slot.Stable.V1.t
        }
      [@@deriving sexp, to_yojson]
    end
  end]
end

[%%versioned:
module Stable : sig
  module V2 : sig
    type t =
      { transaction : Mina_transaction.Transaction.Stable.V2.t
      ; ledger : Mina_ledger.Sparse_ledger.Stable.V2.t
      ; protocol_state_body : Mina_state.Protocol_state.Body.Value.Stable.V2.t
      ; init_stack : Mina_base.Pending_coinbase.Stack_versioned.Stable.V1.t
      ; status : Mina_base.Transaction_status.Stable.V2.t
      ; block_global_slot : Mina_numbers.Global_slot.Stable.V1.t
      }
    [@@deriving sexp, to_yojson]
  end
end]
