An incremental computation runtime written in OCaml. 
The project explores how to implement this efficiently and correctly from first principles.

Propagate maintains a graph of dependent computations and recomputes only the parts affected when an input changes. 


```text
        A
       / \
      B   C
       \ /
        D
```

If `A` changes, Propagate invalidates and recomputes `B`, `C`, and `D` without unnecessarily evaluating unrelated computations.

## Example

```ocaml
let x = Propagate.var 10.0

let y =
  Propagate.map x ~f:(fun x ->
    x *. 2.0)

let z =
  Propagate.map y ~f:(fun y ->
    y +. 100.0)

Propagate.stabilize ();

Propagate.set x 20.0;
Propagate.stabilize ();

Propagate.value z
```

The runtime tracks the dependency graph automatically.

## Core Ideas

- Dependency tracking
- Invalidation
- Incremental recomputation
- Memoization
- Dependency-aware scheduling
- Dynamic dependencies
- Cycle detection
- Deterministic stabilization

## Correctness

Propagate will include a simple full-recomputation reference implementation.
The incremental runtime will be tested against it using generated graphs and update sequences.

```text
Incremental result == Full recomputation result
```

## Performance

Benchmarks will compare incremental recomputation against full recomputation across different graph structures and affected-subgraph sizes.
The goal is not to assume incremental computation is always faster, but to determine **when it actually is**.

## Status

Early development.

## License

MIT
