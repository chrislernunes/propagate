(* Distinct from test/unit (targeted single-behavior checks) and
   test/property (black-box random exploration): this file checks each
   named invariant explicitly via Debug introspection, so a reader can
   see exactly what each one means and watch it hold (or, in one case,
   watch the checker have actually caught a violation during
   development). *)

open Propagate

(* I1: height(dependency) < height(dependent), everywhere, including
   after a bind rebind's height-fixup rule runs. *)
let test_i1_height_ordering () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let a = Incremental.map g (Incremental.watch x) ~f:(fun v -> v) in
  let b = Incremental.map g a ~f:(fun v -> v) in
  let c = Incremental.map2 g a b ~f:( + ) in
  Alcotest.(check bool) "h(watch x) < h(a)" true (Incremental.Debug.height (Incremental.watch x) < Incremental.Debug.height a);
  Alcotest.(check bool) "h(a) < h(b)" true (Incremental.Debug.height a < Incremental.Debug.height b);
  Alcotest.(check bool) "h(a) < h(c), h(b) < h(c)" true
    (Incremental.Debug.height a < Incremental.Debug.height c && Incremental.Debug.height b < Incremental.Debug.height c);
  (* now force a bind rebind mid-stabilize, onto a target deeper than
     the rebinding node's current structural height, and confirm I1
     still holds afterward via the full checker *)
  let sel = Incremental.var g 0 in
  let deep = c in
  let dyn = Incremental.bind g (Incremental.watch sel) ~f:(fun i -> if i = 0 then Incremental.watch x else deep) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Incremental.set sel 1;
  Incremental.stabilize g;
  Alcotest.(check bool) "h(dyn) > h(deep) after rebinding onto a deeper node" true
    (Incremental.Debug.height dyn > Incremental.Debug.height deep);
  Incremental.Debug.assert_invariants
    [ Incremental.Debug.pack c; Incremental.Debug.pack dyn; Incremental.Debug.pack (Incremental.watch x) ];
  Incremental.disable obs

(* I3: necessary_count = observer_count + count of necessary
   dependents, tracked by hand across a lifecycle with two independent
   observers sharing a common ancestor. *)
let test_i3_necessity_count () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let a = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let b1 = Incremental.map g a ~f:(fun v -> v * 2) in
  let b2 = Incremental.map g a ~f:(fun v -> v * 3) in
  Alcotest.(check int) "a: necessary_count 0 before any observer" 0 (Incremental.Debug.necessary_count a);
  let obs1 = Incremental.observe g b1 in
  Alcotest.(check int) "a: necessary_count 1 with one necessary dependent (b1)" 1 (Incremental.Debug.necessary_count a);
  let obs2 = Incremental.observe g b2 in
  Alcotest.(check int) "a: necessary_count 2 with two necessary dependents (b1, b2)" 2 (Incremental.Debug.necessary_count a);
  Incremental.stabilize g;
  Incremental.disable obs1;
  Alcotest.(check int) "a: back to 1 after disabling one observer's chain" 1 (Incremental.Debug.necessary_count a);
  Incremental.disable obs2;
  Alcotest.(check int) "a: back to 0 after disabling both" 0 (Incremental.Debug.necessary_count a);
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack b1; Incremental.Debug.pack b2 ]

(* I4: an unnecessary node is never stale, no matter what its
   dependencies do. *)
let test_i4_only_necessary_scheduled () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  Alcotest.(check bool) "not necessary, so also never stale (nothing to become stale into)" false
    (Incremental.Debug.is_stale y);
  Incremental.set x 1;
  Incremental.set x 2;
  Alcotest.(check bool) "still not stale: y was never made necessary" false (Incremental.Debug.is_stale y);
  Alcotest.(check bool) "and not necessary either" false (Incremental.Debug.is_necessary y)

(* I7 (acyclicity), as a regression check: the graph remains acyclic
   (per the full checker) after a rejected cycle attempt. *)
let test_i7_acyclicity_after_rejected_cycle () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let self = ref None in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun v ->
        if v = 0 then Incremental.watch (Incremental.var g 0)
        else match !self with Some s -> s | None -> Incremental.watch (Incremental.var g 0))
  in
  self := Some dyn;
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Incremental.set sel 1;
  Incremental.stabilize g;
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack dyn ];
  Incremental.disable obs

