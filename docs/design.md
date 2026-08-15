# Design — accepted decisions and deviations from the Stage 0 RFC

This document records what the Stage 0 RFC got right, where implementation
proved it wrong, and every deliberate deviation, with reasoning. Nothing
here is retrospective tidying: each deviation below was driven by a
specific compile error, test failure, or measurement, not by taste.

## Module boundaries

The RFC's five-layer split (Node / Graph / Scheduler / Incremental /
Reference) survived implementation intact. What changed is where the
`.mli` abstraction boundary sits. The RFC's own file list implied one
`.mli` per module; the actual repository gives `.mli`s only to
`incremental.ml` (the real public API) and leaves `node.ml`, `graph.ml`,
`scheduler.ml`, `stats.ml`, and `invariant.ml` fully transparent to each
other, marked `private_modules` in `lib/dune` so they're invisible to
anything outside the library. The boundary that matters is
library-external vs. library-internal, not file-by-file — Graph needs deep,
unrestricted access to Node's constructors, and manufacturing a
restrictive `.mli` for Node would only have added ceremony with no actual
safety benefit, since Graph is the only consumer that matters. A `Debug`
submodule on `Incremental` is the deliberate, narrow escape hatch that
lets test code (property, invariant, unit) reach in for introspection and
invariant checking without punching a hole in the real boundary.

## API: handle instead of functor

The RFC proposed `module Make () : Incremental` — a generative functor —
specifically so that two independent runtimes would be different, mutually
incompatible types, preventing a node from graph A being passed to graph
B's operations by accident.

Implementation uses an explicit handle instead: `type runtime`, created via
`create : unit -> runtime`, threaded through every operation that needs
it. This trades away that one compile-time guarantee (nothing stops
`Incremental.set` from being called with a var from a different runtime —
though the necessity/scheduler bookkeeping simply wouldn't make sense
across runtimes, so it's a *meaningless* operation rather than a memory-
unsafe one) for something that mattered more in practice: property and
differential testing construct many independent runtimes, often thousands
per test run via QCheck2, and `Incremental.create ()` returning a plain
value is trivially cheap to spin up in a loop. A functor application in
the same position is heavier ceremony for the same job. If cross-runtime
type safety becomes a real requirement later, the functor can be layered
on top of the handle-based core trivially:

```ocaml
module Make () = struct
  type t = Runtime.t
  let g = Runtime.create ()
  let var init = Incremental_core.var g init
  (* ... *)
end
```

`'a var` and `'a observer` bundle their owning `runtime` internally, so
`set`, `disable`, and `value` don't need it passed explicitly — only the
"construct something new" operations (`var`, `map`, `map2`, `bind`,
`cutoff`, `observe`, `stabilize`, `Stats.snapshot`) do, since a
freshly-constructed node has nothing else to infer its runtime from.

## `propagate.ml` -> `incremental.ml`

The RFC's file list uses `propagate.ml` as the public API file. The actual
public module lives in `incremental.ml`, matching the RFC's own naming for
the signature (`module Incremental : sig ... end`) and sidestepping an
OCaml/Dune wrinkle: when a module's filename matches its containing
library's name, Dune's wrapping behavior around that module changes in
ways not worth the ambiguity for a project this size. Purely cosmetic; no
semantic effect. `Propagate` remains the library name and namespace
(`Propagate.Incremental`, `Propagate.Reference`).

## Scheduler: `Set`-based minimum lookup instead of an explicit cursor

