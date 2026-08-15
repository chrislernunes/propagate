(* Benchmark D — Shared DAG: many computations sharing common
   ancestors. A binary fan-in tree from [base_width] leaves down to 1
   root; every internal node is shared beneath it by exactly its two
   children's subtrees — the structure that makes "evaluate a shared
   ancestor once, not once per path to it" actually matter. *)
open Propagate
open Bench_util

let build base_width =
  let g = Incremental.create () in
  let inputs = Array.init base_width (fun i -> Incremental.var g i) in
  let layer = ref (Array.map Incremental.watch inputs) in
  while Array.length !layer > 1 do
    let w = Array.length !layer in
    let prev = !layer in
    layer := Array.init (w / 2) (fun i -> Incremental.map2 g prev.(2 * i) prev.((2 * i) + 1) ~f:( + ))
  done;
  let obs = Incremental.observe g !layer.(0) in
  g, inputs, obs

let () =
  section "Shared DAG (Benchmark D)";
  List.iter
    (fun base_width ->
      let layers = int_of_float (log (float_of_int base_width) /. log 2.0) in
      let name = Printf.sprintf "%d leaves (%d layers)" base_width layers in
      let _ =
        run ~warmup:0 ~trials:3 ~name:(name ^ ": build+first stabilize") ~setup:(fun () -> ()) (fun () ->
            let g, _, obs = build base_width in
            Incremental.stabilize g;
            Incremental.disable obs)
      in
      let g, inputs, obs = build base_width in
      Incremental.stabilize g;
      let counter = ref 0 in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": sparse update (1 leaf)") ~setup:(fun () -> ()) (fun () ->
            incr counter;
            Incremental.set inputs.(0) !counter;
            Incremental.stabilize g)
      in
      Incremental.disable obs)
    [ 1 lsl 10; 1 lsl 14; 1 lsl 18 ]
