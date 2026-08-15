open Propagate

let () =
  let g = Incremental.create () in
  let x = Incremental.var g 10 in
  let y = Incremental.map g (Incremental.watch x) ~f:(fun x -> x * 2) in
  let z = Incremental.map g y ~f:(fun y -> y + 100) in
  let obs = Incremental.observe g z in
  Incremental.stabilize g;
  Printf.printf "z = %d (expect 120)\n%!" (Incremental.value obs);
  Incremental.set x 20;
  Incremental.stabilize g;
  Printf.printf "z = %d (expect 140)\n%!" (Incremental.value obs);
  let stats = Incremental.Stats.snapshot g in
  Printf.printf "nodes_created=%d nodes_evaluated=%d stabilizations=%d\n%!" stats.nodes_created
    stats.nodes_evaluated stats.stabilizations;
  (* repeated set before a stabilize should still only evaluate once *)
  Incremental.set x 1;
  Incremental.set x 2;
  Incremental.set x 3;
  let before = (Incremental.Stats.snapshot g).nodes_evaluated in
  Incremental.stabilize g;
  let after = (Incremental.Stats.snapshot g).nodes_evaluated in
  Printf.printf "z = %d (expect 106), evaluated %d nodes for 3 sets (expect 3: x,y,z each once)\n%!"
    (Incremental.value obs) (after - before);
  (* a simple bind, switching dependencies *)
  let selector = Incremental.var g 0 in
  let values = Array.init 5 (fun i -> Incremental.var g (i * 10)) in
  let dyn =
    Incremental.bind g (Incremental.watch selector) ~f:(fun i -> Incremental.watch values.(i))
  in
  let dyn_obs = Incremental.observe g dyn in
  Incremental.stabilize g;
  Printf.printf "dyn = %d (expect 0)\n%!" (Incremental.value dyn_obs);
  Incremental.set selector 3;
  Incremental.stabilize g;
  Printf.printf "dyn = %d (expect 30)\n%!" (Incremental.value dyn_obs);
  Incremental.set values.(3) 999;
  Incremental.stabilize g;
  Printf.printf "dyn = %d (expect 999)\n%!" (Incremental.value dyn_obs);
  Incremental.Debug.assert_invariants
    [ Incremental.Debug.pack (Incremental.watch x); Incremental.Debug.pack z; Incremental.Debug.pack dyn ];
  print_endline "invariants OK"
