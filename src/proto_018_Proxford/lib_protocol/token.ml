(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020-2021 Nomadic Labs <contact@nomadic-labs.com>           *)
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

type container =
  [ `Contract of Contract_repr.t
  | `Collected_commitments of Blinded_public_key_hash.t
  | `Frozen_deposits of Stake_repr.staker
  | `Unstaked_frozen_deposits of Stake_repr.staker * Cycle_repr.t
  | `Block_fees
  | `Frozen_bonds of Contract_repr.t * Bond_id_repr.t ]

type infinite_source =
  [ `Invoice
  | `Bootstrap
  | `Initial_commitments
  | `Revelation_rewards
  | `Attesting_rewards
  | `Baking_rewards
  | `Baking_bonuses
  | `Minted
  | `Liquidity_baking_subsidies
  | `Sc_rollup_refutation_rewards ]

type giver = [infinite_source | container]

type infinite_sink =
  [ `Storage_fees
  | `Double_signing_punishments
  | `Lost_attesting_rewards of Signature.Public_key_hash.t * bool * bool
  | `Sc_rollup_refutation_punishments
  | `Burned ]

type receiver = [infinite_sink | container]

let balance ctxt stored =
  match stored with
  | `Collected_commitments bpkh ->
      Commitment_storage.committed_amount ctxt bpkh >|=? fun balance ->
      (ctxt, balance)
  | `Block_fees -> return (ctxt, Raw_context.get_collected_fees ctxt)

let credit ctxt receiver amount origin =
  let open Receipt_repr in
  (match receiver with
  | #infinite_sink as infinite_sink ->
      let sink =
        match infinite_sink with
        | `Storage_fees -> Storage_fees
        | `Double_signing_punishments -> Double_signing_punishments
        | `Lost_attesting_rewards (d, p, r) -> Lost_attesting_rewards (d, p, r)
        | `Sc_rollup_refutation_punishments -> Sc_rollup_refutation_punishments
        | `Burned -> Burned
      in
      Storage.Contract.Total_supply.get ctxt >>=? fun old_total_supply ->
      Tez_repr.(old_total_supply -? amount) >>?= fun new_total_supply ->
      Storage.Contract.Total_supply.update ctxt new_total_supply
      >|=? fun ctxt -> (ctxt, sink)
  | #container as container -> (
      match container with
      | `Contract receiver ->
          Contract_storage.credit_only_call_from_token ctxt receiver amount
          >|=? fun ctxt -> (ctxt, Contract receiver)
      | `Collected_commitments bpkh ->
          Commitment_storage.increase_commitment_only_call_from_token
            ctxt
            bpkh
            amount
          >|=? fun ctxt -> (ctxt, Commitments bpkh)
      | `Frozen_deposits staker ->
          Frozen_deposits_storage.credit_only_call_from_token ctxt staker amount
          >|=? fun ctxt -> (ctxt, Deposits staker)
      | `Unstaked_frozen_deposits (staker, cycle) ->
          Unstaked_frozen_deposits_storage.credit_only_call_from_token
            ctxt
            staker
            cycle
            amount
          >|=? fun ctxt -> (ctxt, Unstaked_deposits (staker, cycle))
      | `Block_fees ->
          Raw_context.credit_collected_fees_only_call_from_token ctxt amount
          >>?= fun ctxt -> return (ctxt, Block_fees)
      | `Frozen_bonds (contract, bond_id) ->
          Contract_storage.credit_bond_only_call_from_token
            ctxt
            contract
            bond_id
            amount
          >>=? fun ctxt -> return (ctxt, Frozen_bonds (contract, bond_id))))
  >|=? fun (ctxt, balance) -> (ctxt, (balance, Credited amount, origin))

