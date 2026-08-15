open Propagate

let live_words () =
  Gc.full_major ();
  Gc.full_major ();
  (Gc.stat ()).live_words

let build_and_drop_chain g n =
  let x = Incremental.var g 0 in
  let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(fun v -> v + 1)) in
  let leaf = chain n (Incremental.watch x) in
  let obs = Incremental.observe g leaf in
  Incremental.stabilize g;
  ignore (Incremental.value obs);
  Incremental.disable obs

(* Disabling the only observer of a chain, and dropping every OCaml
   reference to it, should let ordinary GC reclaim the whole chain —
   nothing in the runtime should be holding it alive on the graph's
   behalf. Bound, not exact: generational GC bookkeeping is inherently
   a little noisy, but a genuine leak of a 5000-node chain would show
   up as tens of thousands of retained words, which this comfortably
   distinguishes from noise. *)
let test_disabled_subgraph_is_reclaimed () =
  let g = Incremental.create () in
  let baseline = live_words () in
  build_and_drop_chain g 5000;
  let after = live_words () in
  let growth = after - baseline in
  Alcotest.(check bool)
    (Printf.sprintf "growth after dropping a disabled 5000-node chain should be small, got %d words" growth)
    true (growth < 20_000)

(* Repeated create/observe/disable/drop cycles should not accumulate:
   the marginal cost of more cycles should not scale with how many
   nodes each cycle builds. Checked as a slope (growth per additional
   batch of iterations) rather than an absolute number, which is more
   robust to whatever fixed overhead the runtime itself legitimately
   carries. *)
let test_repeated_cycles_do_not_leak () =
  let g = Incremental.create () in
  let run_batch n_iters =
    for _ = 1 to n_iters do
      build_and_drop_chain g 200
    done;
    live_words ()
  in
  let after_10 = run_batch 10 in
  let after_60 = run_batch 50 in
  let growth_per_50_more = after_60 - after_10 in
  Alcotest.(check bool)
    (Printf.sprintf "growth over 50 more cycles should not scale with node count, got %d words" growth_per_50_more)
    true
    (growth_per_50_more < 40_000)

(* A bind's old rhs, once switched away from and disabled/dropped,
   should not remain retained via the bind's own bookkeeping —
   otherwise a long-lived bind that rebinds many times would leak
   every branch it ever visited. *)
let test_bind_old_rhs_not_retained () =
  let g = Incremental.create () in
  let baseline = live_words () in
  let sel = Incremental.var g 0 in
  let make_big_branch tag =
    let v = Incremental.var g tag in
    let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(fun x -> x + 1)) in
    chain 3000 (Incremental.watch v)
  in
  let dyn = Incremental.bind g (Incremental.watch sel) ~f:(fun i -> if i = 0 then make_big_branch 0 else make_big_branch 1) in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Incremental.set sel 1;
  Incremental.stabilize g;
  let after = live_words () in
  Incremental.disable obs;
  let growth = after - baseline in
  (* Empirically, one retained 3000-node chain costs ~65,000 words
     here (~21.6 words/node: the node record, its Map-kind block, its
     cached Fresh value box, and one dependents cons cell). If the old
     branch were *also* retained, growth would be roughly double that,
     around 130,000. The threshold sits well clear of both: comfortable
     headroom above one branch for GC timing noise, comfortably below
     two branches so a real retention leak still fails this test. *)
  Alcotest.(check bool)
    (Printf.sprintf "growth %d should reflect ~1 retained 3000-node branch (~65k words), not 2 (~130k)" growth)
    true (growth < 100_000)

let tests =
  [
    Alcotest.test_case "disabled + dropped subgraph is reclaimed" `Slow test_disabled_subgraph_is_reclaimed;
    Alcotest.test_case "repeated create/observe/disable cycles do not leak" `Slow test_repeated_cycles_do_not_leak;
    Alcotest.test_case "bind's old rhs is not retained after switching away" `Slow test_bind_old_rhs_not_retained;
  ]
