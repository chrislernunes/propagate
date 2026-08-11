# Propagate

An incremental computation runtime written in OCaml 5.
Propagate maintains a dependency graph of computations and recomputes only the parts of the graph affected by a change.

```text
        A
       / \
      B   C
       \ /
        D
```

When `A` changes:

```text
A changes
   │
   ├──→ B becomes stale
   │
   ├──→ C becomes stale
   │
   └──→ D becomes stale
          │
          ▼
    affected nodes
      recompute
```

Unrelated computations are left untouched.

## Example

```ocaml
module I = Propagate.Make ()

let x = I.var 10

let y =
  I.map (I.watch x) ~f:(fun x ->
    x * 2)

let obs = I.observe y

I.stabilize ()

let v = I.value obs
(* 20 *)

I.set x 21;
I.stabilize ()

let v = I.value obs
(* 42 *)
```

## Core

Propagate implements:

* Mutable input variables
* Dependency tracking
* Incremental invalidation
* Necessity propagation
* Deterministic stabilization
* Height-based scheduling
* Dynamic dependencies through `bind`
* Cycle detection
* Exception propagation
* Cutoff-based propagation suppression
* Observer lifecycle management

The implementation separates:

```text
Node
  ↓
Graph
  ↓
Scheduler
  ↓
Incremental API
```

A separate reference evaluator provides an independent full-recomputation implementation for differential testing.

## Correctness

Correctness is treated as a first-class property rather than inferred from unit tests.

The test suite includes:

* Unit tests
* Property-based tests with QCheck2
* Differential testing against the reference evaluator
* Runtime invariant checking
* Deep and wide graph stress tests
* Dynamic dependency tests
* Exception and recovery tests
* Memory/lifetime tests

The runtime checks invariants including dependency height ordering, scheduler membership, necessity propagation, acyclicity, and post-stabilization consistency.

## Performance

The benchmark suite evaluates:

* Chains
* Wide graphs
* Deep graphs
* Shared DAGs
* Sparse updates
* Dense updates
* Dynamic dependencies
* Financial-shaped dependency graphs

Incremental computation is also compared against a fair full-recomputation baseline that preserves DAG sharing.

The goal is not to assume that incremental computation is always faster, but to measure where the crossover occurs as the fraction of affected nodes and computation cost change.

## License

MIT