let spend ctxt giver amount origin =
  let open Receipt_repr in
  (match giver with
  | #infinite_source as infinite_source ->
      let src =
        match infinite_source with
        | `Bootstrap -> Bootstrap
        | `Invoice -> Invoice
        | `Initial_commitments -> Initial_commitments
        | `Minted -> Minted
        | `Liquidity_baking_subsidies -> Liquidity_baking_subsidies
        | `Revelation_rewards -> Nonce_revelation_rewards
        | `Attesting_rewards -> Attesting_rewards
        | `Baking_rewards -> Baking_rewards
        | `Baking_bonuses -> Baking_bonuses
        | `Sc_rollup_refutation_rewards -> Sc_rollup_refutation_rewards
      in
      Storage.Contract.Total_supply.get ctxt >>=? fun old_total_supply ->
      Tez_repr.(old_total_supply +? amount) >>?= fun new_total_supply ->
      Storage.Contract.Total_supply.update ctxt new_total_supply
      >|=? fun ctxt -> (ctxt, src)
  | #container as container -> (
      match container with
      | `Contract giver ->
          Contract_storage.spend_only_call_from_token ctxt giver amount
          >|=? fun ctxt -> (ctxt, Contract giver)
      | `Collected_commitments bpkh ->
          Commitment_storage.decrease_commitment_only_call_from_token
            ctxt
            bpkh
            amount
          >|=? fun ctxt -> (ctxt, Commitments bpkh)
      | `Frozen_deposits staker ->
          Frozen_deposits_storage.spend_only_call_from_token ctxt staker amount
          >|=? fun ctxt -> (ctxt, Deposits staker)
      | `Unstaked_frozen_deposits (staker, cycle) ->
          Unstaked_frozen_deposits_storage.spend_only_call_from_token
            ctxt
            staker
            cycle
            amount
          >|=? fun ctxt -> (ctxt, Unstaked_deposits (staker, cycle))
      | `Block_fees ->
          Raw_context.spend_collected_fees_only_call_from_token ctxt amount
          >>?= fun ctxt -> return (ctxt, Block_fees)
      | `Frozen_bonds (contract, bond_id) ->
          Contract_storage.spend_bond_only_call_from_token
            ctxt
            contract
            bond_id
            amount
          >>=? fun ctxt -> return (ctxt, Frozen_bonds (contract, bond_id))))
  >|=? fun (ctxt, balance) -> (ctxt, (balance, Debited amount, origin))

let transfer_n ?(origin = Receipt_repr.Block_application) ctxt givers receiver =
  let givers = List.filter (fun (_, am) -> Tez_repr.(am <> zero)) givers in
  match givers with
  | [] ->
      (* Avoid accessing context data when there is nothing to transfer. *)
      return (ctxt, [])
  | _ :: _ ->
      (* Withdraw from givers. *)
      List.fold_left_es
        (fun (ctxt, total, debit_logs) (giver, amount) ->
          spend ctxt giver amount origin >>=? fun (ctxt, debit_log) ->
          Tez_repr.(amount +? total) >>?= fun total ->
          return (ctxt, total, debit_log :: debit_logs))
        (ctxt, Tez_repr.zero, [])
        givers
      >>=? fun (ctxt, amount, debit_logs) ->
      credit ctxt receiver amount origin >>=? fun (ctxt, credit_log) ->
      (* Deallocate implicit contracts with no stake. This must be done after
         spending and crediting. If done in between then a transfer of all the
         balance from (`Contract c) to (`Frozen_bonds (c,_)) would leave the
         contract c unallocated. *)
      List.fold_left_es
        (fun ctxt (giver, _amount) ->
          match giver with
          | `Contract contract | `Frozen_bonds (contract, _) ->
              Contract_storage.ensure_deallocated_if_empty ctxt contract
          | #giver -> return ctxt)
        ctxt
        givers
      >|=? fun ctxt ->
      (* Make sure the order of balance updates is : debit logs in the order of
         of the parameter [givers], and then the credit log. *)
      let balance_updates = List.rev (credit_log :: debit_logs) in
      (ctxt, balance_updates)

let transfer ?(origin = Receipt_repr.Block_application) ctxt giver receiver
    amount =
  transfer_n ~origin ctxt [(giver, amount)] receiver

module Internal_for_tests = struct
  let allocated ctxt stored =
    match stored with
    | `Contract contract ->
        Contract_storage.allocated ctxt contract >|= fun allocated ->
        ok (ctxt, allocated)
    | `Collected_commitments bpkh ->
        Commitment_storage.exists ctxt bpkh >|= fun allocated ->
        ok (ctxt, allocated)
    | `Frozen_deposits _ | `Unstaked_frozen_deposits _ | `Block_fees ->
        return (ctxt, true)
    | `Frozen_bonds (contract, bond_id) ->
        Contract_storage.bond_allocated ctxt contract bond_id

  type container_with_balance =
    [ `Contract of Contract_repr.t
    | `Collected_commitments of Blinded_public_key_hash.t
    | `Block_fees
    | `Frozen_bonds of Contract_repr.t * Bond_id_repr.t ]

  let balance ctxt (stored : [< container_with_balance]) =
    match stored with
    | (`Collected_commitments _ | `Block_fees) as stored -> balance ctxt stored
    | `Contract contract ->
        Contract_storage.get_balance ctxt contract >|=? fun balance ->
        (ctxt, balance)
    | `Frozen_bonds (contract, bond_id) ->
        Contract_storage.find_bond ctxt contract bond_id
        >|=? fun (ctxt, balance_opt) ->
        (ctxt, Option.value ~default:Tez_repr.zero balance_opt)
end
