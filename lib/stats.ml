(* Instrumentation. Deliberately just counters: a "list of all nodes
   ever created" would be exactly the kind of accidental retention that
   defeats the necessity-refcount memory story (see docs/design.md,
   "Risk 5"). *)

type t = {
  mutable nodes_created : int;
  mutable nodes_evaluated : int;
  mutable nodes_invalidated : int;   (* times a node transitioned unnecessary/idle -> stale *)
  mutable nodes_skipped_propagation : int; (* evaluated, but cutoff suppressed further propagation *)
  mutable stabilizations : int;
  mutable bind_recomputations : int; (* times a Bind actually re-ran f, vs just relaying *)
  mutable bind_relays : int;
  mutable max_height_seen : int;
  mutable cycle_rejections : int;
}

let create () =
  {
    nodes_created = 0;
    nodes_evaluated = 0;
    nodes_invalidated = 0;
    nodes_skipped_propagation = 0;
    stabilizations = 0;
    bind_recomputations = 0;
    bind_relays = 0;
    max_height_seen = 0;
    cycle_rejections = 0;
  }

let incr_created s = s.nodes_created <- s.nodes_created + 1
let incr_evaluated s = s.nodes_evaluated <- s.nodes_evaluated + 1
let incr_invalidated s = s.nodes_invalidated <- s.nodes_invalidated + 1
let incr_skipped s = s.nodes_skipped_propagation <- s.nodes_skipped_propagation + 1
let incr_stabilizations s = s.stabilizations <- s.stabilizations + 1
let incr_bind_recompute s = s.bind_recomputations <- s.bind_recomputations + 1
let incr_bind_relay s = s.bind_relays <- s.bind_relays + 1
let incr_cycle_rejections s = s.cycle_rejections <- s.cycle_rejections + 1
let note_height s h = if h > s.max_height_seen then s.max_height_seen <- h

let copy s = { s with nodes_created = s.nodes_created }
