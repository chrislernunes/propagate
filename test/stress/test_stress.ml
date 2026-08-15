(* Stage 14. Every number printed here is measured on this run, not
   asserted as a promise about performance elsewhere — see
   docs/benchmarks.md for the actual benchmark suite and methodology.
   This file's job is narrower: confirm the implementation doesn't
   fall over (stack overflow, unbounded memory, pathological slowdown)
   at sizes an order of magnitude past what the unit/property/
   differential suites exercise, and record what "falling over" looks
   like where it genuinely does. *)

open Propagate

let time_it label f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  Printf.printf "  %-60s %8.3fs\n%!" label (t1 -. t0);
  r

let log2_floor n =
  let rec go n acc = if n <= 1 then acc else go (n / 2) (acc + 1) in
  go n 0

(* Benchmark-A shape, at 1,000,000 nodes: a single input at the root
   of a million-deep chain of maps. This is specifically what would
   stack-overflow if invalidation, height fixup, or necessity
   propagation used native recursion instead of an explicit worklist —
   which is exactly how test/stress found the necessity-propagation
   bug documented in docs/design.md, "Implementation deviations": the
   unit/property/differential suites all passed, then this segfaulted
   on a native `let rec` cascade the first time it ran at real depth. *)
let test_million_node_chain () =
  Printf.printf "\n[chain, 1,000,000 nodes]\n%!";
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let leaf =
    time_it "build" (fun () ->
        let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(fun v -> v + 1)) in
        chain 1_000_000 (Incremental.watch x))
  in
  let obs = time_it "observe (necessity cascade, 1M deep)" (fun () -> Incremental.observe g leaf) in
  time_it "first stabilize" (fun () -> Incremental.stabilize g);
  Alcotest.(check int) "value after first stabilize" 1_000_000 (Incremental.value obs);
  time_it "10 further set+stabilize cycles" (fun () ->
      for i = 1 to 10 do
        Incremental.set x i;
        Incremental.stabilize g
      done);
  Alcotest.(check int) "value after 10 more updates" 1_000_010 (Incremental.value obs);
  let stats = Incremental.Stats.snapshot g in
  Printf.printf "  nodes_created=%d nodes_evaluated=%d max_height_seen=%d\n%!" stats.nodes_created stats.nodes_evaluated
    stats.max_height_seen;
  time_it "disable (necessity cascade back down, 1M deep)" (fun () -> Incremental.disable obs)

(* Benchmark-B shape, at 300,000 branches: one input feeding a very
   wide fan-out. *)
let test_wide_graph () =
  Printf.printf "\n[wide, 300,000 independent branches of 1 input]\n%!";
  let g = Incremental.create () in
  let width = 300_000 in
  let x = Incremental.var g 1 in
  let branches =
    time_it "build" (fun () -> Array.init width (fun i -> Incremental.map g (Incremental.watch x) ~f:(fun v -> v + i)))
  in
  let obs =
    time_it "observe all + first stabilize" (fun () ->
        let obs = Array.map (Incremental.observe g) branches in
        Incremental.stabilize g;
        obs)
  in
  Alcotest.(check int) "branches.(0)" 1 (Incremental.value obs.(0));
  Alcotest.(check int) "branches.(width-1)" (1 + width - 1) (Incremental.value obs.(width - 1));
  time_it "1 set + stabilize (touches all 300,000)" (fun () ->
      Incremental.set x 100;
      Incremental.stabilize g);
  Alcotest.(check int) "branches.(0) after update" 100 (Incremental.value obs.(0));
  Array.iter Incremental.disable obs

(* A large DAG with real sharing: a layered binary fan-in structure
   (each layer half the width of the one below, each node combining
   two from the previous layer), 18 layers deep from a base of
   262,144 leaves down to 1 root — deliberately structured so that
   without correct sharing, a naive re-evaluation would be
   exponential. *)
let test_large_shared_dag () =
  Printf.printf "\n[shared DAG, 18 layers, 262,144 leaves]\n%!";
  let g = Incremental.create () in
  let base_width = 1 lsl 18 in
  let inputs = Array.init base_width (fun i -> Incremental.var g i) in
  let root =
    time_it "build" (fun () ->
        let layer = ref (Array.map Incremental.watch inputs) in
        while Array.length !layer > 1 do
          let w = Array.length !layer in
          let prev = !layer in
          layer := Array.init (w / 2) (fun i -> Incremental.map2 g prev.(2 * i) prev.((2 * i) + 1) ~f:( + ))
        done;
        !layer.(0))
  in
  let obs =
    time_it "observe + first stabilize" (fun () ->
        let obs = Incremental.observe g root in
        Incremental.stabilize g;
        obs)
  in
  let expected_sum = Array.fold_left ( + ) 0 (Array.init base_width (fun i -> i)) in
  Alcotest.(check int) "sum of all leaves" expected_sum (Incremental.value obs);
  let evaluated_before = (Incremental.Stats.snapshot g).nodes_evaluated in
  time_it "sparse update: change 1 of 262,144 leaves" (fun () ->
      Incremental.set inputs.(0) 1_000_000;
      Incremental.stabilize g);
  let evaluated_after = (Incremental.Stats.snapshot g).nodes_evaluated in
  Alcotest.(check int) "sum reflects the sparse update" (expected_sum + 1_000_000) (Incremental.value obs);
  Printf.printf "  sparse update evaluated %d nodes (expect exactly %d: 1 leaf + 1 per layer up to the root)\n%!"
    (evaluated_after - evaluated_before) (log2_floor base_width + 1);
  Incremental.disable obs

