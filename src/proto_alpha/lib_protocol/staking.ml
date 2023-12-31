(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Alpha_context

type error +=
  | Cannot_stake_with_unfinalizable_unstake_requests_to_another_delegate

let () =
  let description =
    "A contract tries to stake to its delegate while having unstake requests \
     to a previous delegate that cannot be finalized yet. Try again in a later \
     cycle (no more than preserved_cycles + max_slashing_period)."
  in
  register_error_kind
    `Permanent
    ~id:
      "operation.cannot_stake_with_unfinalizable_unstake_requests_to_another_delegate"
    ~title:
      "Cannot stake with unfinalizable unstake requests to another delegate"
    ~description
    Data_encoding.unit
    (function
      | Cannot_stake_with_unfinalizable_unstake_requests_to_another_delegate ->
          Some ()
      | _ -> None)
    (fun () ->
      Cannot_stake_with_unfinalizable_unstake_requests_to_another_delegate)

let perform_finalizable_unstake_transfers ctxt contract finalizable =
  let open Lwt_result_syntax in
  List.fold_left_es
    (fun (ctxt, balance_updates) (delegate, cycle, amount) ->
      let+ ctxt, new_balance_updates =
        Token.transfer
          ctxt
          (`Unstaked_frozen_deposits
            (Receipt.Single (contract, delegate), cycle))
          (`Contract contract)
          amount
      in
      (ctxt, new_balance_updates @ balance_updates))
    (ctxt, [])
    finalizable

(* The [check_unfinalizable] function in argument must consume its gas, if
   relevant. *)
let finalize_unstake_and_check ~check_unfinalizable ctxt contract =
  let open Lwt_result_syntax in
  let*? ctxt =
    Gas.consume ctxt Adaptive_issuance_costs.prepare_finalize_unstake_cost
  in
  let* prepared_opt = Unstake_requests.prepare_finalize_unstake ctxt contract in
  match prepared_opt with
  | None -> return (ctxt, [])
  | Some {finalizable; unfinalizable} -> (
      let* ctxt = check_unfinalizable ctxt unfinalizable in
      match finalizable with
      | [] -> return (ctxt, [])
      | _ ->
          (* We only update the unstake requests if the [finalizable] list is not empty.
             Indeed, if it is not empty, it means that at least one of the unstake operations
             will be finalized, and the storage needs to be updated accordingly.
             Conversely, if finalizable is empty, then [unfinalizable] contains
             all the previous unstake requests, that should remain as requests after this
             operation. *)
          let*? ctxt =
            Gas.consume
              ctxt
              Adaptive_issuance_costs.finalize_unstake_and_check_cost
          in
          let* ctxt = Unstake_requests.update ctxt contract unfinalizable in
          perform_finalizable_unstake_transfers ctxt contract finalizable)

let finalize_unstake ctxt contract =
  let check_unfinalizable ctxt _unfinalizable = return ctxt in
  finalize_unstake_and_check ~check_unfinalizable ctxt contract

let punish_delegate ctxt delegate level mistake ~rewarded =
  let open Lwt_result_syntax in
  let punish =
    match mistake with
    | `Double_baking -> Delegate.punish_double_baking
    | `Double_attesting -> Delegate.punish_double_attesting
  in
  let* ctxt, {staked; unstaked} = punish ctxt delegate level in
  let init_to_burn_to_reward =
    let Delegate.{amount_to_burn; reward} = staked in
    let giver = `Frozen_deposits (Receipt.Shared delegate) in
    ([(giver, amount_to_burn)], [(giver, reward)])
  in
  let to_burn, to_reward =
    List.fold_left
      (fun (to_burn, to_reward) (cycle, Delegate.{amount_to_burn; reward}) ->
        let giver =
          `Unstaked_frozen_deposits (Receipt.Shared delegate, cycle)
        in
        ((giver, amount_to_burn) :: to_burn, (giver, reward) :: to_reward))
      init_to_burn_to_reward
      unstaked
  in
  let* ctxt, punish_balance_updates =
    Token.transfer_n ctxt to_burn `Double_signing_punishments
  in
  let+ ctxt, reward_balance_updates =
    Token.transfer_n ctxt to_reward (`Contract rewarded)
  in
  (ctxt, reward_balance_updates @ punish_balance_updates)

let stake ctxt ~sender ~delegate amount =
  let open Lwt_result_syntax in
  let check_unfinalizable ctxt
      Unstake_requests.{delegate = unstake_delegate; requests} =
    match requests with
    | [] -> return ctxt
    | _ :: _ ->
        if Signature.Public_key_hash.(delegate <> unstake_delegate) then
          tzfail
            Cannot_stake_with_unfinalizable_unstake_requests_to_another_delegate
        else return ctxt
  in
  let sender_contract = Contract.Implicit sender in
  let* ctxt, finalize_balance_updates =
    finalize_unstake_and_check ~check_unfinalizable ctxt sender_contract
  in
  let* ctxt =
    Staking_pseudotokens.stake ctxt ~contract:sender_contract ~delegate amount
  in
  let+ ctxt, stake_balance_updates =
    Token.transfer
      ctxt
      (`Contract sender_contract)
      (`Frozen_deposits (Receipt.Single (sender_contract, delegate)))
      amount
  in
  (ctxt, stake_balance_updates @ finalize_balance_updates)

let request_unstake ctxt ~sender_contract ~delegate requested_amount =
  let open Lwt_result_syntax in
  let* ctxt, tez_to_unstake =
    Staking_pseudotokens.request_unstake
      ctxt
      ~contract:sender_contract
      ~delegate
      requested_amount
  in
  if Tez.(tez_to_unstake = zero) then return (ctxt, [])
  else
    let*? ctxt =
      Gas.consume ctxt Adaptive_issuance_costs.request_unstake_cost
    in
    let current_cycle = (Level.current ctxt).cycle in
    let* ctxt, balance_updates =
      Token.transfer
        ctxt
        (`Frozen_deposits (Receipt.Single (sender_contract, delegate)))
        (`Unstaked_frozen_deposits
          (Receipt.Single (sender_contract, delegate), current_cycle))
        tez_to_unstake
    in
    let* ctxt, finalize_balance_updates =
      finalize_unstake ctxt sender_contract
    in
    let+ ctxt =
      Unstake_requests.add
        ctxt
        ~contract:sender_contract
        ~delegate
        current_cycle
        tez_to_unstake
    in
    (ctxt, balance_updates @ finalize_balance_updates)
