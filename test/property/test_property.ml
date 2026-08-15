open Propagate
module M = Test_support.Model

(* Invariant 1 (every reachable node consistent with dependencies) and
   Invariant 4 (incremental == full recomputation) and Invariant 6
   (mutations preserve dependency consistency): this single test is
   where the bulk of the coverage lives. Every mutating op is followed
   by a full invariant-checker pass, and every Stabilize is followed
   by a differential check against Reference. *)
let test_random_sequences =
  QCheck2.Test.make ~name:"random op sequences: invariants hold, production matches reference" ~count:3000
    ~print:M.ops_to_string (M.gen_ops 120) (fun ops ->
      match M.run ops with
      | Ok () -> true
      | Error m ->
        QCheck2.Test.fail_reportf "at op #%d (%s): %s\nfull sequence: %s" m.op_index (M.describe_op m.op) m.detail
          (M.ops_to_string ops))

(* Same model, longer sequences, run less often — cheap way to get
   deeper graphs and more bind-switching per sequence without paying
   that cost on every one of the 3000 short-sequence cases above. *)
let test_random_sequences_long =
  QCheck2.Test.make ~name:"random op sequences (long): invariants hold, production matches reference" ~count:300
    ~print:M.ops_to_string (M.gen_ops 600) (fun ops ->
      match M.run ops with
      | Ok () -> true
      | Error m ->
        QCheck2.Test.fail_reportf "at op #%d (%s): %s\nfull sequence length %d" m.op_index (M.describe_op m.op)
          m.detail (List.length ops))

(* Invariant 2: changing an unrelated input does not change the value
   of a computation. Not just "the differential check would probably
   have caught it" — this asserts the *mechanism* directly, via a side
   effect in the compute function, so it fails if the unrelated branch
   is recomputed at all, even if it happens to recompute to the same
   value. [depth] is randomized to vary chain length. *)
let test_unrelated_input_isolation =
  QCheck2.Test.make ~name:"unrelated input changes do not recompute an independent branch" ~count:200
    ~print:string_of_int
    (QCheck2.Gen.int_range 1 20)
    (fun depth ->
      let g = Incremental.create () in
      let x1 = Incremental.var g 0 in
      let x2 = Incremental.var g 0 in
      let calls = ref 0 in
      let rec chain n t = if n = 0 then t else chain (n - 1) (Incremental.map g t ~f:(fun v -> v + 1)) in
      let branch1 = chain depth (Incremental.watch x1) in
      let branch2 =
        chain depth
          (Incremental.map g (Incremental.watch x2) ~f:(fun v ->
               incr calls;
               v))
      in
      let obs1 = Incremental.observe g branch1 in
      let obs2 = Incremental.observe g branch2 in
      Incremental.stabilize g;
      let calls_after_first_stabilize = !calls in
      Incremental.set x1 (Incremental.value obs1 + 1);
      Incremental.stabilize g;
      let unaffected = !calls = calls_after_first_stabilize in
      Incremental.disable obs1;
      Incremental.disable obs2;
      unaffected)

(* Invariant 3: repeated stabilization without input changes performs
   no unnecessary computation. Checked via Stats.nodes_evaluated,
   which is exactly the counter this invariant is about. *)
let test_noop_stabilize_does_no_work =
  QCheck2.Test.make ~name:"stabilize with nothing changed evaluates nothing" ~count:200 ~print:string_of_int
    (QCheck2.Gen.int_range 1 30)
    (fun width ->
      let g = Incremental.create () in
      let vars = Array.init width (fun i -> Incremental.var g i) in
      let sum =
        Array.fold_left (fun acc v -> Incremental.map2 g acc (Incremental.watch v) ~f:( + )) (Incremental.watch vars.(0))
          (Array.sub vars 1 (width - 1))
      in
      let obs = Incremental.observe g sum in
      Incremental.stabilize g;
      let before = (Incremental.Stats.snapshot g).nodes_evaluated in
      Incremental.stabilize g;
      Incremental.stabilize g;
      let after = (Incremental.Stats.snapshot g).nodes_evaluated in
      Incremental.disable obs;
      after = before)

let () = exit (QCheck_base_runner.run_tests ~verbose:true [
  test_random_sequences;
  test_random_sequences_long;
  test_unrelated_input_isolation;
  test_noop_stabilize_does_no_work;
])
