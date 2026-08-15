open Propagate

let test_set_during_stabilize_rejected () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y2 = Incremental.var g 2 in
  let caught = ref false in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try Incremental.set y2 v with Incremental.Reentrant_call _ -> caught := true);
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check bool) "set() mid-stabilize was rejected" true !caught;
  Alcotest.(check int) "y computed normally despite the illegal set being caught inside f" 1 (Incremental.value obs);
  Incremental.disable obs

let test_stabilize_during_stabilize_rejected () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let caught = ref false in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try Incremental.stabilize g with Incremental.Reentrant_call _ -> caught := true);
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check bool) "nested stabilize() was rejected" true !caught;
  Incremental.disable obs

let test_value_during_stabilize_rejected () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let leaf = Incremental.map g (Incremental.watch x) ~f:(fun v -> v) in
  let leaf_obs = Incremental.observe g leaf in
  let caught = ref false in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try ignore (Incremental.value leaf_obs) with Incremental.Reentrant_call _ -> caught := true);
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check bool) "value() on an unrelated observer was rejected mid-stabilize" true !caught;
  Incremental.disable obs;
  Incremental.disable leaf_obs

let test_observe_during_stabilize_rejected () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let other = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let caught = ref false in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try ignore (Incremental.observe g other) with Incremental.Reentrant_call _ -> caught := true);
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check bool) "observe() mid-stabilize was rejected" true !caught;
  Incremental.disable obs

let test_disable_during_stabilize_rejected () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let other = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let other_obs = Incremental.observe g other in
  let caught = ref false in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try Incremental.disable other_obs with Incremental.Reentrant_call _ -> caught := true);
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check bool) "disable() mid-stabilize was rejected" true !caught;
  Alcotest.(check bool) "the observer being disabled was left untouched (still necessary)" true
    (Incremental.Debug.is_necessary other);
  Incremental.disable obs;
  Incremental.disable other_obs

(* Constructing new nodes mid-stabilize, from inside bind's f, is
   deliberately *not* rejected — it's bind's entire mechanism. This is
   the positive counterpart to the tests above. *)
let test_construction_during_stabilize_is_allowed () =
  let g = Incremental.create () in
  let sel = Incremental.var g 1 in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun v ->
        let fresh = Incremental.var g v in
        Incremental.map g (Incremental.watch fresh) ~f:(fun x -> x * 10))
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Alcotest.(check int) "bind's f constructing new nodes works" 10 (Incremental.value obs);
  Incremental.disable obs

let test_runtime_not_bricked_after_reentrant_call () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y =
    Incremental.map g (Incremental.watch x) ~f:(fun v ->
        (try Incremental.stabilize g with Incremental.Reentrant_call _ -> ());
        v)
  in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  (* stabilizing flag must have been reset even though an exception
     was raised and caught *from inside* the pass — confirm the
     runtime is fully usable afterward, including a plain call from
     outside any callback. *)
  Alcotest.(check bool) "not stuck thinking it's still stabilizing" false (Incremental.Debug.is_stabilizing g);
  Incremental.set x 5;
  Incremental.stabilize g;
  Alcotest.(check int) "ordinary use after a caught reentrant call still works" 5 (Incremental.value obs);
  Incremental.disable obs

let tests =
  [
    Alcotest.test_case "set() during stabilize is rejected" `Quick test_set_during_stabilize_rejected;
    Alcotest.test_case "stabilize() during stabilize is rejected" `Quick test_stabilize_during_stabilize_rejected;
    Alcotest.test_case "value() during stabilize is rejected" `Quick test_value_during_stabilize_rejected;
    Alcotest.test_case "observe() during stabilize is rejected" `Quick test_observe_during_stabilize_rejected;
    Alcotest.test_case "disable() during stabilize is rejected" `Quick test_disable_during_stabilize_rejected;
    Alcotest.test_case "constructing new nodes during stabilize (bind's f) is allowed" `Quick
      test_construction_during_stabilize_is_allowed;
    Alcotest.test_case "runtime is not bricked after a caught reentrant call" `Quick
      test_runtime_not_bricked_after_reentrant_call;
  ]
