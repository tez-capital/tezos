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

(** Adding and removing stake can be done from/toward a delegate, one
   of its staker, or both the delegate and all its stakers at
   once. We need to distinguish these cases to enforce the staking
   over baking limit. *)
type staker =
  | Single of Contract_repr.t * Signature.public_key_hash
    (* A single staker, either the delegate itself or one of its
       staker. *)
  | Shared of Signature.public_key_hash
(* The delegate and all its stakers simultaneously. *)

val staker_encoding : staker Data_encoding.t

val compare_staker : staker -> staker -> int

val staker_delegate : staker -> Signature.public_key_hash

(** Stake of a delegate. *)
type t = private {frozen : Tez_repr.t; delegated : Tez_repr.t}

val zero : t

val make : frozen:Tez_repr.t -> delegated:Tez_repr.t -> t

val encoding : t Data_encoding.t

(** Returns only the frozen part of a stake *)
val get_frozen : t -> Tez_repr.t

val ( +? ) : t -> t -> t tzresult

module Full : sig
  type t = private {
    own_frozen : Tez_repr.t;
    staked_frozen : Tez_repr.t;
    delegated : Tez_repr.t;
  }

  val make :
    own_frozen:Tez_repr.t ->
    staked_frozen:Tez_repr.t ->
    delegated:Tez_repr.t ->
    t

  val zero : t

  val encoding : t Data_encoding.t
end
