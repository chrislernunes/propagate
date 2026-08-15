(* Hand-crafted differential scenarios, each readable in isolation —
   deliberately not randomized, so a reader can see exactly which
   structural case each one pins down. The random model
   (test/support/model.ml) already covers the combinatorial space with
   thousands of generated cases in test/property; this file is about
   regression coverage for specific shapes worth naming. *)

open Propagate

let assert_agree ~msg (inc_result : (int, exn) result) (ref_result : (int, exn) result) =
  match inc_result, ref_result with
  | Ok a, Ok b -> Alcotest.(check int) msg b a
  | Error e1, Error e2 ->
    Alcotest.(check string) (msg ^ " (exception)") (Printexc.to_string e2) (Printexc.to_string e1)
  | Ok a, Error e -> Alcotest.failf "%s: production=Ok %d but reference=Error %s" msg a (Printexc.to_string e)
  | Error e, Ok b -> Alcotest.failf "%s: production=Error %s but reference=Ok %d" msg (Printexc.to_string e) b

let try_value f = try Ok (f ()) with e -> Error e

(* Benchmark A shape: a long chain, single input. *)
let test_chain () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let rx = Reference.var 1 in
  let n = 200 in
  let rec build k it rt = if k = 0 then it, rt else build (k - 1) (Incremental.map g it ~f:(( + ) 1)) (Reference.map rt ~f:(( + ) 1)) in
  let it, rt = build n (Incremental.watch x) rx in
  let obs = Incremental.observe g it in
  Incremental.stabilize g;
  assert_agree ~msg:"chain initial" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rt);
  Incremental.set x 100;
  Reference.set rx 100;
  Incremental.stabilize g;
  assert_agree ~msg:"chain after set" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rt);
  Incremental.disable obs

(* Benchmark B shape: one var feeding many independent maps. *)
let test_wide () =
  let g = Incremental.create () in
  let x = Incremental.var g 3 in
  let rx = Reference.var 3 in
  let width = 300 in
  let branches = List.init width (fun i -> Incremental.map g (Incremental.watch x) ~f:(fun v -> (v * (i + 1)) mod 97)) in
  let rbranches = List.init width (fun i -> Reference.map rx ~f:(fun v -> (v * (i + 1)) mod 97)) in
  let obs = List.map (Incremental.observe g) branches in
  Incremental.stabilize g;
  List.iter2
    (fun o r -> assert_agree ~msg:"wide initial" (try_value (fun () -> Incremental.value o)) (Reference.value_result r))
    obs rbranches;
  Incremental.set x 41;
  Reference.set rx 41;
  Incremental.stabilize g;
  List.iter2
    (fun o r -> assert_agree ~msg:"wide after set" (try_value (fun () -> Incremental.value o)) (Reference.value_result r))
    obs rbranches;
  List.iter Incremental.disable obs

(* Diamond / shared-ancestor DAG: D depends on B and C, both of which
   depend on A. Exercises both engines' handling of shared
   dependencies — Reference's memo must not blow up exponentially on
   deeper versions of this shape (see docs/design.md, "Reference
   evaluator fairness"), and production must evaluate the shared
   ancestor exactly once per stabilize. *)
let test_diamond () =
  let g = Incremental.create () in
  let x = Incremental.var g 5 in
  let rx = Reference.var 5 in
  let ia = Incremental.map g (Incremental.watch x) ~f:(fun v -> v + 1) in
  let ra = Reference.map rx ~f:(fun v -> v + 1) in
  let ib = Incremental.map g ia ~f:(fun v -> v * 2) in
  let rb = Reference.map ra ~f:(fun v -> v * 2) in
  let ic = Incremental.map g ia ~f:(fun v -> v * 3) in
  let rc = Reference.map ra ~f:(fun v -> v * 3) in
  let id_ = Incremental.map2 g ib ic ~f:( + ) in
  let rd = Reference.map2 rb rc ~f:( + ) in
  let obs = Incremental.observe g id_ in
  Incremental.stabilize g;
  assert_agree ~msg:"diamond initial" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rd);
  let evaluated_before = (Incremental.Stats.snapshot g).nodes_evaluated in
  Incremental.set x 6;
  Reference.set rx 6;
  Incremental.stabilize g;
  let evaluated_after = (Incremental.Stats.snapshot g).nodes_evaluated in
  assert_agree ~msg:"diamond after set" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rd);
  (* x, a, b, c, d = 5 nodes, each evaluated exactly once — in
     particular [a] (the shared ancestor) is not evaluated twice. *)
  Alcotest.(check int) "diamond: exactly 5 evaluations, shared ancestor once" 5 (evaluated_after - evaluated_before);
  Incremental.disable obs

