# Semantics

## The state model: four independent axes, not one state machine

A node's status is tracked along four axes that update on different
triggers, rather than one combined `Invalid/Valid/Stale/Computing` enum.
Collapsing them loses information (there's no single state for "valid,
but nobody currently needs it").

| Axis | Values | What it answers | Where it lives |
|---|---|---|---|
| Liveness | necessary / unnecessary | Is anyone consuming this? | `necessary_count > 0` |
| Freshness | stale / not | Does the cache reflect current inputs? | `in_heap` (I2: this *is* the definition, not a derived fact) |
| Eval status | Idle / Computing | Is this node's compute function on the stack right now? | `status` |
| Result | Never_computed / Fresh / Failed | What's actually cached? | `value` |

## Repeated writes before stabilization

`set x v1; set x v2; set x v3; stabilize ()` evaluates `x`'s dependents
exactly once, using `v3`. Mechanism: `set` is O(1) — it only overwrites
the var's raw cell and, if the var wasn't already stale, marks it stale
(inserts into the scheduler). It does *not* walk dependents; that
happens later, uniformly, when the var itself is popped and evaluated
during `stabilize`. A second and third `set` before that point just
overwrite the cell again (already stale, so no further scheduler work).
The full downstream invalidation walk therefore happens exactly once
per `stabilize` call, regardless of how many `set`s preceded it — see
`test/unit/core_tests.ml`'s `test_repeated_set_single_evaluation`, which
asserts this via a call counter, not just a final value.

## Evaluation order (Invariant I1)

For every dependency edge, `height(dependency) < height(dependent)`,
always (barring a documented in-flight moment during height fixup, which
must resolve back to this or raise `Cycle_detected`). The scheduler pops
nodes in increasing height order, so a node is never evaluated while any
of its dependencies are stale — by the time anything at height H is
popped, everything at height < H that could affect it has already been
evaluated this pass. This is checked mechanically by
`Invariant.check`'s I1 rule, and relied on directly by `compute_outcome`,
which treats a `Never_computed` dependency at evaluation time as an
`invalid_arg`-raising bug, not a normal case to handle gracefully.

## Invalidation is one hop at a time, not an eager transitive walk

When a node's value actually changes (post-cutoff), `propagate_change`
marks only its *immediate* dependents stale (inserts them into the
scheduler, if they're necessary and not already stale). It does not
recurse into their dependents. Deeper propagation happens because the
main `stabilize` loop will, in due course, pop each of those dependents,
evaluate it, and call `finish_with` on it — which runs the *same* cutoff
check and only then decides whether to mark *its own* dependents stale
in turn.

This one-hop shape is not a simplification for its own sake: it is what
makes cutoff correct. Marking a value's entire transitive downstream
region stale eagerly — before any of those nodes have actually been
re-evaluated — would invalidate things that a cutoff-suppressed node
further upstream would otherwise have shielded. An earlier version of
this function did exactly that (matching the RFC's original sketch) and
shipped for a while before a cutoff-specific unit test caught it; see
`docs/design.md`'s "Bugs found" for the full story.

## Bind: which trigger re-runs `f`, and which just relays

A `Bind` node has two distinct triggers, and confusing them is the
easiest way to get this wrong:

- **lhs changed** → re-run `f` on the new lhs value, get a (possibly
  different) rhs node, and rebind to it.
- **rhs's value changed** (because something *rhs* depends on changed) →
  just relay the new value. Do not re-run `f`.

The distinction is made via a monotonic global `change_counter`
(incremented every time *any* node's cached value actually changes) and
a per-bind snapshot, `b_lhs_seen_at`, updated every time `f` is run. On
each evaluation: if `bc.b_lhs.value_stamp <> bc.b_lhs_seen_at`, lhs
changed — re-run `f`. Otherwise, this evaluation was triggered by rhs,
and the bind just relays `bc.b_rhs`'s current value.
`test/differential/test_differential.ml`'s `test_bind_switch_existing`
asserts both directions explicitly via the `bind_recomputations` /
`bind_relays` counters, not just via the resulting value (which would be
correct either way and wouldn't catch `f` being re-run unnecessarily).

### Height fixup on rebind

When `f` produces a new rhs, its height might be far too low for where
the scheduler currently is in this pass (the common case: a freshly
built rhs subgraph often starts at height 0 or 1). Naively attaching it
at its structural height risks landing in a bucket the pass has already
swept past — silently deferring its first evaluation to the *next*
`stabilize` call. The fix, applied uniformly whether rhs is brand new or
a deep pre-existing node:

```
height(new_rhs) <- max(structural_height(new_rhs), current_cursor() + 1)
height(bind)    <- max(height(bind), height(new_rhs) + 1)
```

If `new_rhs` isn't already `Fresh`/`Failed` after this (new, or itself
still stale), the bind doesn't produce a value this round — it's
re-enqueued at its new height and revisited once `new_rhs` settles,
which is guaranteed to happen first by construction. If `new_rhs` is
already settled (rebinding back to something previously computed), the
bind relays immediately.
`test/differential/test_differential.ml`'s
`test_bind_fresh_subgraph_same_pass` is the direct regression test for
this: it asserts the rebind settles within the *same* `stabilize` call by
checking the stabilization counter doesn't need to increase.

## Cutoff

Every node applies a default cutoff of physical equality (`==`) between
its old and new value before deciding whether to propagate. `cutoff t
~equal` wraps a node with a stronger, caller-supplied equality instead.

The default was chosen over structural equality (`=`) deliberately.
Structural equality is a real footgun for this purpose: `nan <> nan`
under `(=)` silently defeats it for any float-heavy pipeline (see
`test/unit/cutoff_tests.ml`'s two nan tests — one with `Float.equal`,
which treats nan as equal to itself and does suppress; one with `(=)`,
which doesn't), and it risks surprising behavior on anything containing
a closure or other non-comparable value. Physical equality is never
wrong and is not a no-op the way it might sound: OCaml immediates (small
ints, bools, `None`, `[]`, no-argument variant constructors) are shared,
so `==` genuinely catches real cases — see
`test_default_cutoff_suppresses_on_immediate_values` and
`test_cutoff_on_immediate_variant`. It buys nothing for boxed values
(records, strings, freshly-allocated tuples) unless the computation
explicitly returns a shared value — see
`test_default_cutoff_is_near_noop_for_boxed_values`, which asserts this
limitation directly rather than leaving it as folklore.

`cutoff`'s own evaluation is a relay (read the dependency's current
value, apply the custom `equal` instead of physical equality when
deciding whether to propagate); it does not change what the dependency
itself computes.

## Exceptions

An exception raised by a `map`/`map2`/`bind`'s function is caught at
that single call site and converted to `Failed exn` for that node,
reusing exactly the same propagation machinery as an ordinary value
change (a node's dependents get marked stale precisely as if its value
had changed). A dependent of a `Failed` node short-circuits to `Failed`
itself without ever calling its own function —
`test/unit/exception_tests.ml`'s
`test_dependent_short_circuits_without_calling_f` checks this via a call
counter, the same technique used for the cutoff bug. `value` on a
`Failed` observer re-raises the original exception. A `Failed` node is
not retried automatically; like a `Fresh` node, it only re-evaluates when
something it actually depends on changes. Graph structure is untouched
by a failure, and `stabilize` can always be called again — see
`test_stabilize_retriable_after_exception`.

No path through `evaluate_simple` or `evaluate_bind` can leave a node
stuck in `Computing`: every branch — success, a caught user exception, a
caught `Cycle_detected`, or "waiting for a bind's rhs to settle" —
reaches either `finish_with` (which unconditionally sets `status <-
Idle`) or an explicit reset. `Invariant.check`'s `status_sanity` rule is
the mechanical form of this guarantee, and it's what caught the one case
where this wasn't yet true (see `docs/design.md`, "Bugs found").

## Cycle detection

`bind`'s cycle check is verify-then-commit: before attaching a proposed
edge, a reachability search asks whether the node being rebound could
already reach the proposed new dependency via existing edges. If yes,
the edge is never attached — nothing is mutated — and the exception
becomes that node's `Failed` value, exactly as if its `f` had raised it
directly (see `docs/design.md`, "Cycle handling becomes a per-node
Failed", for why this was chosen over letting the exception escape
`stabilize`). One rejected cycle therefore doesn't stop the rest of that
`stabilize` pass from evaluating everything unrelated correctly —
`test/unit/cycle_tests.ml`'s
`test_cycle_via_nested_bind_chain_rejected` asserts an unrelated node in
the same pass still gets its correct value.

The reachability search itself has a fast path: since every existing
edge satisfies I1, a node reaching the proposed new dependency via one
or more existing hops would require `height(new dependency) >
height(node)`. That's a necessary (not sufficient) condition for a
cycle, so whenever it's false, the O(reachable-region) search is skipped
entirely — see `docs/complexity.md`, "Cycle pre-check", for the
performance story this fixes.

## Reentrancy

`set`, `stabilize`, `observe`, `disable`, and `value` all reject calls
made from inside a computation that's itself running as part of an
active `stabilize` on the same runtime, raising `Reentrant_call`. This
is a deliberate broadening of the RFC's original list (which named only
`set`/`stabilize`/`observer.value`): `observe`/`disable` mid-pass would
let necessity change out from under the scheduler's current traversal in
ways not proven safe, and banning them costs nothing, since there's no
clearly motivated use case for allowing it.

Constructing new nodes (`var`, `map`, `map2`, `bind`, `cutoff`) is
deliberately *not* restricted — this is `bind`'s entire mechanism, since
its `f` routinely builds new nodes as part of producing a new rhs (see
`test/unit/reentrancy_tests.ml`'s
`test_construction_during_stabilize_is_allowed`).

The reentrancy flag itself is exception-safe: `stabilize` wraps its main
loop in `Fun.protect ~finally:(fun () -> g.stabilizing <- false)`, so
even an unexpected internal exception (an invariant-violation
`invalid_arg`, say — a genuine implementation bug, deliberately *not*
caught and converted to a per-node `Failed`, since that would mask a
real bug as if it were an ordinary user-function exception) still resets
the flag before propagating, rather than permanently bricking the
runtime — `test_runtime_not_bricked_after_reentrant_call` is the direct
check.

## Dormant revival

A node that goes unnecessary and later becomes necessary again is always
force-recomputed on revival, regardless of its current cached
`value_state` — never treated as "probably still fine." While
unnecessary, a node's dependencies may have kept changing without
anyone tracking it (a shared dependency that's still necessary elsewhere
continues updating normally; the dormant node just isn't watching). The
unconditional recompute is always safe — cutoff will suppress further
propagation if the recomputed value happens to be unchanged — at the
cost of sometimes redoing work that would have produced the same
answer. See `test/unit/core_tests.ml`'s `test_dormant_revival_recomputes`
and `docs/design.md`'s "Known limitations" for the measured cost of this
conservatism.
