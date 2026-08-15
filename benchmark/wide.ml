(* Benchmark B — Wide DAG: one input feeding thousands of independent
   computations. *)
open Propagate
open Bench_util

let () =
  section "Wide DAG (Benchmark B)";
  List.iter
    (fun width ->
      let name = Printf.sprintf "width %d" width in
      let g = Incremental.create () in
      let x = Incremental.var g 1 in
      let branches =
        Array.init width (fun i -> Incremental.map g (Incremental.watch x) ~f:(fun v -> (v * (i + 1)) mod 1009))
      in
      let obs = ref [||] in
      let _ =
        run ~warmup:0 ~trials:3 ~name:(name ^ ": observe all + first stabilize") ~setup:(fun () -> ()) (fun () ->
            obs := Array.map (Incremental.observe g) branches;
            Incremental.stabilize g;
            Array.iter Incremental.disable !obs)
      in
      obs := Array.map (Incremental.observe g) branches;
      Incremental.stabilize g;
      let counter = ref 0 in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": one update touching all branches") ~setup:(fun () -> ()) (fun () ->
            incr counter;
            Incremental.set x !counter;
            Incremental.stabilize g)
      in
      Array.iter Incremental.disable !obs)
    [ 100; 1_000; 10_000; 100_000 ]
