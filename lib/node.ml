(* Core node representation.

   This module defines only the shared mutable record and its variants.
   It has no .mli: it is an internal implementation module, fully
   transparent to [Scheduler] and [Graph]. The public abstraction
   boundary lives at [Incremental], not here. See docs/design.md,
   "Module boundaries", for the rationale. *)

module Id = struct
  type t = int

  let counter = ref 0
  let create () =
    incr counter;
    !counter

  let equal (a : int) (b : int) = a = b
  let compare (a : int) (b : int) = Stdlib.compare a b
  let to_int t = t
  let hash (t : int) = Hashtbl.hash t
end

type eval_status = Idle | Computing

type 'a value_state =
  | Never_computed
  | Fresh of 'a
  | Failed of exn

(* [packed] is the standard GADT-existential trick: dependents lists and
   scheduler buckets are heterogeneous in the node's result type, so
   anything generic over "some node, whatever it computes" goes through
   this wrapper. *)
type packed = Pack : 'a t -> packed

and 'a t = {
  id : Id.t;
  mutable kind : 'a kind;
  mutable value : 'a value_state;
  mutable height : int;
  (* Total necessity refcount: #observers + #{necessary dependents}. A
     node is Necessary iff necessary_count > 0 (Invariant I3). *)
  mutable necessary_count : int;
  (* Tracked separately from necessary_count purely so the debug
     invariant checker has independent ground truth to check I3
     against, rather than checking necessary_count against itself. *)
  mutable observer_count : int;
  mutable dependents : packed list;
  mutable status : eval_status;
  (* Implements Invariant I2 directly: staleness IS this flag, not a
     separately-derived fact. True iff this node is currently a member
     of the scheduler's recompute heap. *)
  mutable in_heap : bool;
  (* Set to the owning Graph.t's change_counter every time this node's
     *cached value itself* changes (post-cutoff). Used by Bind to tell
     "my lhs changed" apart from "my rhs's value changed" without
     re-running the lhs->rhs function unnecessarily. *)
  mutable value_stamp : int;
}

and 'a kind =
  | Var : 'a var_cell -> 'a kind
  | Map : 'b t * ('b -> 'a) -> 'a kind
  | Map2 : 'b t * 'c t * ('b -> 'c -> 'a) -> 'a kind
  | Bind : ('b, 'a) bind_cell -> 'a kind
  | Cutoff : 'a t * ('a -> 'a -> bool) -> 'a kind

and 'a var_cell = { mutable current : 'a }

and ('b, 'a) bind_cell = {
  b_lhs : 'b t;
  b_f : 'b -> 'a t;
  mutable b_rhs : 'a t option;
  (* The b_lhs.value_stamp we last used to run b_f. If b_lhs.value_stamp
     has since advanced, lhs has changed and f must be re-run; if not,
     any re-evaluation of this Bind node was triggered by rhs's value
     changing, and we just relay it. *)
  mutable b_lhs_seen_at : int;
}

let is_necessary (n : 'a t) = n.necessary_count > 0
let is_stale (n : 'a t) = n.in_heap

let kind_name : type a. a kind -> string = function
  | Var _ -> "Var"
  | Map _ -> "Map"
  | Map2 _ -> "Map2"
  | Bind _ -> "Bind"
  | Cutoff _ -> "Cutoff"
