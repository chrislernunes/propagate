(* Hand-rolled rather than Bechamel/core_bench: this sandbox's network
   allowlist covers apt and a few language package registries but not
   opam's package repository, and Ubuntu's apt-packaged OCaml
   ecosystem (used for the rest of this project — dune, qcheck-core,
   alcotest) doesn't carry either benchmarking library. This harness
   is deliberately minimal — warmup, N timed trials, min/median/mean,
   and Gc-based allocation counts as the profiling signal in place of
   an external profiler (also not available here; see docs/benchmarks.md,
   "Methodology") — but every number it reports is a real wall-clock or
   Gc.stat measurement from this run, not modeled or estimated. *)

type result = { name : string; trials : float array; minor_words : float; major_words : float; promoted_words : float }

let median (a : float array) : float =
  let b = Array.copy a in
  Array.sort compare b;
  let n = Array.length b in
  if n mod 2 = 1 then b.(n / 2) else (b.((n / 2) - 1) +. b.(n / 2)) /. 2.0

let mean (a : float array) : float = Array.fold_left ( +. ) 0.0 a /. float_of_int (Array.length a)
let min_of (a : float array) : float = Array.fold_left min a.(0) a

(* [setup] runs once per trial and is NOT timed (e.g. building the
   graph); [f] receives setup's result and IS timed. Use
   [~warmup:0 ~trials:1] for expensive one-shot measurements
   (multi-hundred-thousand-node builds) where repeating [trials] times
   would itself take unreasonably long; the default is tuned for
   cheaper, more variance-prone measurements. *)
let bench ?(warmup = 1) ?(trials = 5) ~name ~(setup : unit -> 'a) (f : 'a -> unit) : result =
  for _ = 1 to warmup do
    f (setup ())
  done;
  Gc.full_major ();
  let s0 = Gc.quick_stat () in
  let times =
    Array.init trials (fun _ ->
        let arg = setup () in
        let t0 = Unix.gettimeofday () in
        f arg;
        let t1 = Unix.gettimeofday () in
        t1 -. t0)
  in
  let s1 = Gc.quick_stat () in
  {
    name;
    trials = times;
    minor_words = (s1.Gc.minor_words -. s0.Gc.minor_words) /. float_of_int trials;
    major_words = (s1.Gc.major_words -. s0.Gc.major_words) /. float_of_int trials;
    promoted_words = (s1.Gc.promoted_words -. s0.Gc.promoted_words) /. float_of_int trials;
  }

let fmt_secs (s : float) : string =
  if s < 1e-6 then Printf.sprintf "%.0fns" (s *. 1e9)
  else if s < 1e-3 then Printf.sprintf "%.1fus" (s *. 1e6)
  else if s < 1.0 then Printf.sprintf "%.2fms" (s *. 1e3)
  else Printf.sprintf "%.3fs" s

let fmt_words (w : float) : string =
  if w < 1e3 then Printf.sprintf "%.0f" w
  else if w < 1e6 then Printf.sprintf "%.1fK" (w /. 1e3)
  else Printf.sprintf "%.2fM" (w /. 1e6)

let report (r : result) : unit =
  Printf.printf "%-52s min %8s  median %8s  mean %8s  | alloc/trial: minor %8s major %8s promoted %8s\n%!" r.name
    (fmt_secs (min_of r.trials))
    (fmt_secs (median r.trials))
    (fmt_secs (mean r.trials))
    (fmt_words r.minor_words) (fmt_words r.major_words) (fmt_words r.promoted_words)

let run ?warmup ?trials ~name ~setup f =
  let r = bench ?warmup ?trials ~name ~setup f in
  report r;
  r

let section (title : string) : unit = Printf.printf "\n=== %s ===\n%!" title
