(* Benchmark F — Dense updates: same structure as Benchmark E, but
   each trial changes ALL leaves, for direct contrast with the sparse
   case at matching graph sizes. *)
open Propagate
open Bench_util

let group_size = 1000

let build n_leaves =
  let g = Incremental.create () in
  let leaves = Array.init n_leaves (fun i -> Incremental.var g i) in
  let n_groups = (n_leaves + group_size - 1) / group_size in
  let groups =
    Array.init n_groups (fun gi ->
        let lo = gi * group_size and hi = min n_leaves ((gi + 1) * group_size) in
        let rec fold i acc =
          if i >= hi then acc else fold (i + 1) (Incremental.map2 g acc (Incremental.watch leaves.(i)) ~f:( + ))
        in
        fold (lo + 1) (Incremental.watch leaves.(lo)))
  in
  let rec fold_groups i acc = if i >= n_groups then acc else fold_groups (i + 1) (Incremental.map2 g acc groups.(i) ~f:( + )) in
  let total = fold_groups 1 groups.(0) in
  let obs = Incremental.observe g total in
  g, leaves, obs

let () =
  section "Dense updates (Benchmark F)";
  List.iter
    (fun n_leaves ->
      let name = Printf.sprintf "%d leaves, change ALL" n_leaves in
      let g, leaves, obs = build n_leaves in
      Incremental.stabilize g;
      let counter = ref 0 in
      let _ =
        run ~warmup:1 ~trials:5 ~name ~setup:(fun () -> ()) (fun () ->
            incr counter;
            Array.iter (fun v -> Incremental.set v !counter) leaves;
            Incremental.stabilize g)
      in
      let before = (Incremental.Stats.snapshot g).nodes_evaluated in
      incr counter;
      Array.iter (fun v -> Incremental.set v !counter) leaves;
      Incremental.stabilize g;
      let after = (Incremental.Stats.snapshot g).nodes_evaluated in
      Printf.printf "  -> nodes_evaluated for 1 further all-leaves update: %d (out of %d total nodes)\n%!" (after - before)
        (Array.length leaves + ((Array.length leaves + group_size - 1) / group_size) + 1);
      Incremental.disable obs)
    [ 1_000; 20_000; 200_000 ]