(* Regression case: this exact shape (a bind whose dynamic pool
   happens to include its own lhs node) is what property testing
   (test/property) actually found broken during development — the
   dependents list ended up with two entries for the same edge (one
   from the permanent lhs edge, one from the dynamic rhs edge), and
   the old blanket "remove all matching entries" detach logic deleted
   both when the rhs edge was later torn down, corrupting the
   permanent lhs edge's reciprocal entry. See lib/graph.ml,
   remove_dependent's comment, and docs/design.md, "Implementation
   deviations". Kept here as an explicit, minimal, named repro rather
   than only living inside a shrunk QCheck2 counterexample. *)
let test_regression_bind_pool_includes_own_lhs () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let sel_t = Incremental.watch sel in
  let other = Incremental.var g 100 in
  (* pool = [watch sel; watch other] at construction time — index 0 IS
     the bind's own lhs *)
  let dyn = Incremental.bind g sel_t ~f:(fun i -> if i mod 2 = 0 then sel_t else Incremental.watch other) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Alcotest.(check int) "initial: routes to itself (sel_t), value 0" 0 (Incremental.value obs);
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack dyn; Incremental.Debug.pack sel_t ];
  Incremental.set sel 1;
  Incremental.stabilize g;
  Alcotest.(check int) "switched to other" 100 (Incremental.value obs);
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack dyn; Incremental.Debug.pack sel_t ];
  Incremental.set sel 2;
  Incremental.stabilize g;
  (* back to routing through sel_t itself — the permanent lhs edge
     must still be intact for this to even be observable correctly *)
  Alcotest.(check int) "back to self-routing" 2 (Incremental.value obs);
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack dyn; Incremental.Debug.pack sel_t ];
  Incremental.disable obs

(* A larger, systematically (not randomly) constructed layered DAG:
   10 layers of 8 nodes each, each node map2-combining two nodes from
   the previous layer, exercised through several rounds of input
   changes and one bind rebind, checking the full invariant set after
   every round. Bigger and more structurally regular than the unit
   tests, simpler to reason about by hand than the property tests'
   fully random model. *)
let test_layered_dag () =
  let g = Incremental.create () in
  let width = 8 and depth = 10 in
  let inputs = Array.init width (fun i -> Incremental.var g i) in
  let layer0 = Array.map (fun v -> Incremental.watch v) inputs in
  let layers = Array.make depth layer0 in
  for l = 1 to depth - 1 do
    let prev = layers.(l - 1) in
    layers.(l) <-
      Array.init width (fun i ->
          Incremental.map2 g prev.(i) prev.((i + 1) mod width) ~f:(fun a b -> (a + b + l) mod 1009))
  done;
  let last = layers.(depth - 1) in
  let observers = Array.map (Incremental.observe g) last in
  let roots = ref (Array.to_list (Array.map Incremental.Debug.pack last)) in
  Incremental.stabilize g;
  Incremental.Debug.assert_invariants !roots;
  for round = 0 to 4 do
    Incremental.set inputs.(round mod width) (round * 7);
    Incremental.set inputs.((round + 3) mod width) (round * 13);
    Incremental.stabilize g;
    Incremental.Debug.assert_invariants !roots
  done;
  (* one dynamic wrinkle: bind an extra node that switches between two
     mid-layer nodes, folded into the root set for checking *)
  let sel = Incremental.var g 0 in
  let dyn = Incremental.bind g (Incremental.watch sel) ~f:(fun i -> if i = 0 then layers.(3).(0) else layers.(6).(4)) in
  let dyn_obs = Incremental.observe g dyn in
  roots := Incremental.Debug.pack dyn :: !roots;
  Incremental.stabilize g;
  Incremental.Debug.assert_invariants !roots;
  Incremental.set sel 1;
  Incremental.stabilize g;
  Incremental.Debug.assert_invariants !roots;
  Array.iter Incremental.disable observers;
  Incremental.disable dyn_obs

let tests =
  [
    Alcotest.test_case "I1: height ordering, including after a bind height-fixup" `Quick test_i1_height_ordering;
    Alcotest.test_case "I3: necessity count, hand-checked across a shared-observer lifecycle" `Quick
      test_i3_necessity_count;
    Alcotest.test_case "I4: unnecessary nodes are never stale" `Quick test_i4_only_necessary_scheduled;
    Alcotest.test_case "I7: acyclicity holds after a rejected cycle" `Quick test_i7_acyclicity_after_rejected_cycle;
    Alcotest.test_case "regression: bind pool includes its own lhs" `Quick test_regression_bind_pool_includes_own_lhs;
    Alcotest.test_case "layered DAG (10x8), checked every round" `Quick test_layered_dag;
  ]

let () = Alcotest.run "invariant" [ "invariants", tests ]
