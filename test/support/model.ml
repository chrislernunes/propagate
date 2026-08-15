(* A small op-sequence DSL used by both test/property and
   test/differential. Building "the same graph shape" in two
   structurally independent representations at once is the whole
   mechanism differential testing relies on (see lib/reference.ml's
   header comment); this module is where that pairing happens. Values
   are fixed to [int] throughout — polymorphism isn't what's under
   test here, and staying monomorphic keeps the generator and shrinker
   tractable. *)

open Propagate

type fn1 = { name1 : string; f1 : int -> int }
type fn2 = { name2 : string; f2 : int -> int -> int }

(* [100/x] is deliberately included: it raises Division_by_zero
   whenever a chain routes a zero into it, which is what gives the
   random generator exception-path coverage (Stage 8) for free,
   without a dedicated "sometimes raise" op. *)
let fns1 =
  [|
    { name1 = "+1"; f1 = (fun x -> x + 1) };
    { name1 = "*2"; f1 = (fun x -> x * 2) };
    { name1 = "neg"; f1 = (fun x -> -x) };
    { name1 = "mod7"; f1 = (fun x -> x mod 7) };
    { name1 = "abs"; f1 = abs };
    { name1 = "100/x"; f1 = (fun x -> 100 / x) };
  |]

let fns2 =
  [|
    { name2 = "+"; f2 = ( + ) };
    { name2 = "-"; f2 = ( - ) };
    { name2 = "*"; f2 = ( * ) };
    { name2 = "max"; f2 = max };
    { name2 = "min"; f2 = min };
  |]

type op =
  | New_var of int
  | Map1 of int * int (* fn index, source node index — both taken mod a live count at run time *)
  | Map2_ of int * int * int (* fn index, source1, source2 *)
  | Bind1 of int (* source (lhs) index; f switches among a pool of prior nodes fixed at construction *)
  | Set of int * int (* var-list index, new value *)
  | Stabilize
  | Observe of int (* node index *)
  | Disable of int (* observer-list index *)

let norm_mod (v : int) (m : int) : int = if m <= 0 then 0 else ((v mod m) + m) mod m

(* ---------------- generator (QCheck2) ---------------- *)

let gen_op : op QCheck2.Gen.t =
  let open QCheck2.Gen in
  oneof_weighted
    [
      (3, map (fun v -> New_var v) (int_range (-50) 50));
      (4, map2 (fun a b -> Map1 (a, b)) nat_small nat_small);
      (3, map3 (fun a b c -> Map2_ (a, b, c)) nat_small nat_small nat_small);
      (2, map (fun a -> Bind1 a) nat_small);
      (4, map2 (fun a b -> Set (a, b)) nat_small (int_range (-50) 50));
      (5, return Stabilize);
      (2, map (fun a -> Observe a) nat_small);
      (2, map (fun a -> Disable a) nat_small);
    ]

let gen_ops (max_len : int) : op list QCheck2.Gen.t = QCheck2.Gen.list_size (QCheck2.Gen.int_range 1 max_len) gen_op

(* ---------------- interpreter ---------------- *)

type outcome_mismatch = { op_index : int; op : op; detail : string }

exception Mismatch of outcome_mismatch

type state = {
  g : Incremental.runtime;
  mutable nodes : (int Incremental.t * int Reference.t) list; (* most recent first *)
  mutable n_nodes : int;
  mutable vars : (int Incremental.var * int Reference.t) list;
  mutable n_vars : int;
  mutable observers : (int Incremental.observer * int Reference.t) list;
  mutable n_observers : int;
  mutable roots : Incremental.Debug.packed list; (* every node ever created, for invariant checking *)
}

let create_state () =
  {
    g = Incremental.create ();
    nodes = [];
    n_nodes = 0;
    vars = [];
    n_vars = 0;
    observers = [];
    n_observers = 0;
    roots = [];
  }

let push_node st (pair : int Incremental.t * int Reference.t) =
  st.nodes <- pair :: st.nodes;
  st.n_nodes <- st.n_nodes + 1;
  st.roots <- Incremental.Debug.pack (fst pair) :: st.roots

let describe_op = function
  | New_var v -> Printf.sprintf "New_var %d" v
  | Map1 (f, s) -> Printf.sprintf "Map1 (%d, %d)" f s
  | Map2_ (f, a, b) -> Printf.sprintf "Map2_ (%d, %d, %d)" f a b
  | Bind1 s -> Printf.sprintf "Bind1 %d" s
  | Set (v, x) -> Printf.sprintf "Set (%d, %d)" v x
  | Stabilize -> "Stabilize"
  | Observe n -> Printf.sprintf "Observe %d" n
  | Disable o -> Printf.sprintf "Disable %d" o

