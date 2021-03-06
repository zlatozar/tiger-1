type allocation = Frame.register Temp.Table.t

(* Doubly-linked list rep *)

type 'a dll = 'a Dllist.node_t option ref

type 'a dll_node =
  {mutable node: 'a Dllist.node_t option;
   mutable dll: 'a dll}

let create_dll () = ref None

let dll2list dll = Option.map_default Dllist.to_list [] !dll

let move_node setnode dll =
  let olddll = setnode.dll in
  let head = Option.get !olddll in
  let node = Option.get setnode.node in
  let next = Dllist.drop node in
    setnode.dll <- dll;
    (* Remove from old dll *)
    if next == node then
      olddll := None
    else if node == head then
      olddll := Some next;
    (* Append to new dll *)
    match !dll with
      None ->
        dll := Some node
    | Some other ->
        Dllist.splice (Dllist.prev other) node

(* Node rep *)
type cnode =
  {inode: Igraph.node;
   n: int;
   setnode: cnode dll_node}

(* Move rep *)
type move =
  {src: cnode;
   dst: cnode;
   setnode: move dll_node}

module Cset = Set.Make(struct type t = cnode let compare = compare end)

module Rset = Set.Make(struct type t = Frame.register let compare = compare end)

let color ({Liveness.graph; tnode; gtemp; moves} as igraph) spill_cost allocation registers =
  (* Nodeset functions *)
  let nextn = ref 0 in
  let add_node inode dll =
    let cnode = {inode; n=(!nextn); setnode={node=None; dll}} in
      nextn := !nextn + 1;
      let dllnode = Dllist.create cnode in
        cnode.setnode.node <- Some dllnode;
        begin
          match !dll with
            None ->
              dll := Some dllnode
          | Some other ->
              Dllist.splice (Dllist.prev other) dllnode
        end;
        cnode in

  (* Moveset functions *)
  let add_move src dst dll =
    let move = {src; dst; setnode={node=None; dll}} in
    let dllnode = Dllist.create move in
      move.setnode.node <- Some dllnode;
      begin
        match !dll with
          None ->
            dll := Some dllnode
        | Some other ->
            Dllist.splice (Dllist.prev other) dllnode
      end;
      move in

  (* Start *)
  let n = List.length (Igraph.nodes graph) in
  let k = List.length registers in

  (* Node sets *)
  let precolored = create_dll () in
  let initial = create_dll () in
  let simplify_worklist = create_dll () in
  let freeze_worklist = create_dll () in
  let spill_worklist = create_dll () in
  let spilled_nodes = create_dll () in
  let coalesced_nodes = create_dll () in
  let colored_nodes = create_dll () in
  let select_stack = create_dll () in

  (* Move sets *)
  let coalesced_moves = create_dll () in
  let constrained_moves = create_dll () in
  let frozen_moves = create_dll () in
  let worklist_moves = create_dll () in
  let active_moves = create_dll () in

  (* Other data structures *)
  let adj_set = Array.make_matrix n n false in
  let adj_list = Array.make n Cset.empty in
  let degree = Array.make n 0 in
  let move_list = Array.make n [] in
  let alias = Array.make n None in
  let color = Array.make n None in

  let add_edge u v =
    if not adj_set.(u.n).(v.n) && u != v then
      begin
        adj_set.(u.n).(v.n) <- true;
        adj_set.(v.n).(u.n) <- true;
        if u.setnode.dll != precolored then
          begin
            adj_list.(u.n) <- Cset.add v adj_list.(u.n);
            degree.(u.n) <- degree.(u.n) + 1
          end;
        if v.setnode.dll != precolored then
          begin
            adj_list.(v.n) <- Cset.add u adj_list.(v.n);
            degree.(v.n) <- degree.(v.n) + 1
          end
      end in

  let build () =
    let inodetab = List.fold_left
        (fun tab inode ->
           let temp = gtemp inode in
           let cnode = if Temp.Table.mem temp allocation then
               let cnode = add_node inode precolored in
                 color.(cnode.n) <- Some (Temp.Table.find temp allocation);
                 cnode
             else
               add_node inode initial in
             Igraph.Table.add inode cnode tab)
        Igraph.Table.empty 
        (Igraph.nodes graph) in
      List.iter
        (fun inode ->
           let u = Igraph.Table.find inode inodetab in
             List.iter
               (fun adj -> add_edge u (Igraph.Table.find adj inodetab))
               (Igraph.adj inode))
        (Igraph.nodes graph);
      List.iter
        (fun (u, v) ->
           let u = Igraph.Table.find u inodetab in
           let v = Igraph.Table.find v inodetab in
           let m = add_move u v worklist_moves in
             move_list.(u.n) <- move_list.(u.n) @ [m];
             move_list.(v.n) <- move_list.(v.n) @ [m])
        moves in

  let node_moves n =
    List.filter
      (fun m -> m.setnode.dll == active_moves || m.setnode.dll == worklist_moves)
      move_list.(n.n) in

  let move_related n = node_moves n <> [] in

  let make_worklist () =
    List.iter
      (fun cnode ->
         if degree.(cnode.n) >= k then
           move_node cnode.setnode spill_worklist
         else if move_related cnode then
           move_node cnode.setnode freeze_worklist
         else
           move_node cnode.setnode simplify_worklist)
      (dll2list initial) in

  let adjacent cnode =
    Cset.elements
      (Cset.diff adj_list.(cnode.n)
         (Cset.union
            (Cset.of_list (dll2list select_stack))
            (Cset.of_list (dll2list coalesced_nodes)))) in

  let enable_moves cnodes =
    List.iter
      (fun cnode ->
         List.iter (fun m ->
             if m.setnode.dll == active_moves then
               move_node m.setnode worklist_moves)
           (node_moves cnode))
      cnodes in

  let decrement_degree cnode =
    let d = degree.(cnode.n) in
      degree.(cnode.n) <- degree.(cnode.n) - 1;
      if d = k then
        begin
          enable_moves (cnode :: adjacent cnode);
          if move_related cnode then
            move_node cnode.setnode freeze_worklist
          else
            move_node cnode.setnode simplify_worklist
        end in

  let simplify () =
    List.iter
      (fun (cnode : cnode) ->
         move_node cnode.setnode select_stack;
         List.iter decrement_degree (adjacent cnode))
      (dll2list simplify_worklist) in

  let rec get_alias (cnode : cnode) =
    if cnode.setnode.dll == coalesced_nodes then
      get_alias (Option.get alias.(cnode.n))
    else
      cnode in

  let ok t u = degree.(t.n) < k || t.setnode.dll == precolored || adj_set.(t.n).(u.n) in

  let conservative nodes =
    let d = Cset.fold
        (fun n d -> if degree.(n.n) >= k then d + 1 else d)
        nodes
        0 in
      d < k in

  let add_worklist (u : cnode) =
    if u.setnode.dll != precolored && not (move_related u) && degree.(u.n) < k then
      move_node u.setnode simplify_worklist in

  let combine (u : cnode) (v : cnode) =
    move_node v.setnode coalesced_nodes;
    alias.(v.n) <- Some u;
    move_list.(u.n) <- move_list.(u.n) @ move_list.(v.n);
    enable_moves [v];
    List.iter (fun t -> add_edge t u; decrement_degree t) (adjacent v);
    if degree.(u.n) >= k && u.setnode.dll == freeze_worklist then
      move_node u.setnode spill_worklist
  in

  let coalesce () =
    let ({src; dst} as m) :: _  = dll2list worklist_moves in
    let x = get_alias src in
    let y = get_alias dst in
    let (u, v) = if y.setnode.dll == precolored then (y, x) else (x, y) in
      if u == v then
        (move_node m.setnode coalesced_moves;
         add_worklist u)
      else if v.setnode.dll == precolored || adj_set.(u.n).(v.n) then
        (move_node m.setnode constrained_moves;
         add_worklist u;
         add_worklist v)
      else if (u.setnode.dll == precolored && List.for_all (fun t -> ok t u) (adjacent v)) ||
              (u.setnode.dll != precolored && conservative (Cset.union (Cset.of_list (adjacent u)) (Cset.of_list (adjacent v)))) then
        (move_node m.setnode coalesced_moves;
         combine u v;
         add_worklist u)
      else
        move_node m.setnode active_moves in

  let freeze_moves u =
    List.iter
      (fun move ->
         let v = if get_alias u == get_alias move.dst then get_alias move.src else get_alias move.dst in
           move_node move.setnode frozen_moves;
           if not (move_related v) && degree.(v.n) < k then
             move_node v.setnode simplify_worklist)
      (node_moves u) in

  let freeze () =
    let u :: _ = dll2list freeze_worklist in
      move_node u.setnode simplify_worklist;
      freeze_moves u in

  let select_spill () =
    let cost cnode = spill_cost cnode.inode in
    let m :: _ = List.sort (fun u v -> cost u - cost v) (dll2list spill_worklist) in
      move_node m.setnode simplify_worklist;
      freeze_moves m in

  let assign_colors () =
    List.iter
      (fun cnode ->
         let ok_colors' =
           Cset.fold
             (fun adj ok_colors ->
                let adj' = get_alias adj in
                  if adj'.setnode.dll == colored_nodes ||
                     adj'.setnode.dll == precolored then
                    Rset.remove (Option.get color.(adj'.n)) ok_colors
                  else
                    ok_colors)
             adj_list.(cnode.n) 
             (Rset.of_list registers) in
           if Rset.is_empty ok_colors' then
             move_node cnode.setnode spilled_nodes
           else
             begin
               move_node cnode.setnode colored_nodes;
               color.(cnode.n) <- Some (Rset.choose ok_colors')
             end)
      (List.rev (dll2list select_stack));
    List.iter
      (fun cnode ->
         let alias = get_alias cnode in
           color.(cnode.n) <- color.(alias.n))
      (dll2list coalesced_nodes) in

    build ();
    make_worklist ();

    while (dll2list simplify_worklist) <> [] ||
          (dll2list worklist_moves) <> [] ||
          (dll2list freeze_worklist) <> [] ||
          (dll2list spill_worklist) <> [] do
      if (dll2list simplify_worklist) <> [] then simplify ()
      else if (dll2list worklist_moves) <> [] then coalesce ()
      else if (dll2list freeze_worklist) <> [] then freeze ()
      else if (dll2list spill_worklist) <> [] then select_spill ()
    done;

    assign_colors ();

    let allocation' =
      List.fold_left
        (fun alloc cnode ->
           let color = color.(cnode.n) in
             match color with
               Some c ->
                 let t = gtemp cnode.inode in
                   Temp.Table.add t c alloc
             | None ->
                 allocation)
        allocation
        (dll2list colored_nodes @ dll2list coalesced_nodes) in
    let spilled = List.map (fun cnode -> gtemp cnode.inode) (dll2list spilled_nodes) in
      (allocation', spilled)