The RFC sketched an explicit integer cursor that only ever advances within
a pass, justified by the claim that insertions during a pass only ever
target strictly greater heights than whatever's currently being processed
(true — see `docs/semantics.md`, "Evaluation order"). The implementation
doesn't track that cursor as a separate mutable field; instead,
`Scheduler.pop_min` asks `Height_set.min_elt` (an OCaml `Set.Make(Int)`)
fresh every time. The same monotonic-within-a-pass property emerges
automatically — new insertions can only raise the minimum, never lower it,
mid-pass — without needing to reason about resetting a cursor between
`stabilize` calls or plumbing it through. Cost is `O(log k)` per pop across
`k` distinct occupied heights rather than the RFC's hoped-for amortized
`O(1)` sweep; `log k` is negligible next to real per-node evaluation cost
in every benchmark in `docs/benchmarks.md`. `Scheduler.current_height`
(the height of whatever was most recently popped) still exists and is
exactly what `rebind`'s height-fixup rule needs as "the current cursor."

## Dependents storage: `packed list`, not an intrusive doubly-linked list

The RFC flagged this as an open choice and specifically suggested starting
with the simpler structure and only cutting over if a benchmark showed the
O(width) cost of list-based removal actually mattered. That's what
happened: dependents are stored as a plain `Node.packed list`, add is
O(1) prepend, remove is a single-occurrence tail-recursive scan (see
"Bugs found" below for why it has to be single-occurrence). No benchmark
in this repository showed this dominating — Benchmark B (wide DAG, 300,000
branches) never removes those edges at all, since plain `map`/`map2`/
`cutoff` edges are permanent. If a future workload does high-churn
add/remove on a single high-fan-out node, an intrusive list with O(1)
removal-by-handle is the documented upgrade path, deferred exactly as the
RFC proposed.

## Cycle handling becomes a per-node `Failed`, not an exception through `stabilize`

The RFC didn't fully specify whether a rejected cycle should escape
`stabilize()` as a raised exception or be contained per-node. Implementation
settled this in favor of containment, for consistency: `rebind`'s cycle
check runs strictly before any mutation (verify-then-commit, exactly as
designed), so catching `Cycle_detected` right there and converting it to
`finish_with g n (Failed e)` is safe by construction, and it means one
bind's rejected cycle doesn't stop the rest of that `stabilize` pass from
evaluating correctly. This is now uniform with how every other exception a
bind's `f` might raise is handled. See `docs/semantics.md`, "Cycle
detection", and `test/unit/cycle_tests.ml`, whose docstring explains the
same decision at the point it's exercised.

## Bugs found during implementation (and how)

Everything above is a deliberate design choice, documented up front. The
items below are genuine bugs — caught by the test suite doing its job —
kept here rather than quietly fixed and forgotten, because how they were
found is itself informative about which testing layer catches which class
of problem.

**Invalidation walked the full transitive closure eagerly, defeating
cutoff.** The original `propagate_change` was a multi-hop worklist that
marked a changed node's entire downstream reachable region stale in one
call — matching the RFC's own Section 5 sketch fairly literally. This is
wrong once cutoff can suppress propagation: whether a change should
continue past a node depends on whether *that node's own* evaluation
actually produces a different value, which isn't knowable until it's
popped and evaluated. The fix (now in `lib/graph.ml`) marks only the
immediate one-hop `dependents` stale; deeper propagation happens
naturally, one hop at a time, as the stabilize loop evaluates each node
and its own `finish_with` call decides whether to continue. Found by
`test/unit/cutoff_tests.ml`: a downstream call counter that should have
stayed at 0 came back at 1. Not found by `test/property` or
`test/differential` — an aggregate value/invariant checker can't
distinguish "recomputed to the same value" from "correctly never
recomputed"; only a call-counting unit test can. This is the most
important bug found in the project: it's a correctness bug that every
other layer of testing was structurally unable to see.

