open Async_kernel
open Core_kernel
open Pipe_lib.Strict_pipe
open Mina_base
open Mina_state
open Cache_lib
open Mina_block
open Network_peer

module type CONTEXT = sig
  val logger : Logger.t

  val precomputed_values : Precomputed_values.t

  val constraint_constants : Genesis_constants.Constraint_constants.t

  val consensus_constants : Consensus.Constants.t
end

let validate_transition ~context:(module Context : CONTEXT) ~frontier
    ~unprocessed_transition_cache enveloped_transition =
  let module Context = struct
    include Context

    let logger =
      Logger.extend logger
        [ ("selection_context", `String "Transition_handler.Validator") ]
  end in
  let open Result.Let_syntax in
  let transition =
    Envelope.Incoming.data enveloped_transition
    |> Mina_block.Validation.block_with_hash
  in
  let transition_hash = State_hash.With_state_hashes.state_hash transition in
  let root_breadcrumb = Transition_frontier.root frontier in
  let%bind () =
    Option.fold
      (Transition_frontier.find frontier transition_hash)
      ~init:Result.(Ok ())
      ~f:(fun _ _ -> Result.Error (`In_frontier transition_hash))
  in
  let%bind () =
    Option.fold
      (Unprocessed_transition_cache.final_state unprocessed_transition_cache
         enveloped_transition )
      ~init:Result.(Ok ())
      ~f:(fun _ final_state -> Result.Error (`In_process final_state))
  in
  let%map () =
    Result.ok_if_true
      (Consensus.Hooks.equal_select_status `Take
         (Consensus.Hooks.select
            ~context:(module Context)
            ~existing:
              (Transition_frontier.Breadcrumb.consensus_state_with_hashes
                 root_breadcrumb )
            ~candidate:(With_hash.map ~f:Mina_block.consensus_state transition) ) )
      ~error:`Disconnected
  in
  (* we expect this to be Ok since we just checked the cache *)
  Unprocessed_transition_cache.register_exn unprocessed_transition_cache
    enveloped_transition

let run ~context:(module Context : CONTEXT) ~time_controller ~frontier
    ~transition_reader
    ~(valid_transition_writer :
       ( [ `Block of
           ( Mina_block.initial_valid_block Envelope.Incoming.t
           , State_hash.t )
           Cached.t ]
         * [ `Valid_cb of Mina_net2.Validation_callback.t option ]
       , drop_head buffered
       , unit )
       Writer.t ) ~unprocessed_transition_cache =
  let open Context in
  let module Lru = Core_extended_cache.Lru in
  O1trace.background_thread "validate_blocks_against_frontier" (fun () ->
      Reader.iter transition_reader
        ~f:(fun (`Block transition_env, `Valid_cb vc) ->
          let transition_with_hash, _ = Envelope.Incoming.data transition_env in
          let transition_hash =
            State_hash.With_state_hashes.state_hash transition_with_hash
          in
          let transition = With_hash.data transition_with_hash in
          let sender = Envelope.Incoming.sender transition_env in
          match
            validate_transition
              ~context:(module Context)
              ~frontier ~unprocessed_transition_cache transition_env
          with
          | Ok cached_transition ->
              [%log info] "Sent useful gossip"
                ~metadata:
                  [ ("state_hash", State_hash.to_yojson transition_hash)
                  ; ("transition", Mina_block.to_yojson transition)
                  ] ;
              let transition_time =
                Mina_block.header transition
                |> Header.protocol_state |> Protocol_state.blockchain_state
                |> Blockchain_state.timestamp |> Block_time.to_time_exn
              in
              Perf_histograms.add_span
                ~name:"accepted_transition_remote_latency"
                (Core_kernel.Time.diff
                   Block_time.(now time_controller |> to_time_exn)
                   transition_time ) ;
              return
              @@ Writer.write valid_transition_writer
                   (`Block cached_transition, `Valid_cb vc)
          | Error (`In_frontier _) | Error (`In_process _) ->
              [%log info] "Sent old gossip"
                ~metadata:
                  [ ("state_hash", State_hash.to_yojson transition_hash)
                  ; ("transition", Mina_block.to_yojson transition)
                  ] ;
              Deferred.unit
          | Error `Disconnected ->
              Mina_metrics.(Counter.inc_one Rejected_blocks.worse_than_root) ;
              [%log error]
                "Rejected block with state hash $state_hash from $sender, not \
                 connected to our chain"
                ~metadata:
                  [ ("state_hash", State_hash.to_yojson transition_hash)
                  ; ("reason", `String "not selected over current root")
                  ; ( "protocol_state"
                    , Header.protocol_state (Mina_block.header transition)
                      |> Protocol_state.value_to_yojson )
                  ; ("sender", Envelope.Sender.to_yojson sender)
                  ; ("transition", Mina_block.to_yojson transition)
                  ] ;
              Deferred.unit ) )
