(*****************************************************************************)
(*                                                                           *)
(* SPDX-License-Identifier: MIT                                              *)
(* Copyright (c) 2024 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(*****************************************************************************)

(* Testing
   -------
   Component:    Etherlink: EVM simulator
   Requirement:  make -f etherlink.mk build
                 npm install eth-cli
                 # Install cast or foundry (see: https://book.getfoundry.sh/getting-started/installation)
                 curl -L https://foundry.paradigm.xyz | bash
                 foundryup
                 make octez-evm-node
   Invocation:   dune exec etherlink/tezt/tests/main.exe -- --file eth_call.ml
*)

open Setup
open Helpers

let register ?genesis_timestamp ?bootstrap_accounts ?(kernels = Kernel.all)
    ?preimages_dir ?maximum_allowed_ticks ?enable_fa_bridge ?history_mode
    ?additional_uses ~title ~tags body protocols =
  register_test_for_kernels
    ~__FILE__
    ~time_between_blocks:Nothing
    ?genesis_timestamp
    ?bootstrap_accounts
    ~kernels
    ?preimages_dir
    ?maximum_allowed_ticks
    ?enable_fa_bridge
    ?additional_uses
    ?history_mode
    ~enable_dal:false
    ~threshold_encryption:false
    ~title
    ~tags
    body
    protocols

let test_call_state_override_balance =
  register
    ~kernels:[Latest] (* Not a kernel specific test. *)
    ~tags:["evm"; "state_override"; "balance_override"; "eth_call"]
    ~title:"Can override balance in eth_call"
  @@ fun {sequencer; _} _protocol ->
  (*
      This test checks that the simulation allows balance override.
      To do so we deploy a contract which returns the balance of the message 
      sender, and call it with a non-sensical address.
  *)
  let* constant = Solidity_contracts.state_override_tester () in
  let* () = Eth_cli.add_abi ~label:constant.label ~abi:constant.abi () in
  (* Deploy the contract. *)
  let* contract, _tx_hash =
    send_transaction_to_sequencer
      (fun () ->
        Eth_cli.deploy
          ~source_private_key:Eth_account.bootstrap_accounts.(0).private_key
          ~endpoint:(Evm_node.endpoint sequencer)
          ~abi:constant.abi
          ~bin:constant.bin)
      sequencer
  in
  let caller_address = "0x0123456789012345678901234567890123456789" in
  let* calldata = Cast.calldata "getBalance()" in
  let call =
    `O
      [
        ("from", `String caller_address);
        ("to", `String contract);
        ("data", `String calldata);
      ]
  in
  let* call_result =
    Evm_node.(
      call_evm_rpc sequencer {method_ = "eth_call"; parameters = `A [call]})
  in
  Check.(
    (Evm_node.extract_result call_result
    |> JSON.as_string
    = "0x0000000000000000000000000000000000000000000000000000000000000000")
      string)
    ~error_msg:"Expected result %R but got %L " ;
  let override_balance =
    `O [(caller_address, `O [("balance", `String "0xffff")])]
  in
  let* call_result =
    Evm_node.(
      call_evm_rpc
        sequencer
        {method_ = "eth_call"; parameters = `A [call; override_balance]})
    (* we omit the block paramater to test the encoding *)
  in
  Check.(
    (Evm_node.extract_result call_result
    |> JSON.as_string
    = "0x000000000000000000000000000000000000000000000000000000000000ffff")
      string)
    ~error_msg:"Expected result %R but got %L " ;

  unit

let test_call_state_override_code =
  register
    ~kernels:[Latest] (* Not a kernel specific test. *)
    ~tags:["evm"; "state_override"; "code_override"; "eth_call"]
    ~title:"Can override code in eth_call"
  @@ fun {sequencer; _} _protocol ->
  (*
      This test checks that the simulation allows code override.
      To do so we deploy a contract without any function, and call it with an
      alternative code that does have a function.
  *)
  let* constant = Solidity_contracts.state_override_tester () in
  let* constant_readable =
    Solidity_contracts.state_override_tester_readable ()
  in
  let* () = Eth_cli.add_abi ~label:constant.label ~abi:constant.abi () in
  (* Deploy the contract. *)
  let* contract, _tx_hash =
    send_transaction_to_sequencer
      (fun () ->
        Eth_cli.deploy
          ~source_private_key:Eth_account.bootstrap_accounts.(0).private_key
          ~endpoint:(Evm_node.endpoint sequencer)
          ~abi:constant.abi
          ~bin:constant.bin)
      sequencer
  in
  let bytecode_accessor =
    read_file (Option.value ~default:"" constant_readable.deployed_bin)
  in
  let* calldata = Cast.calldata "getCount()" in
  let call = `O [("to", `String contract); ("data", `String calldata)] in

  (* Check that the contract normaly doesn't allow "getCount()" *)
  let* call_result =
    Evm_node.(
      call_evm_rpc
        sequencer
        {method_ = "eth_call"; parameters = `A [call; `String "latest"]})
  in
  Check.(
    (Evm_node.extract_error_message call_result
    |> JSON.as_string = "execution reverted")
      string)
    ~error_msg:"Expected error %R but got %L " ;

  (* try again with an override *)
  let override_code =
    `O [(contract, `O [("code", `String ("0x" ^ bytecode_accessor))])]
  in
  let* call_result =
    Evm_node.(
      call_evm_rpc
        sequencer
        {
          method_ = "eth_call";
          parameters = `A [call; `String "latest"; override_code];
        })
  in
  Check.(
    (Evm_node.extract_result call_result
    |> JSON.as_string
    = "0x000000000000000000000000000000000000000000000000000000000000002a")
      string)
    ~error_msg:"Expected result %R but got %L " ;

  unit

let test_call_state_override_nonce =
  register
    ~kernels:[Latest] (* Not a kernel specific test. *)
    ~tags:["evm"; "state_override"; "nonce_override"; "eth_call"]
    ~title:"Can override nonce in eth_call"
  @@ fun {sequencer; _} _protocol ->
  (*
      This test checks that the simulation allows nonce override.
      To do so we deploy a contract that creates a contract and returns the
      address of the new contract, and call it twice with different nonce.
      The addresses should be different.
      *)
  let* factory = Solidity_contracts.state_override_tester () in
  let* () = Eth_cli.add_abi ~label:factory.label ~abi:factory.abi () in
  (* Deploy the contract. *)
  let* contract, _tx_hash =
    send_transaction_to_sequencer
      (fun () ->
        Eth_cli.deploy
          ~source_private_key:Eth_account.bootstrap_accounts.(0).private_key
          ~endpoint:(Evm_node.endpoint sequencer)
          ~abi:factory.abi
          ~bin:factory.bin)
      sequencer
  in

  let* calldata = Cast.calldata "create()" in
  let caller_address = Eth_account.bootstrap_accounts.(0).address in
  let call =
    `O
      [
        ("from", `String caller_address);
        ("to", `String contract);
        ("data", `String calldata);
      ]
  in

  (* Call a first time to have an address *)
  let* call_result =
    Evm_node.(
      call_evm_rpc
        sequencer
        {method_ = "eth_call"; parameters = `A [call; `String "latest"]})
  in
  let addr1 = Evm_node.extract_result call_result |> JSON.as_string in

  (* try again with an override *)
  let override_code = `O [(contract, `O [("nonce", `String "0x2a")])] in
  let* call_result =
    Evm_node.(
      call_evm_rpc
        sequencer
        {
          method_ = "eth_call";
          parameters = `A [call; `String "latest"; override_code];
        })
  in
  let addr2 = Evm_node.extract_result call_result |> JSON.as_string in

  (* the two address were calculated with different nonce so should be different
     (hopefully) *)
  Check.((addr1 <> addr2) string)
    ~error_msg:"Address should have been different but got %R and %L" ;

  unit

let protocols = Protocol.all

let () =
  test_call_state_override_code protocols ;
  test_call_state_override_nonce protocols ;
  test_call_state_override_balance protocols
