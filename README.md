# Propagate

An incremental computation runtime in OCaml.

Represent a computation as a dependency graph. When an input changes,
only the parts of the graph that are actually affected, and that
someone is actually watching get recomputed.

```text
        A
       / \
      B   C
       \ /
        D
```

Each node depends on the nodes above it. When `A` changes:

```text
A changes
   |
   v
B and C become stale (marked, not yet recomputed)
   |
   v
when stabilize() runs, B and C are recomputed
   |
   v
D becomes stale only once B or C's *value* actually changes,
   and is recomputed in turn
   |
   v
anything unrelated to A is never touched
```

Invalidation and recomputation are different things, on purpose: `set`
just marks the affected region stale; nothing is recomputed until
`stabilize()` runs, and even then a node whose recomputed value turns out
to equal its old one (see "Cutoff" below) doesn't propagate the
invalidation any further.

## Minimal example

```ocaml
let g = Incremental.create () in
let x = Incremental.var g 10 in
let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v * 2) in
let obs = Incremental.observe g y in
Incremental.stabilize g;
Incremental.value obs (* 20 *)

Incremental.set x 21;
Incremental.stabilize g;
Incremental.value obs (* 42 *)
```

`bind` adds dependencies that change shape at runtime:

```ocaml
let selector = Incremental.var g 0 in
let branches = Array.init 5 (fun i -> Incremental.var g (i * 10)) in
let dyn =
  Incremental.bind g (Incremental.watch selector) ~f:(fun i ->
      Incremental.watch branches.(i))
in
(* dyn now tracks branches.(0). Change the selector, and it starts
   tracking a different node entirely -- the dependency graph itself
   changes shape, not just the values flowing through it. *)
```

More in `examples/basic.ml`.

## Core concepts

- **`var` / `watch`** -- a mutable input cell, and the read-only handle
  used to depend on it.
- **`map` / `map2`** -- derive a new computation from one or two others.
- **`bind`** -- derive a computation whose *dependency structure itself*
  depends on a value, re-evaluated dynamically.
- **`cutoff`** -- suppress propagation when a recomputed value is
  equivalent to the old one under a caller-supplied equality (every node
  already does this with physical equality by default -- see
  `docs/semantics.md`).
- **`observe` / `disable`** -- mark a computation as actually needed (only
  necessary, observed computations get scheduled) and stop watching it.
- **`stabilize`** -- recompute everything stale and necessary, in an order
  that never reads a stale dependency.

Full semantics, including exactly when `bind` re-runs its function versus
just relays a value, how exceptions propagate, and why the default
cutoff is physical equality rather than structural equality: see
`docs/semantics.md`.

## Testing

```
dune test
```

runs the unit (`test/unit`), invariant (`test/invariant`), and
differential (`test/differential`) suites (fast -- well under a second
combined). Property tests (`test/property`, ~3,500 QCheck2-generated
cases across two suites) and stress tests (`test/stress`, up to
1,000,000-node graphs) are excluded from the default `dune test` run
because of their runtime, and are run explicitly:

```
dune exec test/property/test_property.exe
dune exec test/stress/test_stress.exe
```

Differential testing compares this engine against `lib/reference.ml`, a
structurally independent full-recomputation evaluator that shares no
code, cache, or scheduler with the real implementation, after every
`stabilize()` in both the differential and property suites. Property
testing (QCheck2, with shrinking) generates random sequences of graph
operations -- including dynamic `bind` switching -- and checks both
differential agreement and a set of mechanically-checked graph invariants
(dependency height ordering, necessity-count consistency, acyclicity,
dependents-list reciprocity) after every mutating operation. It's how
the bind/dependents-list bug in `docs/design.md` was actually found:
QCheck2 generated the exact adversarial shape (a bind whose dynamic pool
includes its own input) and shrank a much longer failing sequence down to
a minimal repro in seconds.

## Benchmarks

```
dune exec benchmark/chains.exe
dune exec benchmark/wide.exe
dune exec benchmark/deep.exe
dune exec benchmark/shared.exe
dune exec benchmark/sparse.exe
dune exec benchmark/dense.exe
dune exec benchmark/dynamic.exe
dune exec benchmark/financial.exe
dune exec benchmark/crossover.exe
```

