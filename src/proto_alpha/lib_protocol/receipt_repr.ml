(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
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

type staker = Stake_repr.staker =
  | Single of Contract_repr.t * Signature.public_key_hash
  | Shared of Signature.public_key_hash

type balance =
  | Contract of Contract_repr.t
  | Block_fees
  | Deposits of staker
  | Unstaked_deposits of staker * Cycle_repr.t
  | Nonce_revelation_rewards
  | Attesting_rewards
  | Baking_rewards
  | Baking_bonuses
  | Storage_fees
  | Double_signing_punishments
  | Lost_attesting_rewards of Signature.Public_key_hash.t * bool * bool
  | Liquidity_baking_subsidies
  | Burned
  | Commitments of Blinded_public_key_hash.t
  | Bootstrap
  | Invoice
  | Initial_commitments
  | Minted
  | Frozen_bonds of Contract_repr.t * Bond_id_repr.t
  | Sc_rollup_refutation_punishments
  | Sc_rollup_refutation_rewards

let balance_encoding ~use_legacy_attestation_name =
  let open Data_encoding in
  let case = function
    | Tag tag ->
        (* The tag was used by old variant. It have been removed in
           protocol proposal O, it can be unblocked in the future. *)
        let tx_rollup_reserved_tag = [22; 23] in
        assert (
          not @@ List.exists (Compare.Int.equal tag) tx_rollup_reserved_tag) ;
        case (Tag tag)
    | _ as c -> case c
  in
  def
    (if use_legacy_attestation_name then
     "operation_metadata_with_legacy_attestation_name.alpha.balance"
    else "operation_metadata.alpha.balance")
  @@ union
       [
         case
           (Tag 0)
           ~title:"Contract"
           (obj2
              (req "kind" (constant "contract"))
              (req "contract" Contract_repr.encoding))
           (function Contract c -> Some ((), c) | _ -> None)
           (fun ((), c) -> Contract c);
         case
           (Tag 2)
           ~title:"Block_fees"
           (obj2
              (req "kind" (constant "accumulator"))
              (req "category" (constant "block fees")))
           (function Block_fees -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Block_fees);
         case
           (Tag 4)
           ~title:"Deposits"
           (obj3
              (req "kind" (constant "freezer"))
              (req "category" (constant "deposits"))
              (req "staker" Stake_repr.staker_encoding))
           (function Deposits staker -> Some ((), (), staker) | _ -> None)
           (fun ((), (), staker) -> Deposits staker);
         case
           (Tag 5)
           ~title:"Nonce_revelation_rewards"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "nonce revelation rewards")))
           (function Nonce_revelation_rewards -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Nonce_revelation_rewards);
         (* 6 was for Double_signing_evidence_rewards that has been removed.
            https://gitlab.com/tezos/tezos/-/merge_requests/7758 *)
         case
           (Tag 7)
           ~title:
             (if use_legacy_attestation_name then "Endorsing_rewards"
             else "Attesting_rewards")
           (obj2
              (req "kind" (constant "minted"))
              (req
                 "category"
                 (constant
                    (if use_legacy_attestation_name then "endorsing rewards"
                    else "attesting rewards"))))
           (function Attesting_rewards -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Attesting_rewards);
         case
           (Tag 8)
           ~title:"Baking_rewards"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "baking rewards")))
           (function Baking_rewards -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Baking_rewards);
         case
           (Tag 9)
           ~title:"Baking_bonuses"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "baking bonuses")))
           (function Baking_bonuses -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Baking_bonuses);
         case
           (Tag 11)
           ~title:"Storage_fees"
           (obj2
              (req "kind" (constant "burned"))
              (req "category" (constant "storage fees")))
           (function Storage_fees -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Storage_fees);
         case
           (Tag 12)
           ~title:"Double_signing_punishments"
           (obj2
              (req "kind" (constant "burned"))
              (req "category" (constant "punishments")))
           (function Double_signing_punishments -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Double_signing_punishments);
         case
           (Tag 13)
           ~title:
             (if use_legacy_attestation_name then "Lost_endorsing_rewards"
             else "Lost_attesting_rewards")
           (obj5
              (req "kind" (constant "burned"))
              (req
                 "category"
                 (constant
                    (if use_legacy_attestation_name then
                     "lost endorsing rewards"
                    else "lost attesting rewards")))
              (req "delegate" Signature.Public_key_hash.encoding)
              (req "participation" Data_encoding.bool)
              (req "revelation" Data_encoding.bool))
           (function
             | Lost_attesting_rewards (d, p, r) -> Some ((), (), d, p, r)
             | _ -> None)
           (fun ((), (), d, p, r) -> Lost_attesting_rewards (d, p, r));
         case
           (Tag 14)
           ~title:"Liquidity_baking_subsidies"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "subsidy")))
           (function Liquidity_baking_subsidies -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Liquidity_baking_subsidies);
         case
           (Tag 15)
           ~title:"Burned"
           (obj2
              (req "kind" (constant "burned"))
              (req "category" (constant "burned")))
           (function Burned -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Burned);
         case
           (Tag 16)
           ~title:"Commitments"
           (obj3
              (req "kind" (constant "commitment"))
              (req "category" (constant "commitment"))
              (req "committer" Blinded_public_key_hash.encoding))
           (function Commitments bpkh -> Some ((), (), bpkh) | _ -> None)
           (fun ((), (), bpkh) -> Commitments bpkh);
         case
           (Tag 17)
           ~title:"Bootstrap"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "bootstrap")))
           (function Bootstrap -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Bootstrap);
         case
           (Tag 18)
           ~title:"Invoice"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "invoice")))
           (function Invoice -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Invoice);
         case
           (Tag 19)
           ~title:"Initial_commitments"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "commitment")))
           (function Initial_commitments -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Initial_commitments);
         case
           (Tag 20)
           ~title:"Minted"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "minted")))
           (function Minted -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Minted);
         case
           (Tag 21)
           ~title:"Frozen_bonds"
           (obj4
              (req "kind" (constant "freezer"))
              (req "category" (constant "bonds"))
              (req "contract" Contract_repr.encoding)
              (req "bond_id" Bond_id_repr.encoding))
           (function Frozen_bonds (c, r) -> Some ((), (), c, r) | _ -> None)
           (fun ((), (), c, r) -> Frozen_bonds (c, r));
         case
           (Tag 24)
           ~title:"Smart_rollup_refutation_punishments"
           (obj2
              (req "kind" (constant "burned"))
              (req "category" (constant "smart_rollup_refutation_punishments")))
           (function
             | Sc_rollup_refutation_punishments -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Sc_rollup_refutation_punishments);
         case
           (Tag 25)
           ~title:"Smart_rollup_refutation_rewards"
           (obj2
              (req "kind" (constant "minted"))
              (req "category" (constant "smart_rollup_refutation_rewards")))
           (function
             | Sc_rollup_refutation_rewards -> Some ((), ()) | _ -> None)
           (fun ((), ()) -> Sc_rollup_refutation_rewards);
         case
           (Tag 26)
           ~title:"Unstaked_deposits"
           (obj4
              (req "kind" (constant "freezer"))
              (req "category" (constant "unstaked_deposits"))
              (req "staker" Stake_repr.staker_encoding)
              (req "cycle" Cycle_repr.encoding))
           (function
             | Unstaked_deposits (staker, cycle) -> Some ((), (), staker, cycle)
             | _ -> None)
           (fun ((), (), staker, cycle) -> Unstaked_deposits (staker, cycle));
       ]

