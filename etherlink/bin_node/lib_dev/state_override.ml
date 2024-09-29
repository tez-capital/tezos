(*****************************************************************************)
(*                                                                           *)
(* SPDX-License-Identifier: MIT                                              *)
(* Copyright (c) 2024 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(*****************************************************************************)

let durable_balance v = v |> Ethereum_types.encode_u256_le |> Bytes.to_string

let durable_nonce v = v |> Ethereum_types.encode_u64_le |> Bytes.to_string

let durable_code = Ethereum_types.hex_to_bytes

let update_account address {Ethereum_types.balance; nonce; code} state =
  let open Durable_storage_path in
  let open Lwt_syntax in
  let update v_opt key encode state =
    match v_opt with
    | None -> Lwt_syntax.return state
    | Some v -> Evm_state.modify ~key ~value:(encode v) state
  in
  let* state =
    update balance (Accounts.balance address) durable_balance state
  in
  let* state = update nonce (Accounts.nonce address) durable_nonce state in
  let* state = update code (Accounts.code address) durable_code state in
  return state

let update_accounts state_override state =
  match state_override with
  | None -> Lwt_syntax.return state
  | Some so -> Ethereum_types.AddressMap.fold_s update_account so state
