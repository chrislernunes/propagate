open Propagate

let test_default_cutoff_suppresses_on_immediate_values () =
  let g = Incremental.create () in
  let x = Incremental.var g 5 in
  (* v mod 2 lands on 0 or 1, both OCaml immediates and shared, so this
     produces a genuinely physically-equal value across many distinct
     inputs — the case default cutoff is meant to catch for free. *)
  let parity = Incremental.map g (Incremental.watch x) ~f:(fun v -> v mod 2) in
  let calls = ref 0 in
  let downstream =
    Incremental.map g parity ~f:(fun v ->
        incr calls;
        v)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 7 (* still odd: parity unchanged *);
  Incremental.stabilize g;
  Alcotest.(check int) "downstream not re-evaluated: same immediate value" 0 !calls;
  Incremental.set x 8 (* now even: parity changes *);
  Incremental.stabilize g;
  Alcotest.(check int) "downstream re-evaluated: parity changed" 1 !calls;
  Incremental.disable obs

let test_default_cutoff_is_near_noop_for_boxed_values () =
  let g = Incremental.create () in
  let x = Incremental.var g 5 in
  (* Every call allocates a fresh tuple, even when the tuple's content
     is unchanged. Physical-equality cutoff cannot see through that —
     this is the documented limitation (docs/semantics.md, "Cutoff"),
     asserted here so it's a known, tested property rather than folklore. *)
  let pair = Incremental.map g (Incremental.watch x) ~f:(fun v -> (v mod 2, "tag")) in
  let calls = ref 0 in
  let downstream =
    Incremental.map g pair ~f:(fun p ->
        incr calls;
        p)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 7 (* content of the pair is unchanged: (1, "tag") both times *);
  Incremental.stabilize g;
  Alcotest.(check int) "still re-evaluated: fresh allocation each time, even though structurally equal" 1 !calls;
  Incremental.disable obs

let test_custom_cutoff_structural_equality_on_boxed_values () =
  let g = Incremental.create () in
  let x = Incremental.var g 5 in
  let pair = Incremental.map g (Incremental.watch x) ~f:(fun v -> (v mod 2, "tag")) in
  let cut = Incremental.cutoff g pair ~equal:( = ) in
  let calls = ref 0 in
  let downstream =
    Incremental.map g cut ~f:(fun p ->
        incr calls;
        p)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 7;
  Incremental.stabilize g;
  Alcotest.(check int) "cutoff ~equal:(=) suppresses on structurally-equal boxed value" 0 !calls;
  Incremental.set x 8;
  Incremental.stabilize g;
  Alcotest.(check int) "still propagates on a real change" 1 !calls;
  Incremental.disable obs

let test_cutoff_nan_with_structural_equality_never_suppresses () =
  let g = Incremental.create () in
  let x = Incremental.var g 1.0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> 0.0 /. (v -. v) (* always nan, for any finite v *)) in
  let cut = Incremental.cutoff g y ~equal:Float.equal in
  (* Float.equal (unlike (=)) is IEEE-total-order based and treats
     nan as equal to itself, so this is the "NaN-safe" choice. *)
  let calls = ref 0 in
  let downstream =
    Incremental.map g cut ~f:(fun v ->
        incr calls;
        v)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 2.0 (* still produces nan *);
  Incremental.stabilize g;
  Alcotest.(check int) "Float.equal treats nan=nan: suppressed" 0 !calls;
  Incremental.disable obs

let test_cutoff_nan_with_structural_polymorphic_equality_never_suppresses () =
  let g = Incremental.create () in
  let x = Incremental.var g 1.0 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun v -> 0.0 /. (v -. v)) in
  (* Polymorphic (=) on floats follows IEEE semantics: nan = nan is
     false. A user reaching for the "obvious" ~equal:(=) here gets
     surprising behaviour — cutoff never suppresses once the value is
     nan, however many times it's set — which is exactly the footgun
     docs/semantics.md warns about. *)
  let cut = Incremental.cutoff g y ~equal:( = ) in
  let calls = ref 0 in
  let downstream =
    Incremental.map g cut ~f:(fun v ->
        incr calls;
        v)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 2.0;
  Incremental.stabilize g;
  Alcotest.(check int) "(=) on floats: nan<>nan, so this is NOT suppressed" 1 !calls;
  Incremental.disable obs

let test_cutoff_plus_bind () =
  let g = Incremental.create () in
  let x = Incremental.var g 1 in
  let parity = Incremental.map g (Incremental.watch x) ~f:(fun v -> v mod 2) in
  let cut = Incremental.cutoff g parity ~equal:( = ) in
  let branch_calls = ref 0 in
  let dyn =
    Incremental.bind g cut ~f:(fun p ->
        incr branch_calls;
        Incremental.watch (Incremental.var g (if p = 0 then "even" else "odd")))
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Alcotest.(check string) "odd" "odd" (Incremental.value obs);
  let before = !branch_calls in
  Incremental.set x 3 (* still odd: cutoff suppresses, bind's f must not re-run *);
  Incremental.stabilize g;
  Alcotest.(check int) "bind's f not re-run when cutoff suppresses upstream" before !branch_calls;
  Incremental.set x 4 (* now even *);
  Incremental.stabilize g;
  Alcotest.(check string) "even" "even" (Incremental.value obs);
  Alcotest.(check int) "bind's f re-run exactly once for the real change" (before + 1) !branch_calls;
  Incremental.disable obs

let test_cutoff_on_immediate_variant () =
  let g = Incremental.create () in
  (* [true]/[false] and [None] are shared/immediate too. *)
  let x = Incremental.var g 0 in
  let flag = Incremental.map g (Incremental.watch x) ~f:(fun v -> v > 10) in
  let calls = ref 0 in
  let downstream =
    Incremental.map g flag ~f:(fun b ->
        incr calls;
        b)
  in
  let obs = Incremental.observe g downstream in
  Incremental.stabilize g;
  calls := 0;
  Incremental.set x 1;
  Incremental.stabilize g;
  Alcotest.(check int) "false -> false: suppressed" 0 !calls;
  Incremental.set x 20;
  Incremental.stabilize g;
  Alcotest.(check int) "false -> true: propagates" 1 !calls;
  Incremental.disable obs

let tests =
  [
    Alcotest.test_case "default cutoff suppresses on immediates" `Quick test_default_cutoff_suppresses_on_immediate_values;
    Alcotest.test_case "default cutoff is a near-no-op for boxed values" `Quick
      test_default_cutoff_is_near_noop_for_boxed_values;
    Alcotest.test_case "custom cutoff: structural equality on boxed values" `Quick
      test_custom_cutoff_structural_equality_on_boxed_values;
    Alcotest.test_case "cutoff: Float.equal treats nan=nan (suppresses)" `Quick
      test_cutoff_nan_with_structural_equality_never_suppresses;
    Alcotest.test_case "cutoff: polymorphic (=) treats nan<>nan (never suppresses)" `Quick
      test_cutoff_nan_with_structural_polymorphic_equality_never_suppresses;
    Alcotest.test_case "cutoff suppresses upstream of a bind: f not re-run" `Quick test_cutoff_plus_bind;
    Alcotest.test_case "cutoff on an immediate variant (bool)" `Quick test_cutoff_on_immediate_variant;
  ]