let balance_encoding_with_legacy_attestation_name =
  balance_encoding ~use_legacy_attestation_name:true

let balance_encoding = balance_encoding ~use_legacy_attestation_name:false

let is_not_zero c = not (Compare.Int.equal c 0)

let compare_balance ba bb =
  match (ba, bb) with
  | Contract ca, Contract cb -> Contract_repr.compare ca cb
  | Deposits sa, Deposits sb -> Stake_repr.compare_staker sa sb
  | Unstaked_deposits (sa, ca), Unstaked_deposits (sb, cb) ->
      Compare.or_else (Stake_repr.compare_staker sa sb) (fun () ->
          Cycle_repr.compare ca cb)
  | Lost_attesting_rewards (pkha, pa, ra), Lost_attesting_rewards (pkhb, pb, rb)
    ->
      let c = Signature.Public_key_hash.compare pkha pkhb in
      if is_not_zero c then c
      else
        let c = Compare.Bool.compare pa pb in
        if is_not_zero c then c else Compare.Bool.compare ra rb
  | Commitments bpkha, Commitments bpkhb ->
      Blinded_public_key_hash.compare bpkha bpkhb
  | Frozen_bonds (ca, ra), Frozen_bonds (cb, rb) ->
      let c = Contract_repr.compare ca cb in
      if is_not_zero c then c else Bond_id_repr.compare ra rb
  | _, _ ->
      let index b =
        match b with
        | Contract _ -> 0
        | Block_fees -> 1
        | Deposits _ -> 2
        | Unstaked_deposits _ -> 3
        | Nonce_revelation_rewards -> 4
        | Attesting_rewards -> 5
        | Baking_rewards -> 6
        | Baking_bonuses -> 7
        | Storage_fees -> 8
        | Double_signing_punishments -> 9
        | Lost_attesting_rewards _ -> 10
        | Liquidity_baking_subsidies -> 11
        | Burned -> 12
        | Commitments _ -> 13
        | Bootstrap -> 14
        | Invoice -> 15
        | Initial_commitments -> 16
        | Minted -> 17
        | Frozen_bonds _ -> 18
        | Sc_rollup_refutation_punishments -> 19
        | Sc_rollup_refutation_rewards -> 20
        (* don't forget to add parameterized cases in the first part of the function *)
      in
      Compare.Int.compare (index ba) (index bb)

type balance_update = Debited of Tez_repr.t | Credited of Tez_repr.t

let is_zero_update = function Debited t | Credited t -> Tez_repr.(t = zero)

let balance_update_encoding =
  let open Data_encoding in
  def "operation_metadata.alpha.balance_update"
  @@ obj1
       (req
          "change"
          (conv
             (function
               | Credited v -> Tez_repr.to_mutez v
               | Debited v -> Int64.neg (Tez_repr.to_mutez v))
             ( Json.wrap_error @@ fun v ->
               if Compare.Int64.(v < 0L) then
                 match Tez_repr.of_mutez (Int64.neg v) with
                 | Some v -> Debited v
                 | None -> assert false (* [of_mutez z] is [None] iff [z < 0] *)
               else
                 match Tez_repr.of_mutez v with
                 | Some v -> Credited v
                 | None -> assert false (* same *) )
             int64))

type update_origin =
  | Block_application
  | Protocol_migration
  | Subsidy
  | Simulation

let compare_update_origin oa ob =
  let index o =
    match o with
    | Block_application -> 0
    | Protocol_migration -> 1
    | Subsidy -> 2
    | Simulation -> 3
  in
  Compare.Int.compare (index oa) (index ob)

let update_origin_encoding =
  let open Data_encoding in
  def "operation_metadata.alpha.update_origin"
  @@ obj1 @@ req "origin"
  @@ union
       [
         case
           (Tag 0)
           ~title:"Block_application"
           (constant "block")
           (function Block_application -> Some () | _ -> None)
           (fun () -> Block_application);
         case
           (Tag 1)
           ~title:"Protocol_migration"
           (constant "migration")
           (function Protocol_migration -> Some () | _ -> None)
           (fun () -> Protocol_migration);
         case
           (Tag 2)
           ~title:"Subsidy"
           (constant "subsidy")
           (function Subsidy -> Some () | _ -> None)
           (fun () -> Subsidy);
         case
           (Tag 3)
           ~title:"Simulation"
           (constant "simulation")
           (function Simulation -> Some () | _ -> None)
           (fun () -> Simulation);
       ]

type balance_updates = (balance * balance_update * update_origin) list

let balance_updates_encoding_with_legacy_attestation_name =
  let open Data_encoding in
  def "operation_metadata_with_legacy_attestation_name.alpha.balance_updates"
  @@ list
       (conv
          (function
            | balance, balance_update, update_origin ->
                ((balance, balance_update), update_origin))
          (fun ((balance, balance_update), update_origin) ->
            (balance, balance_update, update_origin))
          (merge_objs
             (merge_objs
                balance_encoding_with_legacy_attestation_name
                balance_update_encoding)
             update_origin_encoding))

let balance_updates_encoding =
  let open Data_encoding in
  def "operation_metadata.alpha.balance_updates"
  @@ list
       (conv
          (function
            | balance, balance_update, update_origin ->
                ((balance, balance_update), update_origin))
          (fun ((balance, balance_update), update_origin) ->
            (balance, balance_update, update_origin))
          (merge_objs
             (merge_objs balance_encoding balance_update_encoding)
             update_origin_encoding))

module BalanceMap = struct
  include Map.Make (struct
    type t = balance * update_origin

    let compare (ba, ua) (bb, ub) =
      let c = compare_balance ba bb in
      if is_not_zero c then c else compare_update_origin ua ub
  end)

  let update_r key (f : 'a option -> 'b option tzresult) map =
    f (find key map) >>? function
    | Some v -> ok (add key v map)
    | None -> ok (remove key map)
end

let group_balance_updates balance_updates =
  List.fold_left_e
    (fun acc (b, update, o) ->
      (* Do not do anything if the update is zero *)
      if is_zero_update update then ok acc
      else
        BalanceMap.update_r
          (b, o)
          (function
            | None -> ok (Some update)
            | Some balance -> (
                match (balance, update) with
                | Credited a, Debited b | Debited b, Credited a ->
                    (* Remove the binding since it just fell down to zero *)
                    if Tez_repr.(a = b) then ok None
                    else if Tez_repr.(a > b) then
                      Tez_repr.(a -? b) >>? fun update ->
                      ok (Some (Credited update))
                    else
                      Tez_repr.(b -? a) >>? fun update ->
                      ok (Some (Debited update))
                | Credited a, Credited b ->
                    Tez_repr.(a +? b) >>? fun update ->
                    ok (Some (Credited update))
                | Debited a, Debited b ->
                    Tez_repr.(a +? b) >>? fun update ->
                    ok (Some (Debited update))))
          acc)
    BalanceMap.empty
    balance_updates
  >>? fun map ->
  ok (BalanceMap.fold (fun (b, o) u acc -> (b, u, o) :: acc) map [])