**A rejected cycle left the node stuck in `Computing` forever.**
`evaluate_bind` sets `n.status <- Computing` at entry; only `finish_with`
resets it to `Idle`. Before the fix, `rebind`'s cycle check could raise
past that point without ever reaching `finish_with`. Not a *visible*
correctness bug in this implementation (nothing else reads `status` to
gate behavior), but a real one relative to the RFC's explicit Stage 8
requirement and a latent hazard for any future code that does check it.
Found by the invariant checker's `status_sanity` rule, called from
`test/unit/cycle_tests.ml` after a rejected cycle. Fixed by catching
`Cycle_detected` at the one call site where `rebind` can raise it and
routing through `finish_with` like any other exception (see "Cycle
handling" above).

**Necessity propagation used native recursion, and blew the stack at real
scale.** `make_necessary`/`make_unnecessary` were written as ordinary
`let rec` functions over `Node.packed` — which sidesteps OCaml's
polymorphic-recursion typing restriction (packed is already
type-erased), but does nothing about stack *depth*: an `observe()` call
at the end of a long chain cascades one native call frame per level.
Every differential, property, and unit test passed, because none of them
build chains anywhere near deep enough to hit a stack limit. `test/stress`
does: a plain 500,000-node chain segfaulted with `Stack overflow` on
`observe`. Rewritten as an explicit `Queue.t`-based worklist, matching how
`bump_height`, `reachable`, and `propagate_change` already worked; a
million-node chain now observes, stabilizes, and disables without issue
(`test/stress/test_stress.ml`). A related non-tail-recursive helper
(`remove_dependent`'s original formulation, cons-after-recursive-call) was
fixed the same way, for the same reason, found the same way.

**A Bind whose dynamic pool includes its own lhs corrupts an unrelated
edge.** `remove_dependent` originally removed *every* entry matching a
given node id. That's wrong whenever a target can be a dependent of a node
through two logically distinct edges at once — which happens exactly when
a bind's `f` returns its own lhs node as the new rhs (legal, and not even
unusual: a dynamic pool that includes "route back to my own input" is a
reasonable thing to build). The lhs edge is permanent; the rhs edge comes
and goes. With blind removal, detaching the rhs edge deleted *both*
entries, silently breaking the permanent lhs edge's reciprocal entry in
the dependents list. Found by `test/property`: QCheck2 generated exactly
this shape and shrank it to a minimal repro in seconds; the invariant
checker's `edge_reciprocity` rule caught it. Fixed by making
`remove_dependent` remove exactly one occurrence
(`test/invariant/test_invariant.ml`'s
`test_regression_bind_pool_includes_own_lhs` keeps this as a named,
human-readable regression case rather than only a shrunk QCheck2
counterexample).

**Bind chains scale worse than linearly in one specific, narrow shape.**
Not a correctness bug — a measured performance characteristic, kept as a
documented limitation rather than hidden. See "Known limitations" below
and `test/stress/test_stress.ml`'s `test_deep_bind_chain_known_limitation`.

## Known limitations

**Long chains of distinct, sequentially-dependent binds becoming necessary
at once scale worse than linearly.** `rebind`'s height-fixup rule bumps a
freshly-attached rhs's height to at least `(scheduler cursor + 1)`, and
that bump must cascade forward through every existing dependent to
preserve I1 (dependency height < dependent height) — see
`docs/complexity.md`, "Bind", for the full derivation. In most shapes this
cascade is cheap or empty. In one specific shape — a chain of N *distinct*
bind nodes, all constructed before the first one is ever evaluated, then
made necessary all at once (a single `observe` at the far end, or a
disable/reobserve cycle) — the entire remaining chain already exists as
live, scheduled nodes by the time the first bind evaluates, so each
rebind's cascade walks most of what's left. Measured during development: a
6,000-deep chain of this shape took several seconds and did not scale
linearly with depth (see `docs/benchmarks.md`, "Dynamic dependencies").

Two mitigations were applied where they were cheap and clearly correct:
the cycle pre-check gained a height-based fast path (an O(1) *necessary*-
condition check derived directly from I1, skipping the O(reachable
region) search whenever it's provably unneeded — this alone took the same
shape from "doesn't finish" to "finishes, just not linearly"). A further
fix — e.g. not eagerly cascading height bumps through dependents that
haven't been touched yet, deferring their correction to when *they're*
individually evaluated — is architecturally reasonable but wasn't
attempted under this project's time constraints; it would change the
scheduler's height-consistency invariant from "always true" to
"eventually true before it's read," which is a bigger, riskier change to
verify correctly than the time available allowed.

Critically, this is narrow: `test/stress`'s
`test_repeated_bind_switching` shows 200,000 rebinds among a small,
*pre-existing* pool of targets — switching among a fixed set of
alternatives, the far more common real usage of `bind` — with no such
pathology. The problem is specifically about many *new*, previously-
unevaluated bind nodes becoming necessary together in a long dependency
chain, not about `bind` or dynamic dependencies generally.

**Dormant nodes always recompute on revival, even when nothing changed.**
`make_necessary`'s unconditional re-enqueue on the 0->1 necessity
transition (`docs/semantics.md`, "Dormant revival") is a deliberately safe
default — a node that went unnecessary might have stale dependencies
nobody was tracking — but it's conservative even when nothing upstream
actually changed while dormant. A cheaper version would stamp a node's
transitive dependency set at dormancy time and compare on revival,
avoiding the wasted recompute in the common case where nothing changed.
Not implemented; the measured cost of this conservatism is visible in
`test/stress/test_stress.ml`'s bind-switching benchmark, where switching
back to a just-vacated target costs one extra `evaluate_bind` call (a
relay, not a recompute — see the comment there) rather than zero.

**No OCaml 5 / Domains parallelism was executed.** apt's OCaml package on
this build image is 4.14.1; getting OCaml 5.x required building from
source via opam. That build was attempted twice, made real (observable,
logged) progress compiling the runtime each time, and did not finish
within either attempt's time bounds — this sandbox's tool call time
limits, combined with background processes not surviving across separate
tool invocations, made a multi-minute compilation infeasible to complete.
See `docs/complexity.md`, "Parallelism", for what a Domains-based design
would look like and the reasoning for why it's a discussion rather than
measured benchmarks.

**Benchmarking used a hand-rolled harness, not Bechamel or core_bench.**
See `docs/benchmarks.md`, "Methodology".

## `Scheduler`: no side-by-side comparison against a naive scheduler

Stage 4 of the master prompt asks for the simplest correct scheduler
first, then the height-bucket design "if appropriate," benchmarked
against that simpler baseline rather than assumed faster. Given this
project's time constraints, that comparison wasn't built: the
height-bucket scheduler was implemented directly, on the strength of the
RFC's own asymptotic argument (Set-based minimum lookup, O(log k) per pop
— see above), rather than also building and measuring a naive
linear-scan-of-a-dirty-set scheduler as a second data point. This is a
genuine scope reduction, not a finding — unlike every other claim in this
document, "the bucket scheduler is faster than the naive alternative" is
asserted from the asymptotic argument, not measured against a
same-repository baseline.

## `ocamlformat`

Not available via this sandbox's apt-packaged OCaml ecosystem (checked;
not present) and not installable via opam either, for the same reason
opam-based Bechamel/core_bench weren't (`docs/benchmarks.md`,
"Methodology"). Formatting throughout is by hand, kept consistent
(2-space indent, `let%` -free, `;;`-free) but not verified against a
formatter.



Worth stating plainly, since this document is mostly about deviations:
the four-phase pipeline (mutation -> invalidation -> stabilization ->
evaluation), the four-axis state model (liveness / freshness / eval
status / result), the height-ordering invariant and its role in
scheduling, the physical-equality default cutoff, the `value : 'a
observer -> 'a` restriction, the reachability-based verify-then-commit
cycle check, and the differential-testing strategy against a
structurally independent reference evaluator all survived from Stage 0 to
the shipped implementation without modification. The RFC's biggest
structural bets were right; the deviations above are corrections found
by testing it hard, not signs the original design was unsound.