(* Repeated updates: 50,000 sequential set+stabilize cycles against a
   moderately-sized graph, confirming per-cycle cost stays roughly
   constant rather than drifting upward (which would indicate some
   form of accumulating state — a throughput-focused companion to the
   memory tests in test/unit). *)
let test_repeated_updates () =
  Printf.printf "\n[50,000 repeated updates against a 500-node graph]\n%!";
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let leaf =
    let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(fun v -> v + 1)) in
    chain 500 (Incremental.watch x)
  in
  let obs = Incremental.observe g leaf in
  Incremental.stabilize g;
  time_it "updates 1..25,000" (fun () ->
      for i = 1 to 25_000 do
        Incremental.set x i;
        Incremental.stabilize g
      done);
  time_it "updates 25,001..50,000 (compare to the block above)" (fun () ->
      for i = 25_001 to 50_000 do
        Incremental.set x i;
        Incremental.stabilize g
      done);
  Alcotest.(check int) "final value" (50_000 + 500) (Incremental.value obs);
  Incremental.disable obs

(* Repeated bind switching at scale: 200,000 rebinds between two
   pre-existing targets — the common, realistic bind-usage pattern
   (switch among a small fixed set of alternatives), as opposed to the
   pathological one documented below.

   Note on the printed counters: both bind_recomputations AND
   bind_relays end up around 200,000 here, not just the former. Each
   switch evaluates dyn *twice* in the same pass: once via the
   lhs-changed path (rebind attaches the new target), and once more
   via the lhs-unchanged/relay path, because attaching a target that
   was dormant (unnecessary) since the *previous* switch triggers
   make_necessary's unconditional re-verification of newly-necessary
   nodes (docs/design.md, "Dormant revival") — dyn can't finalize
   immediately in rebind, since the newly-attached target's freshness
   isn't confirmed yet, so it waits and gets re-popped once the target
   settles. The target's value never actually changes (cutoff
   correctly suppresses further propagation from it), so the end
   result is correct, just two evaluate_bind calls instead of one for
   this specific shape (switching back to a target that went dormant
   in between). This is a measured, minor performance characteristic,
   not a correctness issue — every value assertion below still holds. *)
let test_repeated_bind_switching () =
  Printf.printf "\n[200,000 repeated bind switches between 2 existing targets]\n%!";
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let a = Incremental.var g 1 in
  let b = Incremental.var g 2 in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun i -> if i mod 2 = 0 then Incremental.watch a else Incremental.watch b)
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  time_it "200,000 switches" (fun () ->
      for i = 1 to 200_000 do
        Incremental.set sel i;
        Incremental.stabilize g
      done);
  Alcotest.(check int) "final value" 1 (Incremental.value obs);
  let stats = Incremental.Stats.snapshot g in
  Printf.printf
    "  bind_recomputations=%d bind_relays=%d\n%!"
    stats.bind_recomputations stats.bind_relays;
  Printf.printf
    "  (both are ~200,000, not just recomputations — see comment above test_repeated_bind_switching)\n%!";
  Incremental.disable obs

(* KNOWN LIMITATION, measured and documented rather than hidden (see
   docs/design.md, "Known limitations", and docs/benchmarks.md): a
   long chain of *distinct, sequentially-dependent* bind nodes that
   all become necessary at once (e.g. via a single observe() on the
   far end) pays a quadratic-ish cost. Root cause: rebind's
   height-fixup rule bumps a fresh rhs's height to (scheduler cursor +
   1), and that bump must cascade forward through every existing
   dependent to preserve I1 — and in this specific shape, the entire
   remaining chain already exists as live scheduled nodes by the time
   the first bind in the chain is evaluated, so each rebind's cascade
   walks most of what's left. Measured during development: depth 6,000
   took several seconds and scaled worse than linearly with depth.
   Contrast with test_repeated_bind_switching above: switching among a
   small fixed set of pre-existing targets — the far more common real
   usage of bind — shows no such pathology even at 200,000 operations.
   This is deliberately run at a modest, verified-fast depth rather
   than skipped, so the limitation has a passing, timed regression
   test attached to it rather than just a paragraph of prose. *)
let test_deep_bind_chain_known_limitation () =
  Printf.printf "\n[KNOWN LIMITATION: chain of 3,000 distinct sequential binds]\n%!";
  let g = Incremental.create () in
  let base = Incremental.var g 1 in
  let leaf =
    let rec go k t =
      if k = 0 then t else go (k - 1) (Incremental.bind g t ~f:(fun v -> Incremental.watch (Incremental.var g (v + 1))))
    in
    go 3_000 (Incremental.watch base)
  in
  let obs = Incremental.observe g leaf in
  time_it "first stabilize (quadratic-ish height-fixup cascade — see comment above)" (fun () -> Incremental.stabilize g);
  Alcotest.(check int) "value" 3_001 (Incremental.value obs);
  Incremental.disable obs

let tests =
  [
    Alcotest.test_case "1,000,000-node chain: no stack overflow, correct value" `Slow test_million_node_chain;
    Alcotest.test_case "300,000-branch wide graph" `Slow test_wide_graph;
    Alcotest.test_case "large shared DAG (262,144 leaves, real sharing)" `Slow test_large_shared_dag;
    Alcotest.test_case "50,000 repeated updates" `Slow test_repeated_updates;
    Alcotest.test_case "200,000 repeated bind switches (fixed target set)" `Slow test_repeated_bind_switching;
    Alcotest.test_case "known limitation: 3,000-deep chain of distinct binds" `Slow test_deep_bind_chain_known_limitation;
  ]

let () = Alcotest.run "stress" [ "stress", tests ]
