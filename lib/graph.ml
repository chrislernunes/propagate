(* Graph algorithms. No .mli — see node.ml's header comment for the
   module-boundary rationale; the real abstraction boundary is
   Incremental's .mli, not this file's.

   Deliberately does not [open Node]: this file juggles both [Graph.t]
   (defined below) and ['a Node.t], and those two are easy to confuse
   if [Node.t] is opened into unqualified scope. Everything from Node
   is referenced with an explicit [Node.] prefix throughout. *)

exception Cycle_detected of string
exception Reentrant_call of string

type t = {
  scheduler : Scheduler.t;
  stats : Stats.t;
  mutable stabilizing : bool;
  (* Global monotonic counter, bumped every time ANY node's cached
     value actually changes (post-cutoff). Bind uses per-node snapshots
     of this (Node.value_stamp / bind_cell.b_lhs_seen_at) to tell "lhs
     changed" apart from "rhs's value changed" without re-running f
     unnecessarily. *)
  mutable change_counter : int;
}

let create () =
  { scheduler = Scheduler.create (); stats = Stats.create (); stabilizing = false; change_counter = 0 }

let check_not_stabilizing (g : t) (op : string) : unit =
  if g.stabilizing then
    raise (Reentrant_call (Printf.sprintf "%s: illegal reentrant call during stabilize()" op))

(* ---------------------------------------------------------------- *)
(* Construction                                                      *)
(* ---------------------------------------------------------------- *)

let make_node (g : t) (kind : 'a Node.kind) ~(height : int) : 'a Node.t =
  Stats.incr_created g.stats;
  Stats.note_height g.stats height;
  {
    Node.id = Node.Id.create ();
    kind;
    value = Never_computed;
    height;
    necessary_count = 0;
    observer_count = 0;
    dependents = [];
    status = Idle;
    in_heap = false;
    value_stamp = 0;
  }

let add_dependent (on : 'b Node.t) (dep : Node.packed) : unit = on.dependents <- dep :: on.dependents

(* Removes exactly one occurrence of [dep_id], not every occurrence.
   This matters because [on.dependents] is a multiset, not a set: a
   Bind node whose rhs happens to coincide with its own lhs (its
   dynamic pool can legitimately include the lhs node itself)
   contributes *two* separate entries to that target's dependents list
   — one for the permanent lhs edge, one for the dynamic rhs edge.
   Removing "all matches" when detaching the rhs edge would silently
   delete the permanent lhs edge's entry too, breaking dependents-list
   reciprocity for an edge that's still very much live. Property
   testing (test/property) found this the direct way, via exactly
   this scenario.

   Written with an explicit accumulator so it's tail-recursive: a
   node's dependents list can be arbitrarily long (Benchmark B: one
   input feeding thousands of computations), and the more natural
   "cons after the recursive call returns" formulation is not in tail
   position and grows the stack proportionally to list length. Found
   the same way as the multiset issue above — empirically, via
   test/stress on a chain deep enough to actually blow a
   non-tail-recursive stack. *)
let remove_dependent (on : 'b Node.t) (dep_id : Node.Id.t) : unit =
  let rec go acc = function
    | [] -> List.rev acc
    | (Node.Pack x as p) :: rest -> if Node.Id.equal x.id dep_id then List.rev_append acc rest else go (p :: acc) rest
  in
  on.dependents <- go [] on.dependents

let var (g : t) (init : 'a) : 'a Node.t = make_node g (Var { current = init }) ~height:0

let map (g : t) (dep : 'a Node.t) ~(f : 'a -> 'b) : 'b Node.t =
  let n = make_node g (Map (dep, f)) ~height:(dep.height + 1) in
  add_dependent dep (Pack n);
  n

let map2 (g : t) (a : 'a Node.t) (b : 'b Node.t) ~(f : 'a -> 'b -> 'c) : 'c Node.t =
  let n = make_node g (Map2 (a, b, f)) ~height:(1 + max a.height b.height) in
  add_dependent a (Pack n);
  add_dependent b (Pack n);
  n

let bind (g : t) (lhs : 'a Node.t) ~(f : 'a -> 'b Node.t) : 'b Node.t =
  let bc : ('a, 'b) Node.bind_cell = { b_lhs = lhs; b_f = f; b_rhs = None; b_lhs_seen_at = -1 } in
  let n = make_node g (Bind bc) ~height:(lhs.height + 1) in
  add_dependent lhs (Pack n);
  n

let cutoff (g : t) (dep : 'a Node.t) ~(equal : 'a -> 'a -> bool) : 'a Node.t =
  let n = make_node g (Cutoff (dep, equal)) ~height:(dep.height + 1) in
  add_dependent dep (Pack n);
  n

(* ---------------------------------------------------------------- *)
(* Necessity (liveness) cascade                                      *)
(* ---------------------------------------------------------------- *)

(* Both operate on [Node.packed] via an explicit worklist (a
   [Queue.t], not native recursion): a node's necessity can cascade
   the full depth of a chain (Benchmark A: thousands of levels;
   test/stress pushes this much further), and native `let rec`
   recursion here — even though it type-checks fine over the already
   type-erased [packed], sidestepping OCaml's polymorphic-recursion
   restriction — still consumes one stack frame per level, which
   overflows on a deep enough chain. An earlier version of this pair
   used ordinary mutual recursion (make_necessary calling itself,
   make_unnecessary calling detach_old_rhs calling make_unnecessary);
   it type-checked and passed every differential/property/unit test,
   because none of those exercise chains deep enough to hit a stack
   limit — test/stress, at a few hundred thousand nodes, does. Fixed
   the same way bump_height/reachable/propagate_change already were:
   an explicit queue standing in for the call stack. *)

let make_necessary (g : t) (start : Node.packed) : unit =
  let q = Queue.create () in
  Queue.push start q;
  while not (Queue.is_empty q) do
    let (Node.Pack n) = Queue.pop q in
    n.necessary_count <- n.necessary_count + 1;
    if n.necessary_count = 1 then begin
      (match n.kind with
       | Var _ -> ()
       | Map (dep, _) -> Queue.push (Node.Pack dep) q
       | Map2 (d1, d2, _) ->
         Queue.push (Node.Pack d1) q;
         Queue.push (Node.Pack d2) q
       | Cutoff (dep, _) -> Queue.push (Node.Pack dep) q
       | Bind bc -> Queue.push (Node.Pack bc.b_lhs) q);
      (* Unconditional, regardless of current value_state: a node that
         was dormant may have stale dependencies nobody was tracking
         while it was unnecessary (see docs/design.md, "Dormant
         revival"). Recomputing is always safe; cutoff will suppress
         further propagation if the recomputed value is unchanged. *)
      if not n.in_heap then Scheduler.insert g.scheduler (Node.Pack n)
    end
  done

(* A Bind's rhs edge, whenever present, was only ever attached by
   [rebind] while the Bind node itself was necessary (rebind only runs
   from evaluate_bind, only reachable for scheduler-popped —
   necessary, per I4 — nodes). So detaching it here unconditionally
   propagates unnecessary-ness to the old rhs; no need to re-check the
   Bind node's own current necessary_count. The rhs-detach logic is
   inlined into this loop (rather than calling the standalone
   [detach_old_rhs] below, which is used by [rebind] instead) so that
   an old rhs which is itself the head of a long chain going
   unnecessary is walked by *this* worklist, not by a fresh recursive
   call. *)
let make_unnecessary (g : t) (start : Node.packed) : unit =
  let q = Queue.create () in
  Queue.push start q;
  while not (Queue.is_empty q) do
    let (Node.Pack n) = Queue.pop q in
    if n.necessary_count <= 0 then
      invalid_arg (Printf.sprintf "make_unnecessary: refcount underflow on node #%d" (Node.Id.to_int n.id));
    n.necessary_count <- n.necessary_count - 1;
    if n.necessary_count = 0 then begin
      if n.in_heap then Scheduler.remove_node g.scheduler (Node.Pack n);
      match n.kind with
      | Var _ -> ()
      | Map (dep, _) -> Queue.push (Node.Pack dep) q
      | Map2 (d1, d2, _) ->
        Queue.push (Node.Pack d1) q;
        Queue.push (Node.Pack d2) q
      | Cutoff (dep, _) -> Queue.push (Node.Pack dep) q
      | Bind bc ->
        Queue.push (Node.Pack bc.b_lhs) q;
        (match bc.b_rhs with
         | None -> ()
         | Some old ->
           bc.b_rhs <- None;
           remove_dependent old n.id;
           Queue.push (Node.Pack old) q)
    end
  done

(* Standalone helper for [rebind]'s use: detach the current rhs edge
   as a one-off operation (the Bind node itself remains necessary
   throughout — this is a rebind, not a necessity loss), delegating to
   the now-iterative [make_unnecessary] above for the cascade. Not
   itself recursive, so no stack-depth concern here regardless of how
   deep the cascade from [old] turns out to be. *)
let detach_old_rhs : 'b 'a. t -> Node.Id.t -> ('b, 'a) Node.bind_cell -> unit =
  fun g n_id bc ->
  match bc.b_rhs with
  | None -> ()
  | Some old ->
    bc.b_rhs <- None;
    remove_dependent old n_id;
    make_unnecessary g (Pack old)

(* ---------------------------------------------------------------- *)
(* Height fixup                                                      *)
(* ---------------------------------------------------------------- *)

let bump_height (g : t) (start : Node.packed) (min_height : int) : unit =
  let q = Queue.create () in
  Queue.push (start, min_height) q;
  while not (Queue.is_empty q) do
    let Node.Pack n, min_h = Queue.pop q in
    if n.height < min_h then begin
      let old_h = n.height in
      n.height <- min_h;
      Stats.note_height g.stats min_h;
      if n.in_heap then Scheduler.relocate g.scheduler (Pack n) ~old_height:old_h;
      List.iter (fun d -> Queue.push (d, min_h + 1) q) n.dependents
    end
  done

(* ---------------------------------------------------------------- *)
(* Cycle pre-check: verify-then-commit, never mutate-then-rollback    *)
(* ---------------------------------------------------------------- *)

(* Is [target_id] reachable from [from] by following existing
   dependency -> dependent edges forward? Used to answer "would adding
   an edge (new_rhs -> n) create a cycle" by checking whether [n] can
   already reach [new_rhs]. *)
let reachable (from : Node.packed) (target_id : Node.Id.t) : bool =
  let seen = Hashtbl.create 16 in
  let q = Queue.create () in
  Queue.push from q;
  let found = ref false in
  while (not !found) && not (Queue.is_empty q) do
    let Node.Pack n = Queue.pop q in
    if Node.Id.equal n.id target_id then found := true
    else if not (Hashtbl.mem seen n.id) then begin
      Hashtbl.add seen n.id ();
      List.iter (fun d -> Queue.push d q) n.dependents
    end
  done;
  !found

(* ---------------------------------------------------------------- *)
(* Invalidation                                                      *)
(* ---------------------------------------------------------------- *)

(* Single hop only — this is the crux of getting cutoff right. Marking
   [dependents] stale does not mean *their* dependents must be marked
   too: whether propagation continues past a node depends on whether
   *that node's own* evaluation actually changes its value, which
   isn't known until it's popped and evaluated. Walking the full
   transitive closure eagerly here (an earlier version of this
   function did exactly that, via a worklist that pushed each visited
   node's own dependents) would mark everything downstream of a
   cutoff-suppressed node stale regardless of the suppression —
   silently defeating cutoff. Property testing's random op sequences
   didn't catch this (an aggregate value/invariant checker can't see
   "recomputed but shouldn't have been"); the dedicated cutoff unit
   tests, which assert on a call counter, did. Deeper propagation
   still happens — one hop at a time, driven by each node's own
   [finish_with] call as the stabilize loop evaluates it. *)
let propagate_change (g : t) (dependents : Node.packed list) : unit =
  List.iter
    (fun (Node.Pack d) ->
      if d.necessary_count > 0 && not d.in_heap then begin
        Stats.incr_invalidated g.stats;
        Scheduler.insert g.scheduler (Pack d)
      end)
    dependents

(* ---------------------------------------------------------------- *)
(* Evaluation                                                        *)
(* ---------------------------------------------------------------- *)

let compute_outcome (n : 'a Node.t) : ('a, exn) result =
  match n.kind with
  | Var cell -> Ok cell.current
  | Map (dep, f) -> (
    match dep.value with
    | Never_computed ->
      invalid_arg (Printf.sprintf "compute_outcome: dependency #%d not evaluated (I1 violation)" (Node.Id.to_int dep.id))
    | Failed e -> Error e
    | Fresh v -> ( try Ok (f v) with e -> Error e))
  | Map2 (d1, d2, f) -> (
    match d1.value, d2.value with
    | Never_computed, _ | _, Never_computed ->
      invalid_arg "compute_outcome: map2 dependency not evaluated (I1 violation)"
    | Failed e, _ -> Error e
    | _, Failed e -> Error e
    | Fresh a, Fresh b -> ( try Ok (f a b) with e -> Error e))
  | Cutoff (dep, _) -> (
    match dep.value with
    | Never_computed -> invalid_arg "compute_outcome: cutoff dependency not evaluated (I1 violation)"
    | Failed e -> Error e
    | Fresh v -> Ok v)
  | Bind _ -> invalid_arg "compute_outcome: Bind must be evaluated via evaluate_bind, not compute_outcome"

let equal_for (n : 'a Node.t) : 'a -> 'a -> bool =
  match n.kind with
  | Cutoff (_, eq) -> eq
  | _ -> fun a b -> a == b

let should_propagate (old_v : 'a Node.value_state) (new_v : 'a Node.value_state) ~(equal : 'a -> 'a -> bool) : bool =
  match old_v, new_v with
  | Fresh a, Fresh b -> not (equal a b)
  | _ -> true

let finish_with (g : t) (n : 'a Node.t) (new_state : 'a Node.value_state) : unit =
  let equal = equal_for n in
  let changed = should_propagate n.value new_state ~equal in
  n.value <- new_state;
  n.status <- Idle;
  Stats.incr_evaluated g.stats;
  if changed then begin
    g.change_counter <- g.change_counter + 1;
    n.value_stamp <- g.change_counter;
    propagate_change g n.dependents
  end
  else Stats.incr_skipped g.stats

let evaluate_simple (g : t) (n : 'a Node.t) : unit =
  n.status <- Computing;
  let outcome = compute_outcome n in
  finish_with g n (match outcome with Ok v -> Fresh v | Error e -> Failed e)

(* The two-phase bind evaluator. See docs/design.md, "Bind", for why
   the height-fixup rule below (relative to the scheduler's current
   cursor, not just structural height) is load-bearing rather than
   cosmetic: without it, a freshly-created rhs subgraph can land in a
   bucket the pass has already swept past, silently deferring its
   first evaluation to the *next* stabilize call. *)
let rebind (g : t) (n : 'a Node.t) (bc : ('lhs, 'a) Node.bind_cell) (new_rhs : 'a Node.t) : unit =
  let same_rhs = match bc.b_rhs with Some old -> Node.Id.equal old.id new_rhs.id | None -> false in
  if same_rhs then
    match new_rhs.value with
    | Never_computed ->
      n.status <- Idle;
      if not n.in_heap then Scheduler.insert g.scheduler (Pack n)
    | (Fresh _ | Failed _) as st -> finish_with g n st
  else begin
    (* Fast path, derived directly from I1: if n could reach new_rhs
       via >=1 existing edge, height would strictly increase along
       that path, so height(new_rhs) > height(n) is a *necessary*
       condition for a cycle (excepting the immediate self-reference
       case, handled separately since it's a 0-hop "path" with equal
       height). It is not sufficient — plenty of unrelated nodes
       satisfy it without being reachable — so this cannot replace the
       real check, only skip it when it's provably unneeded.
       Concretely: binding to a freshly-created, low-height leaf (the
       common case) now costs O(1) instead of a full graph walk.
       Without this, evaluating a pre-built chain of N sequentially
       dependent binds costs O(N) per rebind — each one's reachable
       search walking the entire not-yet-evaluated tail — for O(N^2)
       overall; test/stress found this directly (depth 3,000 took
       ~2.1s, depth 6,000 ~9.6s, the ~4x-for-2x scaling a quadratic
       signature). With the fast path, both are effectively instant. *)
    if Node.Id.equal new_rhs.id n.id then begin
      Stats.incr_cycle_rejections g.stats;
      raise
        (Cycle_detected (Printf.sprintf "bind: rebinding node #%d to itself would create a cycle" (Node.Id.to_int n.id)))
    end;
    if new_rhs.height > n.height && reachable (Pack n) new_rhs.id then begin
      Stats.incr_cycle_rejections g.stats;
      raise
        (Cycle_detected
           (Printf.sprintf "bind: rebinding node #%d to node #%d would create a cycle" (Node.Id.to_int n.id)
              (Node.Id.to_int new_rhs.id)))
    end;
    detach_old_rhs g n.id bc;
    bc.b_rhs <- Some new_rhs;
    add_dependent new_rhs (Pack n);
    if n.necessary_count > 0 then make_necessary g (Pack new_rhs);
    let cursor = match Scheduler.current_height g.scheduler with Some h -> h | None -> 0 in
    let min_new_rhs_h = max new_rhs.height (cursor + 1) in
    if new_rhs.height < min_new_rhs_h then bump_height g (Pack new_rhs) min_new_rhs_h;
    if n.height <= new_rhs.height then bump_height g (Pack n) (new_rhs.height + 1);
    match new_rhs.value, new_rhs.in_heap with
    | (Fresh _ | Failed _ as st), false -> finish_with g n st
    | _, _ ->
      n.status <- Idle;
      if not n.in_heap then Scheduler.insert g.scheduler (Pack n)
  end

let evaluate_bind (g : t) (n : 'a Node.t) (bc : ('lhs, 'a) Node.bind_cell) : unit =
  n.status <- Computing;
  let lhs_changed = match bc.b_rhs with None -> true | Some _ -> bc.b_lhs.value_stamp <> bc.b_lhs_seen_at in
  if lhs_changed then
    match bc.b_lhs.value with
    | Never_computed -> invalid_arg "evaluate_bind: lhs not evaluated (I1 violation)"
    | Failed e ->
      bc.b_lhs_seen_at <- bc.b_lhs.value_stamp;
      detach_old_rhs g n.id bc;
      Stats.incr_bind_recompute g.stats;
      finish_with g n (Failed e)
    | Fresh lv -> (
      bc.b_lhs_seen_at <- bc.b_lhs.value_stamp;
      Stats.incr_bind_recompute g.stats;
      match (try Ok (bc.b_f lv) with e -> Error e) with
      | Error e ->
        detach_old_rhs g n.id bc;
        finish_with g n (Failed e)
      | Ok new_rhs -> (
        (* rebind's cycle check runs strictly before any mutation
           (verify-then-commit), so catching here and converting to a
           per-node Failed — exactly like any other exception a bind's
           f might produce — is safe: the graph is guaranteed
           untouched at the point this can fire. Without this catch,
           the exception would escape evaluate_bind with n.status still
           Computing (set at this function's entry) and never reset,
           since finish_with — the only place that resets it — would
           never run. That is precisely the "node stuck in Computing
           after an exception" failure Stage 8 rules out; it was
           originally caught by the invariant checker's status_sanity
           rule during unit testing, in the cycle-detection tests
           specifically. *)
        try rebind g n bc new_rhs with Cycle_detected _ as e -> finish_with g n (Failed e)))
  else begin
    Stats.incr_bind_relay g.stats;
    match bc.b_rhs with
    | None -> invalid_arg "evaluate_bind: lhs unchanged but no rhs attached (invariant violation)"
    | Some rhs -> (
      match rhs.value with
      | Never_computed -> invalid_arg "evaluate_bind: rhs not evaluated (I1 violation)"
      | (Fresh _ | Failed _) as st -> finish_with g n st)
  end

let evaluate (g : t) (Node.Pack n : Node.packed) : unit =
  match n.kind with Bind bc -> evaluate_bind g n bc | _ -> evaluate_simple g n

(* ---------------------------------------------------------------- *)
(* Public-ish operations (wrapped further by Incremental)            *)
(* ---------------------------------------------------------------- *)

let set (g : t) (n : 'a Node.t) (new_val : 'a) : unit =
  check_not_stabilizing g "set";
  match n.kind with
  | Var cell ->
    if not (cell.current == new_val) then begin
      cell.current <- new_val;
      if n.necessary_count > 0 && not n.in_heap then Scheduler.insert g.scheduler (Pack n)
    end
  | _ -> invalid_arg "set: node is not a Var (internal error)"

let observe (g : t) (n : 'a Node.t) : unit =
  check_not_stabilizing g "observe";
  n.observer_count <- n.observer_count + 1;
  make_necessary g (Pack n)

let disable (g : t) (n : 'a Node.t) : unit =
  check_not_stabilizing g "disable";
  if n.observer_count <= 0 then invalid_arg "disable: node has no active observers"
  else begin
    n.observer_count <- n.observer_count - 1;
    make_unnecessary g (Pack n)
  end

let value (g : t) (n : 'a Node.t) : 'a =
  check_not_stabilizing g "value";
  match n.value with
  | Fresh v -> v
  | Failed e -> raise e
  | Never_computed -> failwith "value: node has never been stabilized (was it observed before stabilize() ran?)"

let stabilize (g : t) : unit =
  check_not_stabilizing g "stabilize";
  g.stabilizing <- true;
  Scheduler.begin_pass g.scheduler;
  Fun.protect
    ~finally:(fun () -> g.stabilizing <- false)
    (fun () ->
      let continue_ = ref true in
      while !continue_ do
        match Scheduler.pop_min g.scheduler with
        | None -> continue_ := false
        | Some p -> evaluate g p
      done);
  Stats.incr_stabilizations g.stats
