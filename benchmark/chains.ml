(* Benchmark A — Chain: A -> B -> C -> ... -> N. *)
open Propagate
open Bench_util

let build n =
  let g = Incremental.create () in
  let x = Incremental.var g 0 in
  let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(fun v -> v + 1)) in
  let leaf = chain n (Incremental.watch x) in
  let obs = Incremental.observe g leaf in
  g, x, obs

let () =
  section "Chain (Benchmark A)";
  List.iter
    (fun n ->
      let name = Printf.sprintf "chain length %d" n in
      let _ =
        run ~warmup:0 ~trials:3 ~name:(name ^ ": build+first stabilize") ~setup:(fun () -> ())
          (fun () ->
            let g, _, obs = build n in
            Incremental.stabilize g;
            ignore (Incremental.value obs))
      in
      let g, x, obs = build n in
      Incremental.stabilize g;
      let counter = ref 0 in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": one incremental update (set+stabilize)") ~setup:(fun () -> ())
          (fun () ->
            incr counter;
            Incremental.set x !counter;
            Incremental.stabilize g)
      in
      Incremental.disable obs)
    [ 100; 1_000; 10_000; 100_000 ]
