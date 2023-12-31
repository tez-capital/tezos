(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

type group = Standalone | Group of string | Generic

type 'config parameters = {bench_number : int; config : 'config}

type purpose = Other_purpose of string | Generate_code of string

let pp_purpose ppf t =
  match t with
  | Other_purpose s -> Format.fprintf ppf "Other purpose: %s" s
  | Generate_code s -> Format.fprintf ppf "Generate code: %s" s

module type Benchmark_base = sig
  val name : Namespace.t

  val info : string

  val module_filename : string

  val purpose : purpose

  val tags : string list

  type config

  val default_config : config

  val config_encoding : config Data_encoding.t

  type workload

  val workload_encoding : workload Data_encoding.t

  val workload_to_vector : workload -> Sparse_vec.String.t
end

module type S = sig
  include Benchmark_base

  val models : (string * workload Model.t) list

  include Generator.S with type config := config and type workload := workload
end

module type Simple = sig
  include Benchmark_base

  val group : group

  val model : workload Model.t

  val create_benchmark :
    rng_state:Random.State.t -> config -> workload Generator.benchmark
end

module type Simple_with_num = sig
  include Benchmark_base

  val group : group

  val model : workload Model.t

  include Generator.S with type workload := workload and type config := config
end

type t = (module S)

type simple = (module Simple)

type simple_with_num = (module Simple_with_num)

let pp ppf (module Bench : S) =
  let open Bench in
  let open Format in
  let f fmt = fprintf ppf fmt in
  let pp_config fmt config =
    Data_encoding.Json.pp fmt
    @@ Data_encoding.Json.construct config_encoding config
  in
  f "@[<v>" ;
  f "name: %a@;" Namespace.pp name ;
  f "info: %s@;" info ;
  f "module_filename: %s@;" module_filename ;
  f "purpose: %a@;" pp_purpose purpose ;
  f
    "tags: [%a]@;"
    (pp_print_list ~pp_sep:(fun ppf () -> fprintf ppf "; ") pp_print_string)
    tags ;
  f "@[<v2>default_config:@ @[%a@]@]@;" pp_config default_config ;
  f
    "@[<v2>local models for inference:@ @[<v>%a@]@]@;"
    (pp_print_list (fun ppf (local_model_name, model) ->
         fprintf ppf "@[<v2>%s:@ @[%a@]@]" local_model_name Model.pp model))
    models ;
  f "@]"

type ('cfg, 'workload) poly =
  (module S with type config = 'cfg and type workload = 'workload)

type packed = Ex : ('cfg, 'workload) poly -> packed

let name ((module B) : t) = B.name

let info ((module B) : t) = B.info

let tags ((module B) : t) = B.tags

let ex_unpack : t -> packed = fun (module Bench) -> Ex ((module Bench) : _ poly)

let get_free_variable_set (module Bench : S) =
  List.fold_left
    (fun acc (_, model) ->
      Free_variable.Set.union acc @@ Model.get_free_variable_set_of_t model)
    Free_variable.Set.empty
    Bench.models
