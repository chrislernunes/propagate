(* Height-indexed bucket scheduler.

   Design (see docs/design.md, "Scheduler"): within a single stabilize
   pass, a just-evaluated node can only ever cause insertions at
   strictly greater heights than itself (Invariant I1, plus no
   interleaved mutation during a pass, Invariant I6). So the minimum
   occupied height, read via [Set.min_elt] on [occupied], only ever
   moves forward across one pass without any manual cursor bookkeeping
   — we simply always ask "what's the current minimum" and it's
   automatically monotonic for the duration of a pass. This is a
   simplification of the RFC's originally-sketched explicit-cursor
   design: same asymptotic shape (a pass costs O(D * log k) for D pops
   across k distinct occupied heights, vs. the RFC's hoped-for O(D) +
   O(H); log k is negligible next to real evaluation cost in practice),
   but with no cursor-reset logic to get wrong between stabilize calls. *)

module Height_set = Set.Make (Int)

type t = {
  buckets : (int, Node.packed list ref) Hashtbl.t;
  mutable occupied : Height_set.t;
  mutable size : int;
  (* Height of whichever node pop_min most recently returned. This is
     exactly "the height currently being processed", which Bind's
     rebind logic (Graph.rebind) needs for its height-fixup rule. None
     before the first pop of a pass, or once the heap has drained. *)
  mutable last_popped_height : int option;
}

let create () =
  { buckets = Hashtbl.create 256; occupied = Height_set.empty; size = 0; last_popped_height = None }

let bucket_for t h =
  match Hashtbl.find_opt t.buckets h with
  | Some r -> r
  | None ->
    let r = ref [] in
    Hashtbl.add t.buckets h r;
    r

let is_empty t = t.size = 0
let size t = t.size
let current_height t = t.last_popped_height

(* Idempotent: a no-op if [n] is already enqueued. This is the sole
   place [in_heap] is set true, keeping I2 ("stale iff in_heap")
   mechanically enforced from one location. *)
let insert t (Node.Pack n) =
  if not n.in_heap then begin
    n.in_heap <- true;
    let b = bucket_for t n.height in
    b := Node.Pack n :: !b;
    t.occupied <- Height_set.add n.height t.occupied;
    t.size <- t.size + 1
  end

(* Remove [n] from wherever it currently sits and clear in_heap. Used
   when a node becomes unnecessary while stale (no point recomputing
   something nobody needs), or after popping (see pop_min). *)
let remove_node t (Node.Pack n) =
  if n.in_heap then begin
    n.in_heap <- false;
    (match Hashtbl.find_opt t.buckets n.height with
     | None -> ()
     | Some b ->
       b := List.filter (fun (Node.Pack x) -> not (Node.Id.equal x.id n.id)) !b;
       if !b = [] then begin
         Hashtbl.remove t.buckets n.height;
         t.occupied <- Height_set.remove n.height t.occupied
       end);
    t.size <- t.size - 1
  end

(* Move [n] from [old_height]'s bucket into its (already-updated)
   current-height bucket, without touching in_heap or size — used
   mid-height-fixup, where the node stays logically "still stale,
   still queued" throughout. *)
let relocate t (Node.Pack n) ~old_height =
  (match Hashtbl.find_opt t.buckets old_height with
   | None -> ()
   | Some b ->
     b := List.filter (fun (Node.Pack x) -> not (Node.Id.equal x.id n.id)) !b;
     if !b = [] then begin
       Hashtbl.remove t.buckets old_height;
       t.occupied <- Height_set.remove old_height t.occupied
     end);
  let b = bucket_for t n.height in
  b := Node.Pack n :: !b;
  t.occupied <- Height_set.add n.height t.occupied

let pop_min t =
  if Height_set.is_empty t.occupied then begin
    t.last_popped_height <- None;
    None
  end
  else begin
    let h = Height_set.min_elt t.occupied in
    let b = Hashtbl.find t.buckets h in
    match !b with
    | [] ->
      (* Shouldn't happen: buckets are removed from [occupied]/the table
         as soon as they go empty (insert/remove_node/relocate all
         maintain this). Defensive fallback rather than a silent hang. *)
      t.occupied <- Height_set.remove h t.occupied;
      Hashtbl.remove t.buckets h;
      t.last_popped_height <- None;
      None
    | (Node.Pack n as p) :: rest ->
      b := rest;
      if rest = [] then begin
        Hashtbl.remove t.buckets h;
        t.occupied <- Height_set.remove h t.occupied
      end;
      n.in_heap <- false;
      t.size <- t.size - 1;
      t.last_popped_height <- Some h;
      Some p
  end

(* Called once at the start of every stabilize() so a fresh pass
   doesn't report a stale cursor from the previous pass. *)
let begin_pass t = t.last_popped_height <- None
