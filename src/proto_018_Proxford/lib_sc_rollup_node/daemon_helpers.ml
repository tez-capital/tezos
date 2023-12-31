(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
(* Copyright (c) 2023 TriliTech <contact@trili.tech>                         *)
(* Copyright (c) 2023 Functori, <contact@functori.com>                       *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Protocol
open Alpha_context
open Apply_results

let check_pvm_initial_state_hash {Node_context.cctxt; rollup_address; kind; _} =
  let open Lwt_result_syntax in
  let module PVM = (val Pvm.of_kind kind) in
  let* l1_reference_initial_state_hash =
    RPC.Sc_rollup.initial_pvm_state_hash
      (new Protocol_client_context.wrap_full cctxt)
      (cctxt#chain, cctxt#block)
      rollup_address
  in
  let*! s = PVM.initial_state ~empty:(PVM.State.empty ()) in
  let*! l2_initial_state_hash = PVM.state_hash s in
  let l1_reference_initial_state_hash =
    Sc_rollup_proto_types.State_hash.to_octez l1_reference_initial_state_hash
  in
  let l2_initial_state_hash =
    Sc_rollup_proto_types.State_hash.to_octez l2_initial_state_hash
  in
  fail_unless
    Octez_smart_rollup.State_hash.(
      l1_reference_initial_state_hash = l2_initial_state_hash)
    (Sc_rollup_node_errors.Wrong_initial_pvm_state
       {
         initial_state_hash = l2_initial_state_hash;
         expected_state_hash = l1_reference_initial_state_hash;
       })

(** Returns [Some c] if [their_commitment] is refutable where [c] is our
      commitment for the same inbox level. *)
let is_refutable_commitment node_ctxt
    (their_commitment : Sc_rollup.Commitment.t) their_commitment_hash =
  let open Lwt_result_syntax in
  let* l2_block =
    Node_context.get_l2_block_by_level
      node_ctxt
      (Raw_level.to_int32 their_commitment.inbox_level)
  in
  let* our_commitment_and_hash =
    Option.filter_map_es
      (fun hash ->
        let hash = Sc_rollup_proto_types.Commitment_hash.of_octez hash in
        let+ commitment = Node_context.find_commitment node_ctxt hash in
        Option.map (fun c -> (c, hash)) commitment)
      l2_block.header.commitment_hash
  in
  match our_commitment_and_hash with
  | Some (our_commitment, our_commitment_hash)
    when Sc_rollup.Commitment.Hash.(
           their_commitment_hash <> our_commitment_hash
           && their_commitment.predecessor = our_commitment.predecessor) ->
      return our_commitment_and_hash
  | _ -> return_none

(** Publish a commitment when an accuser node sees a refutable commitment. *)
let accuser_publish_commitment_when_refutable node_ctxt ~other rollup
    their_commitment their_commitment_hash =
  let open Lwt_result_syntax in
  when_ (Node_context.is_accuser node_ctxt) @@ fun () ->
  (* We are seeing a commitment from someone else. We check if we agree
     with it, otherwise the accuser publishes our commitment in order to
     play the refutation game. *)
  let* refutable =
    is_refutable_commitment node_ctxt their_commitment their_commitment_hash
  in
  match refutable with
  | None -> return_unit
  | Some (our_commitment, our_commitment_hash) ->
      let*! () =
        Refutation_game_event.potential_conflict_detected
          ~our_commitment_hash
          ~their_commitment_hash
          ~level:(Raw_level.to_int32 their_commitment.inbox_level)
          ~other
      in
      assert (Sc_rollup.Address.(node_ctxt.rollup_address = rollup)) ;
      Publisher.publish_single_commitment node_ctxt our_commitment

(** Process an L1 SCORU operation (for the node's rollup) which is included
      for the first time. {b Note}: this function does not process inboxes for
      the rollup, which is done instead by {!Inbox.process_head}. *)
let process_included_l1_operation (type kind) (node_ctxt : Node_context.rw)
    (head : Layer1.header) ~source (operation : kind manager_operation)
    (result : kind successful_manager_operation_result) =
  let open Lwt_result_syntax in
  match (operation, result) with
  | ( Sc_rollup_publish {commitment; _},
      Sc_rollup_publish_result {published_at_level; _} )
    when Node_context.is_operator node_ctxt source ->
      (* Published commitment --------------------------------------------- *)
      let save_lpc =
        match Reference.get node_ctxt.lpc with
        | None -> true
        | Some lpc ->
            Raw_level.to_int32 commitment.inbox_level >= lpc.inbox_level
      in
      let commitment = Sc_rollup_proto_types.Commitment.to_octez commitment in
      if save_lpc then Reference.set node_ctxt.lpc (Some commitment) ;
      let commitment_hash = Octez_smart_rollup.Commitment.hash commitment in
      let* () =
        Node_context.set_commitment_published_at_level
          node_ctxt
          commitment_hash
          {
            first_published_at_level = Raw_level.to_int32 published_at_level;
            published_at_level = Some head.Layer1.level;
          }
      in
      let*! () =
        Commitment_event.last_published_commitment_updated
          commitment_hash
          head.Layer1.level
      in
      return_unit
  | ( Sc_rollup_publish {commitment = their_commitment; rollup},
      Sc_rollup_publish_result
        {published_at_level; staked_hash = their_commitment_hash; _} ) ->
      (* Commitment published by someone else *)
      (* We first register the publication information *)
      let* known_commitment =
        Node_context.commitment_exists node_ctxt their_commitment_hash
      in
      let* () =
        if not known_commitment then return_unit
        else
          let* republication =
            Node_context.commitment_was_published
              node_ctxt
              ~source:Anyone
              their_commitment_hash
          in
          if republication then return_unit
          else
            let* () =
              Node_context.set_commitment_published_at_level
                node_ctxt
                their_commitment_hash
                {
                  first_published_at_level =
                    Raw_level.to_int32 published_at_level;
                  published_at_level = None;
                }
            in
            return_unit
      in
      (* An accuser node will publish its commitment if the other one is
         refutable. *)
      accuser_publish_commitment_when_refutable
        node_ctxt
        ~other:source
        rollup
        their_commitment
        their_commitment_hash
  | ( Sc_rollup_cement _,
      Sc_rollup_cement_result {inbox_level; commitment_hash; _} ) ->
      (* Cemented commitment ---------------------------------------------- *)
      let proto_commitment_hash = commitment_hash in
      let inbox_level = Raw_level.to_int32 inbox_level in
      let commitment_hash =
        Sc_rollup_proto_types.Commitment_hash.to_octez commitment_hash
      in
      let* inbox_block =
        Node_context.get_l2_block_by_level node_ctxt inbox_level
      in
      let*? () =
        (* We stop the node if we disagree with a cemented commitment *)
        let our_commitment_hash = inbox_block.header.commitment_hash in
        error_unless
          (Option.equal
             Octez_smart_rollup.Commitment.Hash.( = )
             our_commitment_hash
             (Some commitment_hash))
          (Sc_rollup_node_errors.Disagree_with_cemented
             {inbox_level; ours = our_commitment_hash; on_l1 = commitment_hash})
      in
      let lcc = Reference.get node_ctxt.lcc in
      let*! () =
        if inbox_level > lcc.level then (
          Reference.set
            node_ctxt.lcc
            {commitment = proto_commitment_hash; level = inbox_level} ;
          Commitment_event.last_cemented_commitment_updated
            proto_commitment_hash
            inbox_level)
        else Lwt.return_unit
      in
      return_unit
  | ( Sc_rollup_refute _,
      Sc_rollup_refute_result {game_status = Ended end_status; _} )
  | ( Sc_rollup_timeout _,
      Sc_rollup_timeout_result {game_status = Ended end_status; _} ) -> (
      match end_status with
      | Loser {loser; reason} when Node_context.is_operator node_ctxt loser ->
          let result =
            match reason with
            | Conflict_resolved -> Sc_rollup_node_errors.Conflict_resolved
            | Timeout -> Timeout
          in
          tzfail (Sc_rollup_node_errors.Lost_game result)
      | Loser _ ->
          (* Other player lost *)
          return_unit
      | Draw ->
          let stakers =
            match operation with
            | Sc_rollup_refute {opponent; _} -> [source; opponent]
            | Sc_rollup_timeout {stakers = {alice; bob}; _} -> [alice; bob]
            | _ -> assert false
          in
          fail_when
            (List.exists (Node_context.is_operator node_ctxt) stakers)
            (Sc_rollup_node_errors.Lost_game Draw))
  | Dal_publish_slot_header _, Dal_publish_slot_header_result {slot_header; _}
    when Node_context.dal_supported node_ctxt ->
      let* () =
        Node_context.save_slot_header
          node_ctxt
          ~published_in_block_hash:head.Layer1.hash
          (Sc_rollup_proto_types.Dal.Slot_header.to_octez slot_header)
      in
      return_unit
  | _, _ ->
      (* Other manager operations *)
      return_unit

let process_l1_operation (type kind) node_ctxt (head : Layer1.header) ~source
    (operation : kind manager_operation)
    (result : kind Apply_results.manager_operation_result) =
  let open Lwt_result_syntax in
  let is_for_my_rollup : type kind. kind manager_operation -> bool = function
    | Sc_rollup_add_messages _ -> true
    | Sc_rollup_cement {rollup; _}
    | Sc_rollup_publish {rollup; _}
    | Sc_rollup_refute {rollup; _}
    | Sc_rollup_timeout {rollup; _}
    | Sc_rollup_execute_outbox_message {rollup; _}
    | Sc_rollup_recover_bond {sc_rollup = rollup; staker = _} ->
        Sc_rollup.Address.(rollup = node_ctxt.Node_context.rollup_address)
    | Dal_publish_slot_header _ -> true
    | Reveal _ | Transaction _ | Origination _ | Delegation _
    | Update_consensus_key _ | Register_global_constant _
    | Increase_paid_storage _ | Transfer_ticket _ | Sc_rollup_originate _
    | Zk_rollup_origination _ | Zk_rollup_publish _ | Zk_rollup_update _ ->
        false
  in
  if not (is_for_my_rollup operation) then return_unit
  else
    (* Only look at operations that are for the node's rollup *)
    let*! () =
      match Sc_rollup_injector.injector_operation_of_manager operation with
      | None -> Lwt.return_unit
      | Some op ->
          let status, errors =
            match result with
            | Applied _ -> (`Applied, None)
            | Backtracked (_, e) ->
                (`Backtracked, Option.map Environment.wrap_tztrace e)
            | Failed (_, e) -> (`Failed, Some (Environment.wrap_tztrace e))
            | Skipped _ -> (`Skipped, None)
          in
          Daemon_event.included_operation ?errors status op
    in
    match result with
    | Applied success_result ->
        process_included_l1_operation
          node_ctxt
          head
          ~source
          operation
          success_result
    | _ ->
        (* No action for non successful operations  *)
        return_unit

let process_l1_block_operations node_ctxt (head : Layer1.header) =
  let open Lwt_result_syntax in
  let* block =
    Layer1_helpers.fetch_tezos_block node_ctxt.Node_context.l1_ctxt head.hash
  in
  let apply (type kind) accu ~source (operation : kind manager_operation) result
      =
    let open Lwt_result_syntax in
    let* () = accu in
    process_l1_operation node_ctxt head ~source operation result
  in
  let apply_internal (type kind) accu ~source:_
      (_operation : kind Apply_internal_results.internal_operation)
      (_result : kind Apply_internal_results.internal_operation_result) =
    accu
  in
  let* () =
    Layer1_services.process_manager_operations
      return_unit
      block.operations
      {apply; apply_internal}
  in
  return_unit
