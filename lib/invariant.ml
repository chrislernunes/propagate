(* Debug-only invariant checker (Stage 5). Deliberately not wired into
   any hot path — callers (property tests, invariant tests) decide
   when to pay for a full-graph walk. See docs/design.md, "Testing
   strategy", for why roots are caller-supplied rather than drawn from
   a global registry: a registry of every node ever created would be
   exactly the kind of retention that defeats the necessity-refcount
   GC story (same reasoning as Stats avoiding one). Callers — property
   tests building a graph — naturally already have a list of every
   node they created and can pass it directly. *)

type violation = { node_id : int; invariant_name : string; message : string }

let describe (v : violation) : string = Printf.sprintf "[%s] node #%d: %s" v.invariant_name v.node_id v.message

let dependencies_of (Node.Pack n : Node.packed) : Node.packed list =
  match n.kind with
  | Var _ -> []
  | Map (dep, _) -> [ Node.Pack dep ]
  | Map2 (a, b, _) -> [ Node.Pack a; Node.Pack b ]
  | Cutoff (dep, _) -> [ Node.Pack dep ]
  | Bind bc -> Node.Pack bc.b_lhs :: (match bc.b_rhs with None -> [] | Some r -> [ Node.Pack r ])

let collect_reachable (roots : Node.packed list) : Node.packed list =
  let visited = Hashtbl.create 256 in
  let all = ref [] in
  let q = Queue.create () in
  List.iter (fun p -> Queue.push p q) roots;
  while not (Queue.is_empty q) do
    let (Node.Pack n) as p = Queue.pop q in
    if not (Hashtbl.mem visited n.id) then begin
      Hashtbl.add visited n.id ();
      all := p :: !all;
      List.iter (fun d -> Queue.push d q) n.dependents;
      List.iter (fun d -> Queue.push d q) (dependencies_of p)
    end
  done;
  !all

let check (roots : Node.packed list) : violation list =
  let violations = ref [] in
  let add invariant_name node_id message = violations := { node_id; invariant_name; message } :: !violations in
  let all_nodes = collect_reachable roots in
  List.iter
    (fun ((Node.Pack n) as p) ->
      if n.height < 0 then add "sanity" (Node.Id.to_int n.id) "negative height";
      List.iter
        (fun (Node.Pack dep) ->
          if not (dep.height < n.height) then
            add "I1_height_order" (Node.Id.to_int n.id)
              (Printf.sprintf "dependency #%d has height %d, expected strictly less than self height %d"
                 (Node.Id.to_int dep.id) dep.height n.height))
        (dependencies_of p);
      let necessary_dependents = List.length (List.filter (fun (Node.Pack d) -> d.necessary_count > 0) n.dependents) in
      let expected = n.observer_count + necessary_dependents in
      if n.necessary_count <> expected then
        add "I3_necessity_count" (Node.Id.to_int n.id)
          (Printf.sprintf "necessary_count=%d but observer_count(%d) + necessary_dependents(%d) = %d" n.necessary_count
             n.observer_count necessary_dependents expected);
      if n.in_heap && n.necessary_count <= 0 then
        add "I4_only_necessary_scheduled" (Node.Id.to_int n.id) "node is in_heap but necessary_count <= 0";
      if n.status = Computing then
        add "status_sanity" (Node.Id.to_int n.id) "node left in Computing status outside of an active stabilize()";
      List.iter
        (fun (Node.Pack dep) ->
          let has_back_edge = List.exists (fun (Node.Pack d) -> Node.Id.equal d.id n.id) dep.dependents in
          if not has_back_edge then
            add "edge_reciprocity" (Node.Id.to_int n.id)
              (Printf.sprintf "depends on #%d but is absent from #%d's dependents list" (Node.Id.to_int dep.id)
                 (Node.Id.to_int dep.id)))
        (dependencies_of p))
    all_nodes;
  (* I7 acyclicity: iterative white/grey/black DFS, explicit stack. *)
  let color : (Node.Id.t, [ `White | `Grey | `Black ]) Hashtbl.t = Hashtbl.create 256 in
  List.iter (fun (Node.Pack n) -> Hashtbl.replace color n.id `White) all_nodes;
  let stack : [ `Enter of Node.packed | `Exit of Node.packed ] Stack.t = Stack.create () in
  List.iter
    (fun ((Node.Pack n) as p) ->
      if Hashtbl.find color n.id = `White then begin
        Stack.push (`Enter p) stack;
        while not (Stack.is_empty stack) do
          match Stack.pop stack with
          | `Enter (Node.Pack n) ->
            Hashtbl.replace color n.id `Grey;
            Stack.push (`Exit (Node.Pack n)) stack;
            List.iter
              (fun (Node.Pack d) ->
                match Hashtbl.find_opt color d.id with
                | Some `Grey ->
                  add "I7_acyclicity" (Node.Id.to_int n.id)
                    (Printf.sprintf "cycle: edge to #%d closes a loop back to an in-progress ancestor" (Node.Id.to_int d.id))
                | Some `White | None -> Stack.push (`Enter (Node.Pack d)) stack
                | Some `Black -> ())
              n.dependents
          | `Exit (Node.Pack n) -> Hashtbl.replace color n.id `Black
        done
      end)
    all_nodes;
  !violations

let check_ok (roots : Node.packed list) : unit =
  match check roots with
  | [] -> ()
  | vs -> failwith ("invariant violation(s):\n" ^ String.concat "\n" (List.map describe vs))
