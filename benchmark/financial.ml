(* Benchmark H — Financial dependency graph. A synthetic workload with
   a realistic *shape* (market data -> returns -> rolling statistics
   -> risk factors -> portfolio metrics -> risk limits), used purely
   to exercise a non-uniform, multi-stage dependency structure. This
   is not a trading system and makes no claim to numerical realism:
   "rolling statistics" here is a simple excess-return proxy rather
   than a genuine windowed computation (true incremental windowing —
   a ring buffer of lagged values rotated by the caller each tick —
   is a real feature in its own right and orthogonal to what this
   benchmark is measuring, which is graph *shape*, not finance). *)
open Propagate
open Bench_util

let n_sectors = 10

let build n_assets =
  let g = Incremental.create () in
  let prices = Array.init n_assets (fun i -> Incremental.var g (100.0 +. float_of_int (i mod 50))) in
  let prev_prices = Array.init n_assets (fun i -> Incremental.var g (100.0 +. float_of_int (i mod 50))) in
  let position_sizes = Array.init n_assets (fun i -> Incremental.var g (1.0 +. float_of_int (i mod 7))) in
  let benchmark_return = Incremental.var g 0.001 in
  let sector_factors = Array.init n_sectors (fun s -> Incremental.var g (0.0005 *. float_of_int s)) in
  (* market data -> returns *)
  let returns =
    Array.init n_assets (fun i ->
        Incremental.map2 g (Incremental.watch prices.(i)) (Incremental.watch prev_prices.(i)) ~f:(fun p prev ->
            (p -. prev) /. prev))
  in
  (* returns -> rolling statistics (simplified: excess return vs benchmark) *)
  let rolling_stats =
    Array.init n_assets (fun i -> Incremental.map2 g returns.(i) (Incremental.watch benchmark_return) ~f:(fun r b -> r -. b))
  in
  (* rolling statistics -> risk factors (combine with this asset's sector factor) *)
  let risk_factors =
    Array.init n_assets (fun i ->
        let sector = i mod n_sectors in
        Incremental.map2 g rolling_stats.(i) (Incremental.watch sector_factors.(sector)) ~f:(fun rs sf -> rs +. sf))
  in
  (* risk factors -> portfolio metrics (position-weighted aggregate) *)
  let weighted =
    Array.init n_assets (fun i -> Incremental.map2 g risk_factors.(i) (Incremental.watch position_sizes.(i)) ~f:( *. ))
  in
  let portfolio_metric =
    let rec fold i acc = if i >= n_assets then acc else fold (i + 1) (Incremental.map2 g acc weighted.(i) ~f:( +. )) in
    fold 1 weighted.(0)
  in
  (* portfolio metrics -> risk limits *)
  let threshold = 50.0 in
  let breach = Incremental.map g portfolio_metric ~f:(fun m -> Float.abs m > threshold) in
  let obs = Incremental.observe g breach in
  g, prices, obs

let () =
  section "Financial-shaped dependency graph (Benchmark H)";
  List.iter
    (fun n_assets ->
      let name = Printf.sprintf "%d assets, %d sectors, 6 stages" n_assets n_sectors in
      let _ =
        run ~warmup:0 ~trials:3 ~name:(name ^ ": build+first stabilize") ~setup:(fun () -> ()) (fun () ->
            let g, _, obs = build n_assets in
            Incremental.stabilize g;
            Incremental.disable obs)
      in
      let g, prices, obs = build n_assets in
      Incremental.stabilize g;
      let counter = ref 0.0 in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": one day's price update (all assets)") ~setup:(fun () -> ()) (fun () ->
            counter := !counter +. 0.5;
            Array.iter (fun p -> Incremental.set p (100.0 +. !counter)) prices;
            Incremental.stabilize g)
      in
      let _ =
        run ~warmup:2 ~trials:9 ~name:(name ^ ": one asset's price update (sparse)") ~setup:(fun () -> ()) (fun () ->
            counter := !counter +. 0.5;
            Incremental.set prices.(0) (100.0 +. !counter);
            Incremental.stabilize g)
      in
      ignore (Incremental.value obs);
      Incremental.disable obs)
    [ 200; 2_000 ]
