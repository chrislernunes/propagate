# Architecture

## Module layers

```
   Incremental (public API, lib/incremental.ml + .mli)
        |
        v
      Graph  ----uses---->  Scheduler
        |                       |
        v                       v
      Node   <---------- both operate on Node.packed

   Reference (lib/reference.ml) — structurally independent,
   shares no types or code with the above.
```

- **Node** (`lib/node.ml`): the shared mutable record every computation
  kind is built from, plus the GADT existential wrapper (`packed`) used
  anywhere dependents/scheduler buckets need to hold nodes of differing
  result types. No behavior of its own beyond a couple of trivial
  accessors (`is_necessary`, `is_stale`, `kind_name`).
- **Scheduler** (`lib/scheduler.ml`): the height-bucketed recompute
  structure. Knows nothing about invalidation, necessity, or evaluation —
  just "insert this node," "give me the one at the lowest currently
  occupied height," "remove this node," "relocate this node to its
  now-different height."
- **Graph** (`lib/graph.ml`): everything else — construction, the
  necessity cascade, height fixup, the cycle pre-check, invalidation,
  evaluation (including the two-phase bind logic), and the `stabilize`
  loop. This is the module every other piece of documentation is really
  describing.
- **Stats** (`lib/stats.ml`): plain mutable counters, deliberately never a
  retained collection of nodes (see "Memory management" below).
- **Invariant** (`lib/invariant.ml`): the debug-only checker (Stage 5),
  walking a caller-supplied root set and reporting violations of I1, I3,
  I4, I7, and dependents-list reciprocity.
- **Incremental** (`lib/incremental.ml` + `.mli`): the public API. Thin —
  its job is wrapping `'a var`/`'a observer` with their owning `runtime`
  for self-contained `set`/`disable`/`value`, and hiding everything above
  behind the real abstraction boundary (see `docs/design.md`, "Module
  boundaries").
- **Reference** (`lib/reference.ml`): a second, independent evaluator used
  as the differential-testing answer key and as the "full recomputation"
  side of the crossover benchmark. Shares no types, cache, scheduler, or
  invalidation logic with the above — see its header comment for exactly
  what it does keep (intra-call memoization, for DAG-sharing fairness)
  and why that's not the same thing as an incremental cache.

## Data flow for one `stabilize()` call

```
 mutation                 invalidation              stabilization        evaluation
(set x v)     -->    (mark x stale,     -->    (pop lowest-height   -->  (compute_outcome,
                       insert into                stale node)             cutoff-gated
                       scheduler)                                         finish_with,
                                                                           one-hop
                                                                           propagate_change
                                                                           to that node's
                                                                           own dependents)
```

`propagate_change` deliberately only marks the *immediate* dependents of
whatever just changed. The loop above is what actually walks the graph:
each popped node's own evaluation decides, via `finish_with`'s cutoff
check, whether *its* dependents get marked in turn. See
`docs/design.md`'s "Bugs found" section for why this one-hop-at-a-time
shape is load-bearing rather than incidental.

## Memory management

Liveness is a plain refcount (`necessary_count` = `observer_count` +
count of necessary dependents, mechanically checked by Invariant's I3
rule). The moment a node's count reaches zero, `make_unnecessary` removes
it from the scheduler if present and detaches its dependency edges (for
`Bind`, this includes tearing down the current rhs edge). Once nothing
external holds a reference to a fully-detached subgraph, ordinary OCaml
GC reclaims it — there is no separate "graph GC" pass and no global
registry of nodes. `Stats` is exactly why: every counter in it is a plain
mutable int, incremented at the relevant event, never a list or table of
node references. A registry would be the single easiest way to
accidentally defeat the whole refcount story, so the codebase doesn't
have one; `test/unit/memory_tests.ml` and `test/stress`'s repeated-cycle
tests are the check that this actually holds in practice, via bounded
`Gc.stat` word-count assertions (never exact — see those files for why
exact GC assertions are the wrong tool here).

## What `Debug` exposes, and why it's shaped the way it is

`Incremental.Debug` is the one deliberate crack in the abstraction
boundary: `height`, `is_necessary`, `is_stale`, `id`, `kind_name`,
`observer_count`, `necessary_count`, `dependents_count`,
`is_stabilizing`, and `pack` (erasing a node's type parameter so
heterogeneous nodes can be collected into one root list), plus
`check_invariants`/`assert_invariants`. Every one of these exists because
some test file needed it for a targeted assertion (`test/invariant.ml`'s
per-invariant checks read several of these directly rather than only
calling the aggregate checker) — nothing was added speculatively. It's
intentionally *not* exposed as part of the primary `Incremental` API
surface, per the master prompt's Section 26 guidance not to leak
scheduler/node internals into the API a real caller would use.
