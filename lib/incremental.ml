(* Public API. This is the real abstraction boundary (see
   incremental.mli): Node/Graph/Scheduler/Stats/Invariant are
   library-private (lib/dune's private_modules), so everything an
   external user of Propagate can reach goes through here or through
   Reference. *)

type runtime = Graph.t
type 'a t = 'a Node.t
type 'a var = { var_node : 'a Node.t; var_runtime : Graph.t }
type 'a observer = { obs_node : 'a Node.t; obs_runtime : Graph.t; mutable obs_active : bool }

exception Cycle_detected = Graph.Cycle_detected
exception Reentrant_call = Graph.Reentrant_call

let create () : runtime = Graph.create ()
let var (g : runtime) (init : 'a) : 'a var = { var_node = Graph.var g init; var_runtime = g }
let watch (v : 'a var) : 'a t = v.var_node
let set (v : 'a var) (x : 'a) : unit = Graph.set v.var_runtime v.var_node x
let map (g : runtime) (t : 'a t) ~(f : 'a -> 'b) : 'b t = Graph.map g t ~f
let map2 (g : runtime) (a : 'a t) (b : 'b t) ~(f : 'a -> 'b -> 'c) : 'c t = Graph.map2 g a b ~f
let bind (g : runtime) (t : 'a t) ~(f : 'a -> 'b t) : 'b t = Graph.bind g t ~f
let cutoff (g : runtime) (t : 'a t) ~(equal : 'a -> 'a -> bool) : 'a t = Graph.cutoff g t ~equal

let observe (g : runtime) (t : 'a t) : 'a observer =
  Graph.observe g t;
  { obs_node = t; obs_runtime = g; obs_active = true }

let disable (o : 'a observer) : unit =
  if o.obs_active then begin
    o.obs_active <- false;
    Graph.disable o.obs_runtime o.obs_node
  end

let value (o : 'a observer) : 'a =
  if not o.obs_active then invalid_arg "Incremental.value: observer has been disabled";
  Graph.value o.obs_runtime o.obs_node

let stabilize (g : runtime) : unit = Graph.stabilize g

module Stats = struct
  type t = {
    nodes_created : int;
    nodes_evaluated : int;
    nodes_invalidated : int;
    nodes_skipped_propagation : int;
    stabilizations : int;
    bind_recomputations : int;
    bind_relays : int;
    max_height_seen : int;
    cycle_rejections : int;
  }

  let snapshot (g : runtime) : t =
    let s = g.Graph.stats in
    {
      nodes_created = s.Stats.nodes_created;
      nodes_evaluated = s.nodes_evaluated;
      nodes_invalidated = s.nodes_invalidated;
      nodes_skipped_propagation = s.nodes_skipped_propagation;
      stabilizations = s.stabilizations;
      bind_recomputations = s.bind_recomputations;
      bind_relays = s.bind_relays;
      max_height_seen = s.max_height_seen;
      cycle_rejections = s.cycle_rejections;
    }
end

module Debug = struct
  type packed = Node.packed

  let pack (t : 'a t) : packed = Node.Pack t
  let height (t : 'a t) : int = t.Node.height
  let is_necessary (t : 'a t) : bool = Node.is_necessary t
  let is_stale (t : 'a t) : bool = Node.is_stale t
  let id (t : 'a t) : int = Node.Id.to_int t.Node.id
  let kind_name (t : 'a t) : string = Node.kind_name t.Node.kind
  let observer_count (t : 'a t) : int = t.Node.observer_count
  let necessary_count (t : 'a t) : int = t.Node.necessary_count
  let dependents_count (t : 'a t) : int = List.length t.Node.dependents
  let is_stabilizing (g : runtime) : bool = g.Graph.stabilizing
  let check_invariants (roots : packed list) : string list = List.map Invariant.describe (Invariant.check roots)
  let assert_invariants (roots : packed list) : unit = Invariant.check_ok roots
end
