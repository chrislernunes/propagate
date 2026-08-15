(* A deliberately naive, structurally independent evaluator for the
   same computation semantics: no incremental cache, no height
   scheduler, no invalidation machinery, no dependency-state reuse
   from lib/{node,graph,scheduler}.ml. Every [value] call walks the
   graph fresh from the current inputs.

   The one piece of internal state, [memo], exists only to keep this
   baseline *fair* with respect to DAG sharing (Master prompt, Section
   21: "must not use a deliberately inefficient tree walk that
   repeatedly recomputes shared ancestors") — without it, a diamond
   dependency would be recomputed once per path to it, which can blow
   up exponentially on deep shared DAGs and would make the incremental
   engine look artificially good in any benchmark with real sharing.
   [memo] is scoped to a single top-level [value] call via a pass
   counter, not persisted across calls — that within-call/across-call
   distinction is what keeps this "no incremental caching" rather than
   a second incremental engine in disguise.

   This module is used two ways: as the answer key for differential
   tests (test/differential), and as the "full recomputation" side of
   the crossover benchmark (in the benchmark directory). *)

type pass_id = int

type 'a t = { kind : 'a kind; mutable memo : (pass_id * 'a) option }
and 'a kind =
  | Var of 'a ref
  | Map : 'b t * ('b -> 'a) -> 'a kind
  | Map2 : 'b t * 'c t * ('b -> 'c -> 'a) -> 'a kind
  | Bind : 'b t * ('b -> 'a t) -> 'a kind
  (* [equal] is carried for API parity with Incremental.cutoff but is
     semantically inert here: a full recomputation has no propagation
     to suppress, so cutoff can only ever change *how much work* this
     reference does internally, never the value it reports. This
     matters for differential testing: the whole point is comparing
     values under equivalent semantics, so cutoff must be a no-op on
     the answer-key side. *)
  | Cutoff : 'a t * ('a -> 'a -> bool) -> 'a kind

let var (init : 'a) : 'a t = { kind = Var (ref init); memo = None }
let map (dep : 'a t) ~(f : 'a -> 'b) : 'b t = { kind = Map (dep, f); memo = None }
let map2 (a : 'a t) (b : 'b t) ~(f : 'a -> 'b -> 'c) : 'c t = { kind = Map2 (a, b, f); memo = None }
let bind (lhs : 'a t) ~(f : 'a -> 'b t) : 'b t = { kind = Bind (lhs, f); memo = None }
let cutoff (dep : 'a t) ~(equal : 'a -> 'a -> bool) : 'a t = { kind = Cutoff (dep, equal); memo = None }

let set (n : 'a t) (v : 'a) : unit =
  match n.kind with Var r -> r := v | _ -> invalid_arg "Reference.set: not a var"

let global_pass = ref 0

let rec eval : type a. pass_id -> a t -> a =
 fun p n ->
  match n.memo with
  | Some (p', v) when p' = p -> v
  | _ ->
    let v =
      match n.kind with
      | Var r -> !r
      | Map (dep, f) -> f (eval p dep)
      | Map2 (a, b, f) -> f (eval p a) (eval p b)
      | Bind (lhs, f) -> eval p (f (eval p lhs))
      | Cutoff (dep, _) -> eval p dep
    in
    n.memo <- Some (p, v);
    v

(* Comparison-friendly entry point: differential tests want to assert
   "both sides fail" just as much as "both sides agree on a value". *)
let value_result (n : 'a t) : ('a, exn) result =
  incr global_pass;
  try Ok (eval !global_pass n) with e -> Error e

let value (n : 'a t) : 'a = match value_result n with Ok v -> v | Error e -> raise e
