(* Benchmark C — Deep DAG: thousands of levels, width 4 per level, each
   node depending on 2 adjacent nodes from the previous level (a
   "thick chain" — structurally distinct from Benchmark A's pure
   width-1 chain: every level does real map2 combination, not just
   relaying a single value forward). *)
open Propagate
open Bench_util

let width = 4

let build depth =
  let g = Incremental.create () in
  let inputs = Array.init width (fun i -> Incremental.var g i) in
  let layer = ref (Array.map Incremental.watch inputs) in
  for l = 1 to depth do
    let prev = !layer in
    layer :=
      Array.init width (fun i -> Incremental.map2 g prev.(i) prev.((i + 1) mod width) ~f:(fun a b -> (a + b + l) mod 100_003))
  done;
  let obs = Array.map (Incremental.observe g) !layer in
  g, inputs, obs

let () =
  section "Deep DAG (Benchmark C)";
  List.iter
    (fun depth ->
      let name = Printf.sprintf "depth %d (width %d)" depth width in
      let _ =
        run ~warmup:0 ~trials:3 ~name:(name ^ ": build+first stabilize") ~setup:(fun () -> ()) (fun () ->
            let g, _, obs = build depth in
            Incremental.stabilize g;
            Array.iter Incremental.disable obs)
      in
      let g, inputs, obs = build depth in
      Incremental.stabilize g;
      let counter = ref 0 in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": one incremental update (root input)") ~setup:(fun () -> ()) (fun () ->
            incr counter;
            Incremental.set inputs.(0) !counter;
            Incremental.stabilize g)
      in
      Array.iter Incremental.disable obs)
    [ 100; 1_000; 10_000; 50_000 ]
