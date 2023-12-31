(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

type level_position = Start | Middle | End

type info_per_level = {
  predecessor_timestamp : Time.Protocol.t;
  predecessor : Block_hash.t;
}

type t = {
  ctxt : Context.ro;
  inbox_level : int32;
  state : Context.tree;
  reveal_map : string Utils.Reveal_hash_map.t option;
  nb_messages_inbox : int;
  level_position : level_position;
  info_per_level : info_per_level;
  plugin : (module Protocol_plugin_sig.S);
}

let simulate_info_per_level (node_ctxt : [`Read] Node_context.t) predecessor =
  let open Lwt_result_syntax in
  let* pred_header =
    Layer1.fetch_tezos_shell_header node_ctxt.l1_ctxt predecessor
  in
  let predecessor_timestamp = pred_header.timestamp in
  return {predecessor_timestamp; predecessor}

let start_simulation node_ctxt ~reveal_map (Layer1.{hash; level} as head) =
  let open Lwt_result_syntax in
  let inbox_level = Int32.succ level in
  let* plugin = Protocol_plugins.proto_plugin_for_level node_ctxt inbox_level in
  let*? () =
    error_unless
      (level >= node_ctxt.Node_context.genesis_info.level)
      (Exn (Failure "Cannot simulate before origination level"))
  in
  let first_inbox_level = Int32.succ node_ctxt.genesis_info.level in
  let* ctxt =
    if level < first_inbox_level then
      (* This is before we have interpreted the boot sector, so we start
         with an empty context in genesis *)
      return (Context.empty node_ctxt.context)
    else Node_context.checkout_context node_ctxt hash
  in
  let* ctxt, state =
    Interpreter.state_of_head (module (val plugin)) node_ctxt ctxt head
  in
  let+ info_per_level = simulate_info_per_level node_ctxt hash in
  {
    ctxt;
    inbox_level;
    state;
    reveal_map;
    nb_messages_inbox = 0;
    level_position = Start;
    info_per_level;
    plugin;
  }

let simulate_messages_no_checks (node_ctxt : Node_context.ro)
    ({
       ctxt;
       state;
       inbox_level;
       reveal_map;
       nb_messages_inbox;
       plugin;
       level_position = _;
       info_per_level = _;
     } as sim) messages =
  let open Lwt_result_syntax in
  let open (val plugin) in
  let*! state_hash = Pvm.state_hash node_ctxt.kind state in
  let*! tick = Pvm.get_tick node_ctxt.kind state in
  let eval_state =
    Pvm_plugin_sig.
      {
        state;
        state_hash;
        tick;
        inbox_level;
        message_counter_offset = nb_messages_inbox;
        remaining_fuel = Fuel.Free.of_ticks 0L;
        remaining_messages = messages;
      }
  in
  (* Build new state *)
  let* eval_result =
    Pvm.Fueled.Free.eval_messages ?reveal_map node_ctxt eval_state
  in
  let Pvm_plugin_sig.{state = {state; _}; num_ticks; num_messages; _} =
    Delayed_write_monad.ignore eval_result
  in
  let*! ctxt = Context.PVMState.set ctxt state in
  let nb_messages_inbox = nb_messages_inbox + num_messages in
  return ({sim with ctxt; state; nb_messages_inbox}, num_ticks)

let simulate_messages (node_ctxt : Node_context.ro) sim messages =
  let open Lwt_result_syntax in
  let open (val sim.plugin) in
  (* Build new inbox *)
  let*? () =
    error_when
      (sim.level_position = End)
      (Exn (Failure "Level for simulation is ended"))
  in
  let messages =
    if sim.level_position = Start then
      let {predecessor_timestamp; predecessor} = sim.info_per_level in
      Pvm.start_of_level_serialized
      :: Pvm.info_per_level_serialized ~predecessor ~predecessor_timestamp
      :: messages
    else messages
  in
  let+ sim, num_ticks = simulate_messages_no_checks node_ctxt sim messages in
  ({sim with level_position = Middle}, num_ticks)

let end_simulation node_ctxt sim =
  let open Lwt_result_syntax in
  let open (val sim.plugin) in
  let*? () =
    error_when
      (sim.level_position = End)
      (Exn (Failure "Level for simulation is ended"))
  in
  let+ sim, num_ticks =
    simulate_messages_no_checks node_ctxt sim [Pvm.end_of_level_serialized]
  in
  ({sim with level_position = End}, num_ticks)
