(* 
 * Program Repair Prototype (v2) 
 *
 * Program Representation: 
 *  CIL, but stored as "patches against the original" rather than
 *  "AST containing all changes". The "history" state variable
 *  is used to track edits so far.
 *
 *)
open Printf
open Global
open Cil
open Cilrep
open Rep
open Pretty

(*************************************************************************
 *************************************************************************
                         CIL Patch Representation 
 *************************************************************************
 *************************************************************************)

(* This global variable stores the original Cil AST against which all
 * others are compared. *) 

class cilPatchRep = object (self : 'self_type)
  inherit [cilRep_atom] faultlocRepresentation as faultlocSuper
  inherit cilRep as super

  method get_base () = 
    assert(not (StringMap.is_empty !global_cilRep_code_bank));
    !global_cilRep_code_bank

  (* 
   * The heart of cilPatchRep -- to print out this variant, we print
   * out the original, *but*, if we encounter a statement that
   * has been changed (say, deleted), we print that statement out
   * differently. 
   *
   * This is implemented via a "transform" function that is applied,
   * by the Printer, to every statement just before it is printed.
   * We either replace that statement with something new (e.g., if
   * we've Deleted it, we replace it with an empty block) or leave
   * it unchanged.
   *) 
  method internal_calculate_output_xform () = begin 

    (* Because the transform is called on every statement, and "no change"
     * is the common case, we want this lookup to be fast. We'll use
     * a hash table on statement ids for now -- we can go to an IntSet
     * later.. *) 
    let relevant_targets = Hashtbl.create 255 in 
    let edit_history = self#get_history () in 
    (* Go through the history and find all statements that are changed. *) 
    List.iter (fun h -> match h with 
      | Delete(x) 
      | Append(x,_) 
      | Put(x,_) 
      | Replace_Subatom(x,_,_) 
      -> Hashtbl.replace relevant_targets x true 
      | Swap(x,y) -> 
        Hashtbl.replace relevant_targets x true ;
        Hashtbl.replace relevant_targets y true ;
      | Crossover(_,_) -> 
        abort "cilPatchRep: Crossover not supported\n" 
    ) edit_history ; 

    (* As found by Mike Dewey-Vogt, suppose
     * /* S1 == */ if (p) { foo(); } else { /* S5 */ bar(); } 
     * ... and we try "append S1 after S5". We'll keep finding new
     * instances of S5, which might make an infinite loop. So we only
     * want to apply each operation once. We keep track of remaining
     * operations in a list (since the expected number of operations is
     * under 50). 
     *)
    let edits_remaining = ref edit_history in 

    (* Now we build up the actual transform function. *) 
    let the_xform stmt = 
      let this_id = stmt.sid in 
      (* Most statement will not be in the hashtbl. *)  

      if Hashtbl.mem relevant_targets this_id then begin

        (* For Append or Swap we may need to look the source up 
         * in the "code bank". *) 
        let lookup_stmt src_sid =  
          let f,statement_kind = 
            try self#get_stmt src_sid 
            with _ -> (abort "cilPatchRep: %d not found in stmt_map\n" 
                       src_sid) 
          in statement_kind
        in 

        (* If the history is [e1;e2], then e1 was applied first, followed by
         * e2. So if e1 is a delete for stmt S and e2 appends S2 after S1, 
         * we should end up with the empty block with S2 appended. So, in
         * essence, we need to appliy the edits "in order". *) 
        List.fold_left (fun accumulated_stmt this_edit -> 
          let used_this_edit, resulting_statement = match this_edit with
          (* The code for each operation is taken from Cilrep.ml's
           * various visitors. *) 

          | Put(x,atom) when x = this_id -> begin
            match atom with
            | Stmt(skind) -> true, 
            { accumulated_stmt with skind = copy skind ;
                 labels = possibly_label accumulated_stmt "put" x ; } 
            | Exp(exp) -> 
              abort "cilPatchRep: Put Exp not supported\n" 
          end 
          | Replace_Subatom(x,subatom_id,atom) when x = this_id -> 
            abort "cilPatchRep: Replace_Subatom not supported\n" 
          | Swap(x,y) when x = this_id -> 
            let what_to_swap = lookup_stmt y in 
            true, 
              { accumulated_stmt with skind = copy what_to_swap ;
                 labels = possibly_label accumulated_stmt "swap1" y ; } 
          | Swap(y,x) when x = this_id -> 
            let what_to_swap = lookup_stmt y in 
            true, 
            { accumulated_stmt with skind = copy what_to_swap ;
                 labels = possibly_label accumulated_stmt "swap2" y ; } 

          | Delete(x) when x = this_id -> 
            let block = { battrs = [] ; bstmts = [] ; } in
            true, 
            { accumulated_stmt with skind = Block block ; 
                 labels = possibly_label accumulated_stmt "del" x; } 
          | Append(x,y) when x = this_id -> 
            let s' = { accumulated_stmt with sid = 0 } in 
            let what_to_append = lookup_stmt y in 
            let copy = 
              (visitCilStmt my_zero (mkStmt (copy what_to_append))).skind in 
            let block = {
              battrs = [] ;
              bstmts = [s' ; { s' with skind = copy } ] ; 
            } in
            true, 
            { accumulated_stmt with skind = Block(block) ; 
                     labels = possibly_label accumulated_stmt "app" y ; } 

          (* Otherwise, this edit does not apply to this statement. *) 
          | _ -> false, accumulated_stmt
          in 
          if used_this_edit then begin 
            edits_remaining := List.filter (fun x -> x <> this_edit)
              !edits_remaining  
          end ; 
          resulting_statement
        ) stmt !edits_remaining 
      end else stmt 
    in 
    the_xform 
  end 

  method internal_compute_source_buffers () = 
    let output_list = ref [] in 
    let make_name n = if !multi_file then Some(n) else None in
    let xform = self#internal_calculate_output_xform () in 
    let base = self#get_base () in
    StringMap.iter (fun (fname:string) (cil_file:Cil.file) ->
      let source_string = output_cil_file_to_string ~xform cil_file in
      output_list := (make_name fname,source_string) :: !output_list 
    ) base ; 
	  assert((llen !output_list) > 0);
	  !output_list

  method delete stmt_id = faultlocSuper#delete stmt_id 
  method append stmt_id = faultlocSuper#append stmt_id 
  method swap stmt_id1 stmt_id2 = faultlocSuper#swap stmt_id1 stmt_id2 
  method put stmt_id stmt = faultlocSuper#put stmt_id stmt 
  method replace_subatom stmt_id subatom_id atom = 
    faultlocSuper#note_replaced_subatom stmt_id subatom_id atom 

  (* The "get" method's return value is based on the 'current', 'actual'
   * content of the variant and not the 'code bank'. 
   * 
   * So we get the 'original' answer and then apply all relevant edits that
   * have happened since then. *) 
  method get stmt_id = 
    let xform = self#internal_calculate_output_xform () in 
    match super#get stmt_id with
    | Stmt(skind) -> 
      let stmt = Cil.mkStmt skind in
      stmt.sid <- stmt_id ; 
      let post_edit_stmt = xform stmt in 
      (Stmt(post_edit_stmt.skind))
    | Exp(exp) -> 
      abort "cilPatchRep: get %d returned Exp" stmt_id 

  method set_history new_history = 
    history := new_history 

end