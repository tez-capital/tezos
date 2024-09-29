(*****************************************************************************)
(*                                                                           *)
(* SPDX-License-Identifier: MIT                                              *)
(* Copyright (c) 2024 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2024 Functori <contact@functori.com>                        *)
(*                                                                           *)
(*****************************************************************************)

(* Testing
   -------
   Component:    Smart Optimistic Rollups: Etherlink Sequencer + DAL
   Requirement:  make -f etherlink.mk build
                 npm install eth-cli
                 # Install cast or foundry (see: https://book.getfoundry.sh/getting-started/installation)
                 curl -L https://foundry.paradigm.xyz | bash
                 foundryup
                 make -f etherlink.mk octez-dsn-node
                 ./scripts/install_dal_trusted_setup.sh
   Invocation:   dune exec etherlink/tezt/tests/main.exe -- --file dal_sequencer.ml
*)

open Helpers
open Setup
open Rpc.Syntax

let register_test =
  register_test_for_kernels
    ~__FILE__
    ~enable_dal:true
    ~threshold_encryption:false

let count_event sequencer event counter =
  Evm_node.wait_for sequencer event (fun _json ->
      incr counter ;
      (* We return None here to keep the loop running *)
      None)

let count_blueprint_sent_on_inbox sequencer counter =
  count_event sequencer "blueprint_injection_on_inbox.v0" counter

(* This test is similar to {Evm_sequencer.test_publish_blueprints} but it also checks
   that all 5 blueprints sent from the sequencer were published on the
   DAL (and none on the inbox). *)
let test_publish_blueprints_on_dal =
  register_test
    ~time_between_blocks:Nothing
    ~tags:["evm"; "sequencer"; "data"]
    ~title:"Sequencer publishes the blueprints to the DAL"
  (* We want this test in the CI so we put no extra tags when DAL
     is active to avoid having the [ci_disabled] or [slow] tag. *)
  @@
  fun {sequencer; proxy; client; sc_rollup_node; enable_dal; _} _protocol ->
  let number_of_blueprints = 5 in

  let number_of_blueprints_sent_to_inbox = ref 0 in
  let number_of_blueprints_sent_to_dal = ref 0 in
  let number_of_signals = ref 0 in

  let inbox_counter_p =
    count_blueprint_sent_on_inbox sequencer number_of_blueprints_sent_to_inbox
  in

  let dal_counter_p =
    count_event
      sequencer
      "blueprint_injection_on_DAL.v0"
      number_of_blueprints_sent_to_dal
  in

  let signal_counter_p =
    count_event sequencer "signal_publisher_signal_signed.v0" number_of_signals
  in

  let* _ =
    repeat number_of_blueprints (fun () ->
        let*@ _ = produce_block sequencer in
        unit)
  in

  (* Wait more to avoid flakiness, in particular with DAL *)
  let timeout = if enable_dal then 50. else 5. in
  let* () =
    Evm_node.wait_for_blueprint_injected ~timeout sequencer number_of_blueprints
  in

  (* At this point, the evm node should call the batcher endpoint to publish
     all the blueprints. Stopping the node is then not a problem. *)
  let* () =
    bake_until_sync ~__LOC__ ~sc_rollup_node ~client ~sequencer ~proxy ()
  in

  let* () =
    (* bake 2 block when DAL is enabled so evm_node sees it as
       finalized in `rollup_node_follower` *)
    if enable_dal then
      repeat 2 (fun () ->
          let* _lvl = next_rollup_node_level ~sc_rollup_node ~client in
          unit)
    else unit
  in

  (* We have unfortunately noticed that the test can be flaky. Sometimes,
     the following RPC is done before the proxy being initialised, even though
     we wait for it. The source of flakiness is unknown but happens very rarely,
     we put a small sleep to make the least flaky possible. *)
  let* () = Lwt_unix.sleep 2. in
  let* () = check_head_consistency ~left:sequencer ~right:proxy () in
  let expected_nb_of_bp_on_dal, expected_nb_of_bp_on_inbox =
    if enable_dal then (number_of_blueprints, 0) else (0, number_of_blueprints)
  in
  let expected_nb_of_signals = expected_nb_of_bp_on_dal in
  Check.(expected_nb_of_bp_on_dal = !number_of_blueprints_sent_to_dal)
    ~__LOC__
    Check.int
    ~error_msg:
      "Wrong number of blueprints published on the DAL; Expected %L, got %R." ;
  Check.(expected_nb_of_signals = !number_of_signals)
    ~__LOC__
    Check.int
    ~error_msg:"Wrong number of signals signed; Expected %L, got %R." ;
  Check.(expected_nb_of_bp_on_inbox = !number_of_blueprints_sent_to_inbox)
    ~__LOC__
    Check.int
    ~error_msg:
      "Wrong number of blueprints published on the inbox; Expected %L, got %R." ;
  Lwt.cancel dal_counter_p ;
  Lwt.cancel inbox_counter_p ;
  Lwt.cancel signal_counter_p ;
  unit

let test_chunked_blueprints_on_dal =
  register_test
    ~time_between_blocks:Nothing
    ~tags:["evm"; "sequencer"; "chunks"]
    ~title:
      "Sequencer publishes entire blueprints of more than one chunk to the DAL"
  @@ fun {sequencer; sc_rollup_node; client; proxy; _} _protocol ->
  (* Send data big enough to trigger splitting in multiple chunks. *)
  let number_of_blueprints_sent_to_inbox = ref 0 in

  let inbox_counter_p =
    count_blueprint_sent_on_inbox sequencer number_of_blueprints_sent_to_inbox
  in

  (* Chunks size depends on the size of messages in the inbox, which is for now
     of 4096 bytes. Let's make a transaction that is far bigger so that we can
     be sure it will be added to a blueprint that will be chunked. *)
  let data = String.make 64896 '0' in
  let to_public_key = Eth_account.bootstrap_accounts.(1).address in
  let* _tx_hash =
    send_transaction_to_sequencer
      (Eth_cli.transaction_send
         ~source_private_key:Eth_account.bootstrap_accounts.(0).private_key
         ~to_public_key
         ~value:Wei.zero
         ~data
         ~endpoint:(Evm_node.endpoint sequencer))
      sequencer
  and* _level, nb_chunks =
    Evm_node.wait_for_blueprint_injected_on_dal sequencer
  in
  Check.(
    (nb_chunks >= 2)
      int
      ~error_msg:
        "The number of chunks injected should be at least %R but it is %L") ;
  (* bake until the sequencer and the rollup are in sync, to assess the input
     has been read correctly. *)
  let* () =
    bake_until_sync ~__LOC__ ~sc_rollup_node ~client ~sequencer ~proxy ()
  in
  Check.(
    (!number_of_blueprints_sent_to_inbox = 0)
      int
      ~error_msg:
        "No blueprint should've been sent through the inbox, otherwise it \
         means that the data has been sent via the catchup mechanism") ;
  Lwt.cancel inbox_counter_p ;
  unit

let protocols = Protocol.all

let () =
  test_publish_blueprints_on_dal protocols ;
  test_chunked_blueprints_on_dal protocols