(* Runs [op] against both sides. Returns [true] if it actually did
   something (some ops are no-ops on an empty state, e.g. Map1 before
   any node exists — the generator doesn't know the state, so the
   interpreter is responsible for skipping cleanly). Raises [Mismatch]
   on any disagreement, and asserts invariants after every op that
   touches the graph's structure or necessity. *)
let step ~check_invariants_every_op (st : state) (op_index : int) (op : op) : unit =
  let fail detail = raise (Mismatch { op_index; op; detail }) in
  (match op with
   | New_var v ->
     let iv = Incremental.var st.g v in
     let rv = Reference.var v in
     push_node st (Incremental.watch iv, rv);
     st.vars <- (iv, rv) :: st.vars;
     st.n_vars <- st.n_vars + 1
   | Map1 (fi, si) ->
     if st.n_nodes > 0 then begin
       let fn = fns1.(norm_mod fi (Array.length fns1)) in
       let it, rt = List.nth st.nodes (norm_mod si st.n_nodes) in
       push_node st (Incremental.map st.g it ~f:fn.f1, Reference.map rt ~f:fn.f1)
     end
   | Map2_ (fi, ai, bi) ->
     if st.n_nodes > 0 then begin
       let fn = fns2.(norm_mod fi (Array.length fns2)) in
       let ia, ra = List.nth st.nodes (norm_mod ai st.n_nodes) in
       let ib, rb = List.nth st.nodes (norm_mod bi st.n_nodes) in
       push_node st (Incremental.map2 st.g ia ib ~f:fn.f2, Reference.map2 ra rb ~f:fn.f2)
     end
   | Bind1 si ->
     if st.n_nodes > 0 then begin
       let ilhs, rlhs = List.nth st.nodes (norm_mod si st.n_nodes) in
       (* fixed pool, snapshotted now — this is what makes bind's
          dependency structure genuinely change over time as the pool
          members' *own* values change and as lhs picks different
          members, without the graph growing unboundedly inside f. *)
       let pool = Array.of_list st.nodes in
       let pool_size = Array.length pool in
       let ib = Incremental.bind st.g ilhs ~f:(fun v -> fst pool.(norm_mod v pool_size)) in
       let rb = Reference.bind rlhs ~f:(fun v -> snd pool.(norm_mod v pool_size)) in
       push_node st (ib, rb)
     end
   | Set (vi, x) ->
     if st.n_vars > 0 then begin
       let iv, rv = List.nth st.vars (norm_mod vi st.n_vars) in
       Incremental.set iv x;
       Reference.set rv x
     end
   | Observe ni ->
     if st.n_nodes > 0 then begin
       let it, rt = List.nth st.nodes (norm_mod ni st.n_nodes) in
       let obs = Incremental.observe st.g it in
       st.observers <- (obs, rt) :: st.observers;
       st.n_observers <- st.n_observers + 1
     end
   | Disable oi ->
     if st.n_observers > 0 then begin
       let idx = norm_mod oi st.n_observers in
       let obs, _ = List.nth st.observers idx in
       Incremental.disable obs;
       st.observers <- List.filteri (fun i _ -> i <> idx) st.observers;
       st.n_observers <- st.n_observers - 1
     end
   | Stabilize ->
     Incremental.stabilize st.g;
     List.iter
       (fun (obs, rnode) ->
         let inc_result = try Ok (Incremental.value obs) with e -> Error e in
         let ref_result = Reference.value_result rnode in
         match inc_result, ref_result with
         | Ok a, Ok b -> if a <> b then fail (Printf.sprintf "value mismatch: production=%d reference=%d" a b)
         | Error e1, Error e2 ->
           if Printexc.to_string e1 <> Printexc.to_string e2 then
             fail
               (Printf.sprintf "exception mismatch: production=%s reference=%s" (Printexc.to_string e1)
                  (Printexc.to_string e2))
         | Ok a, Error e -> fail (Printf.sprintf "production=Ok %d but reference=Error %s" a (Printexc.to_string e))
         | Error e, Ok b -> fail (Printf.sprintf "production=Error %s but reference=Ok %d" (Printexc.to_string e) b))
       st.observers);
  if check_invariants_every_op then
    match Incremental.Debug.check_invariants st.roots with
    | [] -> ()
    | vs -> fail ("invariant violation(s): " ^ String.concat "; " vs)

let run ?(check_invariants_every_op = true) (ops : op list) : (unit, outcome_mismatch) result =
  let st = create_state () in
  try
    List.iteri (fun i op -> step ~check_invariants_every_op st i op) ops;
    (* final stabilize + compare, in case the sequence didn't end on one *)
    step ~check_invariants_every_op st (List.length ops) Stabilize;
    Ok ()
  with Mismatch m -> Error m

let ops_to_string (ops : op list) : string =
  "[" ^ String.concat "; " (List.map describe_op ops) ^ "]"