(* Bind switching back and forth between two pre-existing, independently
   observed nodes — including exercising the "relay without re-running
   f" path when the currently-bound target's own input changes. *)
let test_bind_switch_existing () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let rsel = Reference.var 0 in
  let a = Incremental.var g 10 in
  let ra = Reference.var 10 in
  let b = Incremental.var g 20 in
  let rb = Reference.var 20 in
  let dyn = Incremental.bind g (Incremental.watch sel) ~f:(fun i -> if i = 0 then Incremental.watch a else Incremental.watch b) in
  let rdyn = Reference.bind rsel ~f:(fun i -> if i = 0 then ra else rb) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  assert_agree ~msg:"bind switch: initial (a)" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rdyn);
  Incremental.set sel 1;
  Reference.set rsel 1;
  Incremental.stabilize g;
  assert_agree ~msg:"bind switch: to b" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rdyn);
  (* currently bound to b: changing a must NOT affect dyn *)
  let recomputed_before = (Incremental.Stats.snapshot g).bind_recomputations in
  Incremental.set a 999;
  Reference.set ra 999;
  Incremental.stabilize g;
  assert_agree ~msg:"bind switch: a changed while bound to b" (try_value (fun () -> Incremental.value obs))
    (Reference.value_result rdyn);
  Alcotest.(check int) "bind: changing unbound var doesn't touch bind"
    0
    ((Incremental.Stats.snapshot g).bind_recomputations - recomputed_before);
  (* changing b (the currently-bound var) must relay, not re-run f *)
  let recomputed_before2 = (Incremental.Stats.snapshot g).bind_recomputations in
  Incremental.set b 42;
  Reference.set rb 42;
  Incremental.stabilize g;
  assert_agree ~msg:"bind switch: b changed while bound to b" (try_value (fun () -> Incremental.value obs))
    (Reference.value_result rdyn);
  Alcotest.(check int) "bind: relay path doesn't re-run f" 0 ((Incremental.Stats.snapshot g).bind_recomputations - recomputed_before2);
  Incremental.set sel 0;
  Reference.set rsel 0;
  Incremental.stabilize g;
  assert_agree ~msg:"bind switch: back to a" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rdyn);
  Incremental.disable obs

(* Bind to a brand new subgraph created inline by f, and confirm it
   settles within the SAME stabilize call — the regression case for
   the "one-stabilization-late" bug described in docs/design.md
   ("Bind"). *)
let test_bind_fresh_subgraph_same_pass () =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let rsel = Reference.var 0 in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun i ->
        let v = Incremental.var g i in
        Incremental.map g (Incremental.watch v) ~f:(fun x -> x * 100))
  in
  let rdyn = Reference.bind rsel ~f:(fun i -> Reference.map (Reference.var i) ~f:(fun x -> x * 100)) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  assert_agree ~msg:"fresh subgraph: initial" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rdyn);
  let stabilizations_before = (Incremental.Stats.snapshot g).stabilizations in
  Incremental.set sel 7;
  Reference.set rsel 7;
  Incremental.stabilize g;
  let stabilizations_after = (Incremental.Stats.snapshot g).stabilizations in
  Alcotest.(check int) "exactly one stabilize call needed" 1 (stabilizations_after - stabilizations_before);
  assert_agree ~msg:"fresh subgraph: settles in one pass" (try_value (fun () -> Incremental.value obs))
    (Reference.value_result rdyn);
  Incremental.disable obs

(* Nested bind: the inner bind's own dependency structure changes as a
   function of the outer bind's selection. *)
let test_nested_bind () =
  let g = Incremental.create () in
  let outer_sel = Incremental.var g 0 in
  let router_sel = Incremental.var g 0 in
  let vals = Array.init 4 (fun i -> Incremental.var g (i * 100)) in
  let rsel_outer = Reference.var 0 in
  let rsel_router = Reference.var 0 in
  let rvals = Array.init 4 (fun i -> Reference.var (i * 100)) in
  let inner_i (i : int) =
    Incremental.bind g (Incremental.watch router_sel) ~f:(fun j -> Incremental.watch vals.((i + j) mod 4))
  in
  let rinner_i i = Reference.bind rsel_router ~f:(fun j -> rvals.((i + j) mod 4)) in
  let dyn = Incremental.bind g (Incremental.watch outer_sel) ~f:(fun i -> inner_i i) in
  let rdyn = Reference.bind rsel_outer ~f:(fun i -> rinner_i i) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  assert_agree ~msg:"nested bind: initial" (try_value (fun () -> Incremental.value obs)) (Reference.value_result rdyn);
  List.iter
    (fun (o, r) ->
      Incremental.set outer_sel o;
      Reference.set rsel_outer o;
      Incremental.set router_sel r;
      Reference.set rsel_router r;
      Incremental.stabilize g;
      assert_agree ~msg:(Printf.sprintf "nested bind: outer=%d router=%d" o r) (try_value (fun () -> Incremental.value obs))
        (Reference.value_result rdyn))
    [ 1, 0; 2, 1; 0, 3; 3, 2; 1, 1 ];
  Incremental.disable obs

(* A modest reuse of the random model, at a scale that keeps this file
   fast, for basic coverage of the same combinatorial space from a
   second angle. The heavy lifting is in test/property. *)
let test_random_sample () =
  let gen = Test_support.Model.gen_ops 80 in
  let rand = Random.State.make [| 424242 |] in
  for _ = 1 to 100 do
    let ops = QCheck2.Gen.generate1 ~rand gen in
    match Test_support.Model.run ops with
    | Ok () -> ()
    | Error m ->
      Alcotest.failf "random sample mismatch at op #%d (%s): %s\nsequence: %s" m.op_index
        (Test_support.Model.describe_op m.op) m.detail
        (Test_support.Model.ops_to_string ops)
  done

let () =
  Alcotest.run "differential"
    [
      ( "structural",
        [
          Alcotest.test_case "chain" `Quick test_chain;
          Alcotest.test_case "wide" `Quick test_wide;
          Alcotest.test_case "diamond (shared ancestor evaluated once)" `Quick test_diamond;
          Alcotest.test_case "bind: switch between existing nodes" `Quick test_bind_switch_existing;
          Alcotest.test_case "bind: fresh subgraph settles same pass" `Quick test_bind_fresh_subgraph_same_pass;
          Alcotest.test_case "bind: nested" `Quick test_nested_bind;
        ] );
      "random sample", [ Alcotest.test_case "100 random sequences" `Quick test_random_sample ];
    ]
