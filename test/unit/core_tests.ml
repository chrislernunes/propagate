open Propagate

let test_basic_map_chain () =
  let g = Incremental.create () in
  let x = Incremental.var g 10 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v * 2) in
  let z = Incremental.map g y ~f:(fun v -> v + 100) in
  let obs = Incremental.observe g z in
  Incremental.stabilize g;
  Alcotest.(check int) "10*2+100" 120 (Incremental.value obs);
  Incremental.set x 20;
  Incremental.stabilize g;
  Alcotest.(check int) "20*2+100" 140 (Incremental.value obs);
  Incremental.disable obs

let test_repeated_set_single_evaluation () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let calls = ref 0 in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        incr calls;
        v + 1)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 1;
  Incremental.set x 2;
  Incremental.set x 3;
  Alcotest.(check int) "no work before stabilize" 0 !calls;
  Incremental.stabilize g;
  Alcotest.(check int) "y = 3 + 1" 4 (Incremental.value obs);
  Alcotest.(check int) "f called exactly once for 3 sets" 1 !calls;
  Incremental.disable obs

let test_unrelated_subgraph_not_evaluated () =
  let g = Incremental.create () in
  let x1 = Incremental.var g 0 in
  let x2 = Incremental.var g 0 in
  let calls2 = ref 0 in
  let y1 = Incremental.map g (Incremental.watch x1) ~f:(fun v -> v + 1) in
  let y2 =
    Incremental.map g (Incremental.watch x2) ~f:(fun v ->
        incr calls2;
        v + 1)
  in
  let obs1 = Incremental.observe g y1 in
  let obs2 = Incremental.observe g y2 in
  Incremental.stabilize g;
  calls2 := 0;
  Incremental.set x1 999;
  Incremental.stabilize g;
  Alcotest.(check int) "y1 updated" 1000 (Incremental.value obs1);
  Alcotest.(check int) "y2 untouched" 1 (Incremental.value obs2);
  Alcotest.(check int) "y2's f never called" 0 !calls2;
  Incremental.disable obs1;
  Incremental.disable obs2

let test_noop_stabilize_evaluates_nothing () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  let before = (Incremental.Stats.snapshot g).nodes_evaluated in
  Incremental.stabilize g;
  Incremental.stabilize g;
  let after = (Incremental.Stats.snapshot g).nodes_evaluated in
  Alcotest.(check int) "no evaluation on no-op stabilize" 0 (after - before);
  Incremental.disable obs

let test_diamond_shared_dependency_evaluated_once () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let a = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let b = Incremental.map g a ~f:(fun v -> v * 2) in
  let c = Incremental.map g a ~f:(fun v -> v * 3) in
  let d = Incremental.map2 g b c ~f:( + ) in
  let obs = Incremental.observe g d in
  Incremental.stabilize g;
  Alcotest.(check int) "diamond initial" ((1 + 1) * 2 + ((1 + 1) * 3)) (Incremental.value obs);
  let before = (Incremental.Stats.snapshot g).nodes_evaluated in
  Incremental.set x 5;
  Incremental.stabilize g;
  let after = (Incremental.Stats.snapshot g).nodes_evaluated in
  Alcotest.(check int) "diamond updated" ((5 + 1) * 2 + ((5 + 1) * 3)) (Incremental.value obs);
  Alcotest.(check int) "x,a,b,c,d = 5 evaluations, a exactly once" 5 (after - before);
  Incremental.disable obs

let test_height_strictly_increases_along_chain () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let n1 = Incremental.map g (Incremental.watch x) ~f:(fun v -> v) in
  let n2 = Incremental.map g n1 ~f:(fun v -> v) in
  let n3 = Incremental.map g n2 ~f:(fun v -> v) in
  Alcotest.(check bool) "h(watch x) < h(n1)" true (Incremental.Debug.height (Incremental.watch x) < Incremental.Debug.height n1);
  Alcotest.(check bool) "h(n1) < h(n2)" true (Incremental.Debug.height n1 < Incremental.Debug.height n2);
  Alcotest.(check bool) "h(n2) < h(n3)" true (Incremental.Debug.height n2 < Incremental.Debug.height n3)

let test_observer_necessity_lifecycle () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  Alcotest.(check bool) "not necessary before observe" false (Incremental.Debug.is_necessary y);
  let obs = Incremental.observe g y in
  Alcotest.(check bool) "necessary after observe" true (Incremental.Debug.is_necessary y);
  Alcotest.(check bool) "watch x also necessary (transitively)" true (Incremental.Debug.is_necessary (Incremental.watch x));
  Incremental.stabilize g;
  Incremental.disable obs;
  Alcotest.(check bool) "not necessary after disable" false (Incremental.Debug.is_necessary y);
  Alcotest.(check bool) "watch x also unnecessary again" false (Incremental.Debug.is_necessary (Incremental.watch x))

(* A node that goes dormant (disabled) must not silently serve a stale
   cached value once re-observed: its dependencies may have kept
   changing while nobody was tracking it (docs/design.md, "Dormant
   revival"). *)
let test_dormant_revival_recomputes () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v * 10) in
  let obs1 = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check int) "initial" 10 (Incremental.value obs1);
  Incremental.disable obs1;
  (* y is now unnecessary and dormant; x keeps changing *)
  Incremental.set x 2;
  Incremental.set x 3;
  let obs2 = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check int) "reflects the value set while dormant" 30 (Incremental.value obs2);
  Incremental.disable obs2

let test_map2_both_dependencies () =
  let g = Incremental.create () in
  let a = Incremental.var g 3 in
  let b = Incremental.var g 4 in
  let s = Incremental.map2 g (Incremental.watch a) (Incremental.watch b) ~f:( + ) in
  let obs = Incremental.observe g s in
  Incremental.stabilize g;
  Alcotest.(check int) "3+4" 7 (Incremental.value obs);
  Incremental.set a 10;
  Incremental.stabilize g;
  Alcotest.(check int) "10+4" 14 (Incremental.value obs);
  Incremental.set b 1;
  Incremental.stabilize g;
  Alcotest.(check int) "10+1" 11 (Incremental.value obs);
  Incremental.disable obs

let test_physically_equal_set_is_noop () =
  let g = Incremental.create () in
  let x = Incremental.var g 42 in
  let calls = ref 0 in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        incr calls;
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 42 (* immediate ints: physically equal to the current value *);
  Incremental.stabilize g;
  Alcotest.(check int) "set to == value does not invalidate" 0 !calls;
  Incremental.disable obs

let tests =
  [
    Alcotest.test_case "basic map chain" `Quick test_basic_map_chain;
    Alcotest.test_case "repeated set before stabilize: single evaluation" `Quick test_repeated_set_single_evaluation;
    Alcotest.test_case "unrelated subgraph not evaluated" `Quick test_unrelated_subgraph_not_evaluated;
    Alcotest.test_case "no-op stabilize evaluates nothing" `Quick test_noop_stabilize_evaluates_nothing;
    Alcotest.test_case "diamond: shared dependency evaluated once" `Quick test_diamond_shared_dependency_evaluated_once;
    Alcotest.test_case "height strictly increases along a chain" `Quick test_height_strictly_increases_along_chain;
    Alcotest.test_case "observer necessity lifecycle" `Quick test_observer_necessity_lifecycle;
    Alcotest.test_case "dormant revival recomputes, doesn't serve stale cache" `Quick test_dormant_revival_recomputes;
    Alcotest.test_case "map2 reacts to both dependencies" `Quick test_map2_both_dependencies;
    Alcotest.test_case "set to physically-equal value is a no-op" `Quick test_physically_equal_set_is_noop;
  ]
