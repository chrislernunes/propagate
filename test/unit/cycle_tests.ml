open Propagate

(* Design note: a rejected cycle is surfaced exactly like any other
   exception a bind's [f] can raise — as a per-node [Failed] outcome,
   discovered when [value] is called, not as an exception escaping
   [stabilize]. rebind's cycle check runs strictly before any mutation
   (verify-then-commit), so this is safe, and it means one bind
   rejecting a cycle does not abort evaluation of the rest of the
   graph in the same stabilize() pass. See docs/design.md,
   "Implementation deviations", and lib/graph.ml's evaluate_bind. *)

(* A direct self-referential cycle via bind: constructed through a
   forward-reference cell, since a bind's [f] can only return an
   already-existing node under normal use — this is the deliberately
   adversarial construction the RFC's Section 9 asks for. *)
let test_direct_cycle_via_bind_rejected () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let self = ref None in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun _ ->
        match !self with
        | Some s -> s
        | None -> Incremental.watch (Incremental.var g 0) (* first call: harmless placeholder *))
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  (* only now does the closure start seeing [Some dyn]; the first
     stabilize above ran with [self = None], genuinely taking the
     placeholder branch *)
  self := Some dyn;
  (* first stabilize is fine (placeholder branch) *)
  Alcotest.(check int) "first stabilize takes the placeholder branch" 0 (Incremental.value obs);
  Incremental.set sel 1;
  Incremental.stabilize g (* completes without raising *);
  (* the exception message embeds internal node ids that vary run to
     run, so assert on the exception's shape via a wildcard match
     rather than exact string equality *)
  (try
     let (_ : int) = Incremental.value obs in
     Alcotest.fail "expected Cycle_detected from value ()"
   with
  | Incremental.Cycle_detected _ -> ()
  | e -> Alcotest.failf "wrong exception: %s" (Printexc.to_string e));
  Incremental.disable obs

let test_graph_usable_after_rejected_cycle () =
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
  (try
     let (_ : int) = Incremental.value obs in
     Alcotest.fail "expected Cycle_detected"
   with
  | Incremental.Cycle_detected _ -> ()
  | e -> Alcotest.failf "wrong exception: %s" (Printexc.to_string e));
  (* graph must remain valid and independently usable afterward *)
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack dyn ];
  Incremental.set sel 0;
  Incremental.stabilize g;
  Alcotest.(check int) "unaffected computations still work after a rejected cycle" 0 (Incremental.value obs);
  let x = Incremental.var g 3 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> v * 2) in
  let obs2 = Incremental.observe g y in
  Incremental.stabilize g;
  Alcotest.(check int) "fresh, unrelated computations still work" 6 (Incremental.value obs2);
  Incremental.disable obs;
  Incremental.disable obs2

(* A cycle introduced indirectly, through a chain of nested binds
   rather than a single self-reference, and confirming an UNRELATED
   node is still correctly evaluated in the SAME stabilize() pass that
   contains the rejected cycle. *)
let test_cycle_via_nested_bind_chain_rejected () =
  let g = Incremental.create () in
  let sel_a = Incremental.var g 0 in
  let sel_b = Incremental.var g 0 in
  let node_a = ref None in
  let b =
    Incremental.bind g (Incremental.watch sel_b) ~f:(fun v ->
        if v = 0 then Incremental.watch (Incremental.var g 1)
        else match !node_a with Some a -> a | None -> Incremental.watch (Incremental.var g 1))
  in
  let a =
    Incremental.bind g (Incremental.watch sel_a) ~f:(fun v -> if v = 0 then Incremental.watch (Incremental.var g 2) else b)
  in
  node_a := Some a;
  let obs = Incremental.observe g a in
  let unrelated_x = Incremental.var g 10 in
  let unrelated_y = Incremental.map g (Incremental.watch unrelated_x) ~f:(fun v -> v * 2) in
  let unrelated_obs = Incremental.observe g unrelated_y in
  Incremental.stabilize g;
  Alcotest.(check int) "initial: a takes its placeholder branch" 2 (Incremental.value obs);
  Incremental.set sel_a 1;
  Incremental.stabilize g;
  Alcotest.(check int) "a now routes through b, which still takes its own placeholder" 1 (Incremental.value obs);
  Incremental.set sel_b 1;
  Incremental.set unrelated_x 20 (* changed in the SAME pass as the rejected cycle *);
  Incremental.stabilize g (* completes without raising *);
  (try
     let (_ : int) = Incremental.value obs in
     Alcotest.fail "expected Cycle_detected for a -> b -> a"
   with
  | Incremental.Cycle_detected _ -> ()
  | e -> Alcotest.failf "wrong exception: %s" (Printexc.to_string e));
  Alcotest.(check int) "unrelated node in the same pass was still correctly evaluated" 40 (Incremental.value unrelated_obs);
  Incremental.Debug.assert_invariants [ Incremental.Debug.pack a; Incremental.Debug.pack b; Incremental.Debug.pack unrelated_y ];
  Incremental.disable obs;
  Incremental.disable unrelated_obs

let tests =
  [
    Alcotest.test_case "direct self-cycle via bind: Failed(Cycle_detected) on value" `Quick
      test_direct_cycle_via_bind_rejected;
    Alcotest.test_case "graph remains usable after a rejected cycle" `Quick test_graph_usable_after_rejected_cycle;
    Alcotest.test_case "cycle via nested binds: rejected, unrelated work in same pass unaffected" `Quick
      test_cycle_via_nested_bind_chain_rejected;
  ]
