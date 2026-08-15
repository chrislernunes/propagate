open Propagate

exception My_error of string

let test_map_exception_reraised_on_value () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> if v = 0 then raise (My_error "boom") else v) in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  (try
     let (_ : int) = Incremental.value obs in
     Alcotest.fail "expected My_error to be raised"
   with
  | My_error "boom" -> ()
  | e -> Alcotest.failf "wrong exception: %s" (Printexc.to_string e));
  Incremental.disable obs

let test_dependent_short_circuits_without_calling_f () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let downstream_calls = ref 0 in
  let failing = Incremental.map g (Incremental.watch x) ~f:(fun v -> if v = 0 then raise (My_error "boom") else v) in
  let downstream =
    Incremental.map g failing ~f:(fun v ->
        incr downstream_calls;
        v + 1)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  Alcotest.(check int) "downstream's f never called" 0 !downstream_calls;
  (try
     let (_ : int) = Incremental.value obs in
     Alcotest.fail "expected re-raise"
   with My_error _ -> ());
  Incremental.disable obs

let test_recovery_after_fixing_input () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> 100 / v) in
  let obs = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.check_raises "division by zero" Division_by_zero (fun () -> ignore (Incremental.value obs));
  Incremental.set x 4;
  Incremental.stabilize g;
  Alcotest.(check int) "recovered" 25 (Incremental.value obs);
  Incremental.disable obs

let test_exception_in_map2 () =
  let g = Incremental.create () in
  let a = Incremental.var g 1 in
  let b = Incremental.var g 0 in
  let s = Incremental.map2 g (Incremental.watch a) (Incremental.watch b) ~f:(fun a b -> a / b) in
  let obs = Incremental.observe g s in
  Incremental.stabilize g;
  Alcotest.check_raises "map2 div by zero" Division_by_zero (fun () -> ignore (Incremental.value obs));
  Incremental.set b 5;
  Incremental.stabilize g;
  Alcotest.(check int) "map2 recovered" 0 (Incremental.value obs);
  Incremental.disable obs

let test_exception_in_bind_f_itself () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun v ->
        if v = 0 then raise (My_error "bind boom") else Incremental.watch (Incremental.var g v))
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Alcotest.check_raises "bind f raises" (My_error "bind boom") (fun () -> ignore (Incremental.value obs));
  Incremental.set sel 7;
  Incremental.stabilize g;
  Alcotest.(check int) "bind recovered" 7 (Incremental.value obs);
  Incremental.disable obs

let test_nested_chain_failure_propagates () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let a = Incremental.map g (Incremental.watch x) ~f:(fun v -> 100 / v) in
  let b = Incremental.map g a ~f:(fun v -> v + 1) in
  let c = Incremental.map g b ~f:(fun v -> v * 2) in
  let obs = Incremental.observe g c in
  Incremental.stabilize g;
  Alcotest.check_raises "propagates through 2 hops" Division_by_zero (fun () -> ignore (Incremental.value obs));
  Incremental.disable obs

(* No node may be left stuck in Computing after a failing stabilize —
   checked via the invariant checker's status_sanity rule, which is
   exactly the mechanical form of that requirement. *)
let test_no_node_stuck_computing_after_exception () =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> 1 / v) in
  let z = Incremental.map g y ~f:(fun v -> v + 1) in
  let obs = Incremental.observe g z in
  Incremental.stabilize g;
  (try Incremental.stabilize g with _ -> ());
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack z ];
  Incremental.disable obs

let test_stabilize_retriable_after_exception () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let y = Incremental.var g 0 in
  let s = Incremental.map2 g (Incremental.watch x) (Incremental.watch y) ~f:(fun a b -> a / b) in
  let obs = Incremental.observe g s in
  (* y is 0 from the start, so the very first stabilize fails *)
  Alcotest.check_raises "first stabilize's node fails" Division_by_zero (fun () ->
      Incremental.stabilize g;
      ignore (Incremental.value obs));
  (* runtime must still be usable *)
  Incremental.set y 1;
  Incremental.stabilize g;
  Alcotest.(check int) "usable after fixing" 1 (Incremental.value obs);
  Incremental.disable obs

let tests =
  [
    Alcotest.test_case "map exception re-raised by value" `Quick test_map_exception_reraised_on_value;
    Alcotest.test_case "dependent short-circuits without calling its own f" `Quick
      test_dependent_short_circuits_without_calling_f;
    Alcotest.test_case "recovery after fixing the failing input" `Quick test_recovery_after_fixing_input;
    Alcotest.test_case "exception in map2" `Quick test_exception_in_map2;
    Alcotest.test_case "exception in bind's f itself" `Quick test_exception_in_bind_f_itself;
    Alcotest.test_case "failure propagates through a 2-hop chain" `Quick test_nested_chain_failure_propagates;
    Alcotest.test_case "no node stuck in Computing after an exception" `Quick
      test_no_node_stuck_computing_after_exception;
    Alcotest.test_case "stabilize is retriable after a failure" `Quick test_stabilize_retriable_after_exception;
  ]
