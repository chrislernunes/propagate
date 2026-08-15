# Complexity

| Operation | Cost | Note |
|---|---|---|
| `var` / `map` / `map2` / `cutoff` construction | O(1) | edge attach + height = 1 + max(dep heights) |
| `bind` construction | O(1) | rhs attached lazily, on first evaluation |
| `set` | O(1) | defers the invalidation walk to the next `stabilize` |
| `stabilize`, nothing pending | O(1) | heap-empty check |
| `stabilize`, D dirty nodes, k distinct occupied heights | O(D * (c + log k)) | log k from `Height_set.min_elt` per pop; see `docs/design.md` for why this replaced the RFC's cursor |
| `bind` rebind, common case | O(1) + O(fixup frontier) | see "Bind height fixup," below, for when the frontier is *not* small |
| cycle pre-check | O(1) typical, O(reachable region) worst case | see "Cycle pre-check," below |
| `observe`, subgraph size S, currently unnecessary | O(S) | real work: asking the engine to start tracking S nodes |
| `disable`, symmetric | O(S) | tears down S nodes' worth of necessity/edges |
| memory, steady state | O(N_necessary + E_necessary) | unnecessary subgraphs aren't retained by the engine (`docs/architecture.md`, "Memory management") |

## Bind height fixup: why the fixup frontier isn't always small

`rebind`'s height rule (`docs/semantics.md`, "Height fixup on rebind")
forces a freshly-attached rhs's height to at least `cursor + 1`, and that
increase must cascade forward through every one of the rhs's *existing*
dependents to keep I1 true for them too. In the common case that frontier
is empty or tiny — a fresh subgraph has no dependents yet, and rebinding
to a stable pre-existing node whose dependents already have adequate
height requires no cascade at all.

It stops being small in exactly one shape: a chain of N *distinct* bind
nodes — `bind1` depends on `base`, `bind2` depends on `bind1`, ...,
`bindN` depends on `bind(N-1)` — all constructed before any of them is
ever evaluated, then all made necessary together (one `observe()` on
`bindN`). By the time `bind1` is evaluated, `bind2 .. bindN` already
exist as live, scheduled dependents of the nodes ahead of them. `bind1`'s
own height bump cascades through the entire remaining chain in one
`bump_height` call — an O(N) cost for `bind1` alone — and then `bind2`'s
evaluation does the same for the (N-1)-node remainder it sees, and so on.
Total cost across the whole chain's first stabilization: O(N^2).

Measured directly: a chain of this shape at depth 3,000 completes in
roughly one second; depth 6,000 takes several seconds and does not scale
linearly with depth (see `docs/benchmarks.md`, "Dynamic dependencies," for
the exact numbers). See `docs/design.md`'s "Known limitations" for why
this wasn't fixed further given this project's time constraints, and for
why it's narrow: `test/stress`'s `test_repeated_bind_switching` shows
200,000 rebinds among a small, pre-existing pool of targets with no such
pathology — the problem is specifically about many *new* bind nodes
becoming necessary together in a long chain, not about repeated switching
among existing ones.

## Cycle pre-check

The naive form of this check — a full reachability search from the node
being rebound, every single rebind — has the same O(N^2) failure mode as
the height-fixup cascade above, for the identical reason (a long
pre-built chain of not-yet-evaluated binds, where each one's search walks
most of the remaining chain looking for a target it will not find). This
one *was* fixed: since every existing edge satisfies I1, reaching a
proposed new dependency via one or more hops requires
`height(new dependency) > height(node)` — a necessary condition for a
cycle, derived directly from an invariant already proven to hold, not a
heuristic. Checking it first is O(1), and it rules out the search
entirely in the common case (freshly-created subgraphs have height 0 or
1, almost always <= whatever height the rebinding node has already
reached). Applying this fast path alone took the pathological chain shape
above from "does not complete in reasonable time" to "completes, just not
linearly" — see `docs/design.md`'s "Bugs found" for the measurement that
motivated it and `lib/graph.ml`'s `rebind` for the implementation.

## The crossover point: why it moves, not just where it sits

Incremental cost is roughly `D * c_inc`, where `D` is the number of
touched nodes and `c_inc` bundles in the scheduler/height/cutoff
bookkeeping described above. Full recomputation is `N * c_naive`, with
none of that bookkeeping but paying for all `N` nodes regardless of what
changed. Which wins depends on the *ratio* `c_naive / c_inc`, not on
`D / N` alone: as the per-node computation `f` gets more expensive, the
fixed bookkeeping becomes negligible next to real work and incremental
wins at a higher and higher affected fraction; as `f` gets cheap, the
bookkeeping dominates and full recomputation wins earlier. `docs/
benchmarks.md`'s crossover study measures exactly this at two `f` costs
rather than asserting a single number, and the two costs cross over at
meaningfully different affected fractions — see that document for the
actual measured values.

## Parallelism

Not executed — see `docs/design.md`'s "Known limitations" for what was
attempted (building an OCaml 5.x switch via opam, to get Domains) and why
it didn't complete in this sandbox. What follows is the design reasoning
Section 19/25 asks for, worked through against this specific
architecture, without the benchmark numbers a real attempt would need
before drawing conclusions.

**Which nodes could safely execute concurrently.** Same-height nodes are
provably independent for evaluation purposes: I1 guarantees nothing at
height H depends on anything else also at height H, so two same-height
nodes never read each other's output within one pass. That's the natural
unit of parallelism here — evaluate one height bucket's nodes
concurrently, then synchronize before moving to the next bucket (a
bulk-synchronous-parallel shape, not fully asynchronous — a node one
height up must never start before everything below it in this pass has
finished, per I1).

**Where this would probably help.** Benchmark B (wide DAG, 300,000
independent branches, `docs/benchmarks.md`) is the shape most favorable
to this: every branch sits at the same height with no cross-dependencies,
so a bucket-parallel scheme would parallelize essentially the whole
workload with no synchronization inside a bucket.

**Where it probably wouldn't.** Anything chain-shaped (Benchmark A,
Benchmark C) has one node per height bucket for long stretches —
"parallelize a bucket of size 1" is pure overhead: domain
handoff/synchronization cost with no work to hide it behind. Given the
measured per-node cost in `docs/benchmarks.md`'s chain benchmark is in
the hundreds of nanoseconds to low microseconds, and cross-domain
synchronization is typically far more than that, a bucket-parallel
scheduler would very plausibly be *slower* than sequential on chain-
shaped or narrow graphs — consistent with the master prompt's own
expectation ("if it doesn't help, explain why") and with the general
finding in this space that fine-grained incremental node evaluation is
usually too cheap per unit to amortize parallel dispatch overhead unless
individual nodes do substantial work (Benchmark H's per-asset chain, or
the crossover study's "expensive" cost function, are closer to the
regime where it might pay off).

**What would need to change to try it for real.** The scheduler's bucket
structure (`lib/scheduler.ml`) would need a thread-safe (or Domain-safe)
insert path, since evaluating a bucket in parallel and having any of
those evaluations invalidate a *later*-height node means concurrent
inserts into the next bucket. `Stats`' counters would need to become
atomic or per-domain-then-merged. Neither is a large change, but neither
was made, since there was no working Domains build in this environment to
validate the change against — writing untested concurrent code is worse
than not writing it.
