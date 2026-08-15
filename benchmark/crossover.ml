(* Crossover study (RFC Section 17 / master prompt Section 22).
   Structure: N independent chains of depth D (so "fraction of the
   graph affected" has a clean meaning: fraction of the N chains whose
   leaf changed). For each (affected fraction, per-node cost) pair,
   measure:
     - incremental: change that fraction of leaves, one stabilize()
     - full recompute: change the same leaves, then call
       Reference.value on the head of *every one* of the N chains
       (that's what "full recomputation" means — recomputing
       everything regardless of what changed), using lib/reference.ml
       — a structurally independent evaluator with its own intra-call
       memoization for DAG sharing, so this is a fair baseline, not a
       crippled one (see docs/benchmarks.md, "Methodology", and Master
       prompt Section 21).
   The crossover point is wherever these two cross, decided by the
   measurements below, not asserted in advance. *)
open Propagate
open Bench_util

let n_chains = 4_000
let depth = 8

type cost = Cheap | Expensive

let apply cost x =
  match cost with
  | Cheap -> x + 1
  | Expensive ->
    let y = ref x in
    for _ = 1 to 200 do
      y := ((!y * 1103515245) + 12345) land 0x7fffffff
    done;
    !y

let build_incremental cost =
  let g = Incremental.create () in
  let leaves = Array.init n_chains (fun i -> Incremental.var g i) in
  let heads =
    Array.map
      (fun v ->
        let rec chain k t = if k = 0 then t else chain (k - 1) (Incremental.map g t ~f:(apply cost)) in
        chain depth (Incremental.watch v))
      leaves
  in
  let obs = Array.map (Incremental.observe g) heads in
  Incremental.stabilize g;
  g, leaves, obs

let build_reference cost =
  let leaves = Array.init n_chains (fun i -> Reference.var i) in
  let heads =
    Array.map
      (fun v ->
        let rec chain k t = if k = 0 then t else chain (k - 1) (Reference.map t ~f:(apply cost)) in
        chain depth v)
      leaves
  in
  leaves, heads

let affected_fractions = [ 0.0001; 0.001; 0.01; 0.05; 0.10; 0.25; 0.50; 0.75; 1.00 ]

let indices_to_change fraction =
  let k = max 1 (int_of_float (fraction *. float_of_int n_chains)) in
  Array.init k (fun i -> i * (n_chains / k))

let run_one cost =
  section
    (Printf.sprintf "Crossover: %d chains x depth %d, cost=%s" n_chains depth
       (match cost with Cheap -> "cheap (x+1)" | Expensive -> "expensive (~200 int ops)"));
  Printf.printf "%-10s | %14s | %14s | winner\n%!" "fraction" "incremental" "full recompute";
  List.iter
    (fun fraction ->
      let idx = indices_to_change fraction in
      let g, leaves, obs = build_incremental cost in
      let counter = ref 0 in
      let t_inc =
        let r =
          bench ~warmup:1 ~trials:5 ~name:"inc" ~setup:(fun () -> ()) (fun () ->
              incr counter;
              Array.iter (fun i -> Incremental.set leaves.(i) !counter) idx;
              Incremental.stabilize g)
        in
        median r.trials
      in
      Array.iter Incremental.disable obs;
      let rleaves, rheads = build_reference cost in
      let rcounter = ref 0 in
      let t_full =
        let r =
          bench ~warmup:1 ~trials:5 ~name:"full" ~setup:(fun () -> ()) (fun () ->
              incr rcounter;
              Array.iter (fun i -> Reference.set rleaves.(i) !rcounter) idx;
              Array.iter (fun h -> ignore (Reference.value h)) rheads)
        in
        median r.trials
      in
      let winner = if t_inc < t_full then "incremental" else "full recompute" in
      Printf.printf "%-10s | %14s | %14s | %s\n%!" (Printf.sprintf "%.4f%%" (fraction *. 100.0)) (fmt_secs t_inc)
        (fmt_secs t_full) winner)
    affected_fractions

let () =
  run_one Cheap;
  run_one Expensive
