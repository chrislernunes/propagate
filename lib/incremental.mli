(** Propagate's public API: an incremental computation runtime.

    A computation is represented as a dependency graph. Inputs are
    {!var}s; derived computations are built with {!map}, {!map2}, and
    {!bind}. Nothing recomputes until {!stabilize} is called, and only
    the subset of the graph that is both {e necessary} (reachable from
    an active {!observer}) and {e stale} (downstream of something that
    changed) is recomputed then.

    {1 Minimal example}
    {[
      let g = Incremental.create () in
      let x = Incremental.var g 10 in
      let y = Incremental.map g (Incremental.watch x) ~f:(fun x -> x * 2) in
      let obs = Incremental.observe g y in
      Incremental.stabilize g;
      assert (Incremental.value obs = 20);
      Incremental.set x 21;
      Incremental.stabilize g;
      assert (Incremental.value obs = 42)
    ]}

    {1 Multiple instances}
    [runtime] is an explicit handle, not global state: {!create} makes
    a fresh, fully independent instance, and every operation below
    that needs one takes it explicitly (except {!set}, {!disable}, and
    {!value}, whose argument already carries its owning runtime — see
    docs/design.md, "Implementation deviations", for why this replaced
    the RFC's originally-proposed generative functor). *)

(** A runtime: one independent incremental graph, its scheduler, and
    its stabilization state. Operations across two different
    [runtime]s are never implicitly connected — nothing stops you from
    passing a node from one runtime into another runtime's calls, but
    doing so is meaningless (the necessity/scheduling bookkeeping
    belongs to the runtime that created the node) and unsupported. *)
type runtime

(** ['a t] is a computation that produces a value of type ['a] once
    stabilized. Immutable from the outside: the only way to change
    what a [t] evaluates to is to change the input {!var}s it
    transitively depends on and stabilize again. *)
type 'a t

(** A mutable input cell of type ['a]. Distinct from ['a t] so that
    "this is a place mutation enters the graph" is visible at every
    call site — see {!watch}. *)
type 'a var

(** A live subscription to a {!t}'s value. Observing a node marks it
    (and everything it transitively depends on) as necessary, so it
    actually gets scheduled by {!stabilize}; disabling it (see
    {!disable}) allows the runtime to reclaim it once nothing else
    needs it. *)
type 'a observer

(** The exception a rejected cycle surfaces as. When {!bind}'s [f]
    would produce a dependency that is already reachable from the node
    being rebound — i.e. attaching it would close a cycle — the
    rebind is refused and this becomes that node's failed value,
    exactly as if [f] itself had raised it (see docs/semantics.md,
    "Cycle detection"): discovered via {!value}, not by {!stabilize}
    raising. The check runs strictly before any mutation, so refusing
    never leaves the graph structure changed, and refusing one bind's
    rebind does not stop the rest of that {!stabilize} pass from
    completing correctly. *)
exception Cycle_detected of string

(** Raised by {!set}, {!stabilize}, {!observe}, {!disable}, or
    {!value} if called from inside a computation that is itself
    running as part of an active {!stabilize} call on the same
    [runtime] (for instance, from inside a {!map}'s [f]). A
    computation's [f] should be a pure function of its already-supplied
    arguments; it must not reach back into the runtime that is in the
    middle of evaluating it. Constructing new nodes ({!var}, {!map},
    {!map2}, {!bind}, {!cutoff}) is deliberately *not* included in this
    restriction, since {!bind}'s [f] constructing new nodes is its
    entire purpose. *)
exception Reentrant_call of string

(** Create a fresh, independent runtime. *)
val create : unit -> runtime

(** [var g init] creates a new mutable input cell in [g] holding
    [init]. *)
val var : runtime -> 'a -> 'a var

(** [watch v] is the computation that reads [v]'s current (as of the
    last completed {!stabilize}) value. A pure type-level coercion —
    O(1), no runtime state touched. *)
val watch : 'a var -> 'a t

(** [set v x] schedules [v] to hold [x] as of the next {!stabilize}.
    Setting to a value that is physically equal ([==]) to the current
    one is a no-op (consistent with every node's default cutoff — see
    {!cutoff}). Calling [set] more than once on the same [v] before
    the next {!stabilize} is well-defined: only the last value takes
    effect, and downstream computations see exactly one invalidation
    walk, not one per [set] (see docs/semantics.md, "Repeated writes
    before stabilization"). O(1); the actual invalidation walk is
    deferred to {!stabilize}. *)
val set : 'a var -> 'a -> unit

(** [map g t ~f] is a computation that applies [f] to [t]'s value.
    [f] is assumed pure (see docs/semantics.md, "Purity assumption") —
    it receives a plain, already-computed ['a], never a live handle
    back into the runtime. *)
val map : runtime -> 'a t -> f:('a -> 'b) -> 'b t

(** [map2 g a b ~f] is a computation that applies [f] to both [a] and
    [b]'s values. *)
val map2 : runtime -> 'a t -> 'b t -> f:('a -> 'b -> 'c) -> 'c t

(** [bind g t ~f] is a computation whose dependency structure is
    itself determined by [t]'s value: whenever [t] changes, [f] is
    re-run on the new value to produce a (possibly entirely different)
    downstream node, and [bind]'s result tracks {e that} node from then
    on. This is the mechanism for dynamic dependencies — see
    docs/semantics.md, "Bind", for exactly when [f] re-runs versus when
    a value change is simply relayed. *)
val bind : runtime -> 'a t -> f:('a -> 'b t) -> 'b t

(** [cutoff g t ~equal] relays [t]'s value unchanged, but only
    propagates a value change downstream when [equal old new] is
    [false]. Every node already applies a default cutoff of physical
    equality ([==]); [cutoff] lets you supply something stronger (e.g.
    structural equality, or a tolerance check for floats) at the cost
    of calling [equal] on every recomputation. See docs/semantics.md,
    "Cutoff", including why physical equality was chosen as the
    default over structural equality. *)
val cutoff : runtime -> 'a t -> equal:('a -> 'a -> bool) -> 'a t

(** [observe g t] marks [t] (and transitively, everything it depends
    on) necessary and returns a handle to read its value after
    {!stabilize}. A node can have more than one active observer. *)
val observe : runtime -> 'a t -> 'a observer

(** [disable o] ends this subscription. Once nothing else observes or
    necessarily depends on the underlying node, the runtime detaches
    it and ordinary GC reclaims it — see docs/design.md, "Memory
    management". Idempotent: disabling an already-disabled observer is
    a no-op, not an error. *)
val disable : 'a observer -> unit

(** [value o] returns [o]'s value as of the most recently completed
    {!stabilize}. Raises the original exception if the underlying
    computation last failed (see docs/semantics.md, "Exceptions").
    Raises [Invalid_argument] if [o] has been {!disable}d, and
    [Failure] if [stabilize] has never run since [o] was created. *)
val value : 'a observer -> 'a

(** Recompute every stale, necessary node, in an order that never
    reads a stale dependency (Invariant I1). Atomic from the outside:
    {!value}, {!set}, {!observe}, {!disable}, and nested {!stabilize}
    are all rejected (raising {!Reentrant_call}) while a [stabilize]
    on the same [runtime] is in progress, so there is no way to
    observe an intermediate state. *)
val stabilize : runtime -> unit

(** Development/benchmark-mode counters. Plain running totals — see
    docs/design.md, "Instrumentation" — never a retained list of
    nodes, so reading these never affects what the runtime can
    garbage-collect. *)
module Stats : sig
  type t = {
    nodes_created : int;
    nodes_evaluated : int;
    nodes_invalidated : int;  (** transitions into "stale", i.e. into the scheduler *)
    nodes_skipped_propagation : int;  (** evaluated, but cutoff suppressed further propagation *)
    stabilizations : int;
    bind_recomputations : int;  (** times a Bind actually re-ran [f], rather than just relaying rhs's value *)
    bind_relays : int;
    max_height_seen : int;
    cycle_rejections : int;
  }

  val snapshot : runtime -> t
end

(** Introspection for tests and diagnostics. Not intended for use in
    normal application code — see the module-level note in
    docs/design.md, "Module boundaries", on why this exists as an
    explicit escape hatch rather than by leaving internals exposed. *)
module Debug : sig
  type packed  (** a [t], with its value-type parameter erased *)

  val pack : 'a t -> packed
  val height : 'a t -> int
  val is_necessary : 'a t -> bool
  val is_stale : 'a t -> bool
  val id : 'a t -> int
  val kind_name : 'a t -> string
  val observer_count : 'a t -> int
  val necessary_count : 'a t -> int
  val dependents_count : 'a t -> int
  val is_stabilizing : runtime -> bool

  (** [check_invariants roots] walks every node reachable from [roots]
      (via dependency and dependent edges in both directions) and
      returns a human-readable description of every invariant
      violation found — dependency height ordering, necessity-count
      consistency, scheduler membership, acyclicity, and dependents-list
      reciprocity. Empty list means clean. [roots] should include
      every node the caller cares about checking; there is no global
      node registry to fall back on (see docs/design.md, "Memory
      management" — such a registry would itself be a leak). *)
  val check_invariants : packed list -> string list

  (** Same as [check_invariants], but raises [Failure] with the
      combined description on the first non-empty result. *)
  val assert_invariants : packed list -> unit
end
