(* Benchmark G — Dynamic dependencies: repeated switching among a
   fixed pool of targets, at varying pool size and switch count. *)
open Propagate
open Bench_util

let build pool_size =
  let g = Incremental.create () in
  let sel = Incremental.var g 0 in
  let pool = Array.init pool_size (fun i -> Incremental.var g i) in
  let dyn =
    Incremental.bind g (Incremental.watch sel) ~f:(fun i -> Incremental.watch pool.(((i mod pool_size) + pool_size) mod pool_size))
  in
  let obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  g, sel, obs

let () =
  section "Dynamic dependencies (Benchmark G)";
  List.iter
    (fun (pool_size, n_switches) ->
      let name = Printf.sprintf "pool %d, %d switches" pool_size n_switches in
      let g, sel, obs = build pool_size in
      let _ =
        run ~warmup:0 ~trials:1 ~name ~setup:(fun () -> ()) (fun () ->
            for i = 1 to n_switches do
              Incremental.set sel i;
              Incremental.stabilize g
            done)
      in
      let stats = Incremental.Stats.snapshot g in
      Printf.printf "  -> bind_recomputations=%d bind_relays=%d cycle_rejections=%d\n%!" stats.bind_recomputations
        stats.bind_relays stats.cycle_rejections;
      Incremental.disable obs)
    [ 2, 50_000; 100, 50_000; 10_000, 50_000 ]
