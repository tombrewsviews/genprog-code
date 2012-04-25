(*
 *
 * Copyright (c) 2001-2002, 
 *  George C. Necula    <necula@cs.berkeley.edu>
 *  Scott McPeak        <smcpeak@cs.berkeley.edu>
 *  Wes Weimer          <weimer@cs.berkeley.edu>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 * IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)

(* cabsvisit.ml *)
(* tree visitor and rewriter for cabs *)

open Cabs
open Cabshelper
open Trace
open Pretty
module E = Errormsg

(* basic interface for a visitor object *)

(* Different visiting actions. 'a will be instantiated with exp, instr, etc. *)
type 'a visitAction = 
    SkipChildren                        (* Do not visit the children. Return 
                                         * the node as it is *)
  | ChangeTo of 'a                      (* Replace the expression with the 
                                         * given one *)
  | DoChildren                          (* Continue with the children of this 
                                         * node. Rebuild the node on return 
                                         * if any of the children changes 
                                         * (use == test) *)
  | ChangeDoChildrenPost of 'a * ('a -> 'a) (* First consider that the entire 
                                          * exp is replaced by the first 
                                          * paramenter. Then continue with 
                                          * the children. On return rebuild 
                                          * the node if any of the children 
                                          * has changed and then apply the 
                                          * function on the node *)

type nameKind = 
    NVar                                (* Variable or function prototype 
                                           name *)
  | NFun                                (* A function definition name *)
  | NField                              (* The name of a field *)
  | NType                               (* The name of a type *)

(* All visit methods are called in preorder! (but you can use 
 * ChangeDoChildrenPost to change the order) *)
class type cabsVisitor = object
  method vexpr: expression node -> expression node visitAction   (* expressions *)
  method vinitexpr: init_expression -> init_expression visitAction   
  method vstmt: statement node -> statement node list visitAction
  method vblock: block -> block visitAction
  method vvar: string -> string                  (* use of a variable names *)
                                                        
  method vdef: definition node -> definition node list visitAction
  method vtypespec: typeSpecifier -> typeSpecifier visitAction
  method vdecltype: decl_type -> decl_type visitAction

      (* For each declaration we call vname *)
  method vname: nameKind -> specifier -> name -> name visitAction
  method vspec: specifier -> specifier visitAction     (* specifier *)
  method vattr: attribute -> attribute list visitAction
  method vdirective : directive node -> directive node visitAction
  method vmacro : macro -> macro visitAction

  method vEnterScope: unit -> unit
  method vExitScope: unit -> unit

  (* added for Diffs *)
  method vtree: tree_node node list -> tree_node node list visitAction
  method vtreenode: tree_node node -> tree_node node visitAction
end
    
let visitorLocation = ref { filename = ""; 
							lineno = -1; 
							byteno = -1;
                            ident = 0}
    
        (* a default visitor which does nothing to the tree *)

class nopCabsVisitor : cabsVisitor = object
  method vexpr (e:expression node) = DoChildren
  method vinitexpr (e:init_expression) = DoChildren
  method vstmt (s: statement node) = 
    visitorLocation := get_statementloc (dn s);
    DoChildren
  method vblock (b: block) = DoChildren
  method vvar (s: string) = s
  method vdef (d: definition node) = 
    visitorLocation := get_definitionloc (dn d);
    DoChildren
  method vtypespec (ts: typeSpecifier) = DoChildren
  method vdecltype (dt: decl_type) = DoChildren
  method vname k (s:specifier) (n: name) = DoChildren
  method vspec (s:specifier) = DoChildren
  method vattr (a: attribute) = DoChildren
  method vdirective (d : directive node) = DoChildren
  method vmacro (m : macro) = DoChildren
      
  method vEnterScope () = ()
  method vExitScope () = ()

  method vtree t = DoChildren
  method vtreenode tn = DoChildren
end
        
        (* Map but try not to copy the list unless necessary *)
let rec mapNoCopy (f: 'a -> 'a) = function
    [] -> []
  | (i :: resti) as li -> 
      let i' = f i in
      let resti' = mapNoCopy f resti in
      if i' != i || resti' != resti then i' :: resti' else li 
        
let rec mapNoCopyList (f: 'a -> 'a list) = function
    [] -> []
  | (i :: resti) as li -> 
      let il' = f i in
      let resti' = mapNoCopyList f resti in
      match il' with
        [i'] when i' == i && resti' == resti -> li
      | _ -> il' @ resti'
                     
let doVisit (vis: cabsVisitor)
    (startvisit: 'a -> 'a visitAction) 
    (children: cabsVisitor -> 'a -> 'a) 
    (node: 'a) : 'a = 
  let action = startvisit node in
  match action with
    SkipChildren -> node
  | ChangeTo node' -> node'
  | _ ->  
      let nodepre = match action with
        ChangeDoChildrenPost (node', _) -> node'
      | _ -> node
      in
      let nodepost = children vis nodepre in
      match action with
        ChangeDoChildrenPost (_, f) -> f nodepost
      | _ -> nodepost
            
(* A visitor for lists *)
let doVisitList (vis: cabsVisitor)
                (startvisit: 'a -> 'a list visitAction)
                (children: cabsVisitor -> 'a -> 'a)
                (node: 'a) : 'a list = 
  let action = startvisit node in
  match action with
    SkipChildren -> [node]
  | ChangeTo nodes' -> nodes'
  | _ -> 
      let nodespre = match action with
        ChangeDoChildrenPost (nodespre, _) -> nodespre
      | _ -> [node]
      in
      let nodespost = mapNoCopy (children vis) nodespre in
      match action with
        ChangeDoChildrenPost (_, f) -> f nodespost
      | _ -> nodespost

            
let rec visitCabsTypeSpecifier (vis: cabsVisitor) (ts: typeSpecifier) = 
  doVisit vis vis#vtypespec childrenTypeSpecifier ts
    
and childrenTypeSpecifier vis ts = begin
  let childrenFieldGroup (input : field_group) : field_group  = 
	let (s, nel) = input in
    let s' = visitCabsSpecifier vis s in
    let doOneField (input : name * expression node option) =
	  let (n, eo) = input in
	  let n' = visitCabsName vis NField s' n in
	  let eo' = 
        match eo with
		  None -> None
        | Some e -> let e' = visitCabsExpression vis e in
			(if e' != e then e.node <- e'.node); eo
	  in
		if n' != n || eo' != eo then (n', eo') else input
    in
    let nel' = mapNoCopy doOneField nel in
	  if s' != s || nel' != nel then (s', nel') else input
  in
	match ts with
	  Tstruct (n, Some fg, extraAttrs) ->
		(*(trace "sm" (dprintf "visiting struct %s\n" n));*)
		let fg' = mapNoCopy childrenFieldGroup fg in
		  if fg' != fg then Tstruct( n, Some fg', extraAttrs) else ts
	| Tunion (n, Some fg, extraAttrs) ->
		let fg' = mapNoCopy childrenFieldGroup fg in
		  if fg' != fg then Tunion( n, Some fg', extraAttrs) else ts
	| Tenum (n, Some ei, extraAttrs) ->
		let doOneEnumItem ei =
		  let (s,e,loc) = ei in
		  let e' = visitCabsExpression vis e in
			if e' != e then (s, e', loc) else ei
		in
		  vis#vEnterScope ();
		  let ei' = mapNoCopy doOneEnumItem ei in
			vis#vExitScope();
			if ei' != ei then Tenum( n, Some ei', extraAttrs) else ts
	| TtypeofE e ->
		let e' = visitCabsExpression vis e in   
		  if e' != e then TtypeofE e' else ts
	| TtypeofT (s, dt) -> 
		let s' = visitCabsSpecifier vis s in
		let dt' = visitCabsDeclType vis false dt in
		  if s != s' || dt != dt' then TtypeofT (s', dt') else ts
	| _ -> ts
end         
and childrenSpecElem (vis: cabsVisitor) (se: spec_elem) : spec_elem = 
  match se with
    SpecTypedef | SpecInline | SpecStorage _ | SpecPattern _ -> se
  | SpecCV _ -> se    (* cop out *)
  | SpecAttr a -> begin
	  let al' = visitCabsAttribute vis a in
		match al' with
		  [a''] when a'' == a -> se
		| [a''] ->  SpecAttr a''
		| _ -> E.s (E.unimp "childrenSpecElem: visitCabsAttribute returned a list")
	end
  | SpecType ts -> 
	  let ts' = visitCabsTypeSpecifier vis ts in
		if ts' != ts then SpecType ts' else se
		  
and visitCabsSpecifier (vis: cabsVisitor) (s: specifier) : specifier = 
  doVisit vis vis#vspec childrenSpec s

and childrenSpec (vis : cabsVisitor) (s : specifier) =  mapNoCopy (childrenSpecElem vis) s

and visitCabsDeclType (vis : cabsVisitor) (isfundef: bool) (dt: decl_type) : decl_type = 
  doVisit vis vis#vdecltype (childrenDeclType isfundef) dt
and childrenDeclType isfundef vis dt = 
  match dt with
    JUSTBASE -> dt
  | PARENTYPE (prea, dt1, posta) -> 
	  let prea' = mapNoCopyList (visitCabsAttribute vis)  prea in
	  let dt1' = visitCabsDeclType vis isfundef dt1 in
	  let posta'= mapNoCopyList (visitCabsAttribute vis)  posta in
		if prea' != prea || dt1' != dt1 || posta' != posta then 
		   PARENTYPE (prea', dt1', posta') else dt
  | ARRAY (dt1, al, e) -> 
	  let dt1' = visitCabsDeclType vis isfundef dt1 in
	  let al' = mapNoCopy (childrenAttribute vis) al in
	  let e'= visitCabsExpression vis e in
		if dt1' != dt1 || al' != al || e' != e then ARRAY(dt1', al', e') else dt
  | PTR (al, dt1) -> 
	  let al' = mapNoCopy (childrenAttribute vis) al in
	  let dt1' = visitCabsDeclType vis isfundef dt1 in
		if al' != al || dt1' != dt1 then PTR(al', dt1') else dt
  | PROTO (dt1, snl, b) ->
	  (* Do not propagate isfundef further *)
	  let dt1' = visitCabsDeclType vis false dt1 in
	  let _ = vis#vEnterScope () in
	  let snl' = mapNoCopy (childrenSingleName vis NVar) snl in
		(* Exit the scope only if not in a function definition *)
	  let _ = if not isfundef then vis#vExitScope () in
		if dt1' != dt1 || snl' != snl then PROTO(dt1', snl', b) else dt
		  

and childrenNameGroup vis (kind: nameKind) input = 
  let (s,nl) = input in
  let s' = visitCabsSpecifier vis s in
  let nl' = mapNoCopy (visitCabsName vis kind s') nl in
	if s' != s || nl' != nl then (s', nl') else input
	  
and childrenInitNameGroup vis ((s, inl) as input) = 
  let s' = visitCabsSpecifier vis s in
  let inl' = mapNoCopy (childrenInitName vis s') inl in
	if s' != s || inl' != inl then (s', inl') else input
	  
and visitCabsName vis (k: nameKind) (s: specifier) (n: name) : name = 
  doVisit vis (vis#vname k s) (childrenName s k) n

and childrenName (s: specifier) (k: nameKind) vis (n: name) : name = 
  let (sn, dt, al, loc) = n in
  let dt' = visitCabsDeclType vis (k = NFun) dt in
  let al' = mapNoCopy (childrenAttribute vis) al in
	if dt' != dt || al' != al then (sn, dt', al', loc) else n
	  
and childrenInitName vis (s: specifier) (inn: init_name) : init_name = 
  let (n, ie) = inn in
  let n' = visitCabsName vis NVar s n in
  let ie' = visitCabsInitExpression vis ie in
	if n' != n || ie' != ie then (n', ie') else inn
	  
and childrenSingleName vis (k: nameKind) (sn: single_name) : single_name =
  let s, n = sn in
  let s' = visitCabsSpecifier vis s in
  let n' = visitCabsName vis k s' n in
	if s' != s || n' != n then (s', n') else sn
	  
and visitCabsDefinition vis (d: definition node) : definition node list = 
  doVisitList vis vis#vdef childrenDefinition d

and childrenDefinition vis d = 
  match (dn d) with 
  | DIRECTIVE(dn) -> d (* FIXME *)
  | FUNDEF (sn, b, l, lend) -> 
	  let sn' = childrenSingleName vis NFun sn in
	  let b' = visitCabsBlock vis b in
		(* End the scope that was started by childrenFunctionName *)
		vis#vExitScope ();
		if sn' != sn || b' != b then d.node <- NODE(FUNDEF (sn', b', l, lend)); d
		  
  | DECDEF (group, l) -> 
	  let s,inl = group in
	  let s' = visitCabsSpecifier vis s in
	  let inl' = mapNoCopy (childrenInitName vis s') inl in
		if s' != s || inl' != inl then d.node <- NODE(DECDEF ((s',inl'), l)); d
  | TYPEDEF (ng, l) -> 
	  let ng' = childrenNameGroup vis NType ng in
		if ng' != ng then d.node <- NODE(TYPEDEF (ng', l)); d
  | ONLYTYPEDEF (s, l) -> 
	  let s' = visitCabsSpecifier vis s in
		if s' != s then d.node <- NODE(ONLYTYPEDEF (s', l)); d
  | GLOBASM _ -> d
  | PRAGMA (e, l) -> 
	  let e' = visitCabsExpression vis e in
		if e' != e then d.node <- NODE(PRAGMA (e', l)); d
  | LINKAGE (n, l, dl) -> 
	  let dl' = mapNoCopyList (visitCabsDefinition vis) dl in
		if dl' != dl then d.node <- NODE(LINKAGE (n, l, dl')); d
          
and visitCabsBlock vis (b: block) : block =
  doVisit vis vis#vblock childrenBlock b

and childrenBlock vis (b: block) : block = 
  let _ = vis#vEnterScope () in
  let battrs' = mapNoCopyList (visitCabsAttribute vis) b.battrs in
  let bstmts' = mapNoCopyList (visitCabsStatement vis) b.bstmts in
  let _ = vis#vExitScope () in
	if battrs' != b.battrs || bstmts' != b.bstmts then 
	  { blabels = b.blabels; battrs = battrs'; bstmts = bstmts' } else
    b
	  
and visitCabsStatement vis (s: statement node) : statement node list = 
  doVisitList vis vis#vstmt childrenStatement s

and childrenStatement vis s = 
  let ve e = visitCabsExpression vis e in
  let vs l s = 
    match (visitCabsStatement vis s) with
	  [s'] -> s.node <- s'.node; s
    | sl -> s.node <- NODE(BLOCK ({blabels = []; battrs = []; bstmts = sl }, l)); s
  in
	match (dn s) with
	  NOP _ -> s
	| STMTDIRECTIVE _ -> s
	| COMPUTATION (e, l) ->
		let e' = ve e in
		  if e' != e then s.node <- NODE(COMPUTATION (e', l)); s
	| BLOCK (b, l) -> 
		let b' = visitCabsBlock vis b in
		  if b' != b then s.node <- NODE(BLOCK (b', l)); s
	| SEQUENCE (s1, s2, l) -> 
		let s1' = vs l s1 in
		let s2' = vs l s2 in
		  if s1' != s1 || s2' != s2 then s.node <- NODE(SEQUENCE (s1', s2', l)); s
	| IF (e, s1, s2, l) -> 
		let e' = ve e in
		let s1' = vs l s1 in
		let s2' = vs l s2 in
		  if e' != e || s1' != s1 || s2' != s2 then s.node <- NODE(IF (e', s1', s2', l)); s
	| WHILE (e, s1, l) -> 
		let e' = ve e in
		let s1' = vs l s1 in
		  if e' != e || s1' != s1 then s.node <- NODE(WHILE (e', s1', l)); s
	| DOWHILE (e, s1, l) -> 
		let e' = ve e in
		let s1' = vs l s1 in
		  if e' != e || s1' != s1 then s.node <- NODE(DOWHILE (e', s1', l)); s
	| FOR (fc1, e2, e3, s4, l) -> 
		let _ = vis#vEnterScope () in
		let fc1' = 
		  match fc1 with
			FC_EXP e1 -> 
			  let e1' = ve e1 in
				if e1' != e1 then FC_EXP e1' else fc1
		  | FC_DECL d1 -> 
			  let d1' = 
				match visitCabsDefinition vis d1 with
				  [d1'] -> d1'
				| _ -> E.s (E.unimp "visitCabs: for can have only one definition")
			  in
				if d1' != d1 then FC_DECL d1' else fc1
		in
		let e2' = ve e2 in
		let e3' = ve e3 in
		let s4' = vs l s4 in
		let _ = vis#vExitScope () in
		  if fc1' != fc1 || e2' != e2 || e3' != e3 || s4' != s4 
		  then s.node <- NODE(FOR (fc1', e2', e3', s4', l)); s
	| BREAK _ | CONTINUE _ | GOTO _ -> s
	| RETURN (e, l) ->
		let e' = ve e in
		  if e' != e then s.node <- NODE(RETURN (e', l)); s
	| SWITCH (e, s1, l) -> 
		let e' = ve e in
		let s1' = vs l s1 in
		  if e' != e || s1' != s1 then s.node <- NODE(SWITCH (e', s1', l)); s
	| CASE (e, s1, l) -> 
		let e' = ve e in
		let s1' = vs l s1 in
		  if e' != e || s1' != s1 then s.node <- NODE(CASE (e', s1', l)); s
	| CASERANGE (e1, e2, s3, l) -> 
		let e1' = ve e1 in
		let e2' = ve e2 in
		let s3' = vs l s3 in
		  if e1' != e1 || e2' != e2 || s3' != s3 then 
			s.node <- NODE(CASERANGE (e1', e2', s3', l)); s
	| DEFAULT (s1, l) ->
		let s1' = vs l s1 in
		  if s1' != s1 then s.node <- NODE(DEFAULT (s1', l)); s
	| LABEL (n, s1, l) ->
		let s1' = vs l s1 in
		  if s1' != s1 then s.node <- NODE(LABEL (n, s1', l)); s
	| COMPGOTO (e, l) -> 
		let e' = ve e in
		  if e' != e then s.node <- NODE(COMPGOTO (e', l)); s
	| DEFINITION d -> begin
		match visitCabsDefinition vis d with
		  [d'] when d' == d -> s
        | [d'] -> s.node <- NODE(DEFINITION d'); s
        | dl -> let l = get_definitionloc (dn d) in (* FIXME: the latter may be wrong *)
		  let dl' = List.map (fun d' -> {node = NODE(DEFINITION d'); id = d'.id; typelabel = d'.typelabel; tl_str = d'.tl_str}) dl in (* FIXME *)
			s.node <- NODE(BLOCK ({blabels = []; battrs = []; bstmts = dl' }, l)); s
	  end
	| ASM (sl, b, details, l) -> 
		let childrenIdentStringExp ((i,s, e) as input) = 
		  let e' = ve e in
			if e' != e then (i,s, e') else input
		in
		let details' = match details with
		  | None -> details
		  | Some det ->
			  let { aoutputs = outl; ainputs = inl; aclobbers = clobs } = det in
			  let outl' = mapNoCopy childrenIdentStringExp outl in
			  let inl' = mapNoCopy childrenIdentStringExp inl in
				if outl' == outl && inl' == inl then
				  details
				else
				  Some ({ aoutputs = outl'; ainputs = inl'; aclobbers = clobs })
		in
		  if details' != details then 
			s.node <- NODE(ASM (sl, b, details', l)); s
	| TRY_FINALLY (b1, b2, l) -> 
		let b1' = visitCabsBlock vis b1 in
		let b2' = visitCabsBlock vis b2 in
		  if b1' != b1 || b2' != b2 then s.node <- NODE(TRY_FINALLY(b1', b2', l)); s
	| TRY_EXCEPT (b1, e, b2, l) -> 
		let b1' = visitCabsBlock vis b1 in
		let e' = visitCabsExpression vis e in
		let b2' = visitCabsBlock vis b2 in
		  if b1' != b1 || e' != e || b2' != b2 then s.node <- NODE(TRY_EXCEPT(b1', e', b2', l)); s
			
			
and visitCabsExpression vis (e: expression node) : expression node = 
  doVisit vis vis#vexpr childrenExpression e

and childrenExpression vis e = 
  let ve e = visitCabsExpression vis e in
	match (dn e) with 
	  NOTHING | EXPDIRECTIVE _ | LABELADDR _ -> e
	| UNARY (uo, e1) -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(UNARY (uo, e1')); e
	| BINARY (bo, e1, e2) -> 
		let e1' = ve e1 in
		let e2' = ve e2 in
		  if e1' != e1 || e2' != e2 then e.node <- NODE(BINARY (bo, e1', e2')); e
	| QUESTION (e1, e2, e3) -> 
		let e1' = ve e1 in
		let e2' = ve e2 in
		let e3' = ve e3 in
		  if e1' != e1 || e2' != e2 || e3' != e3 then 
			e.node <- NODE(QUESTION (e1', e2', e3')); e
	| CAST ((s, dt), ie) -> 
		let s' = visitCabsSpecifier vis s in
		let dt' = visitCabsDeclType vis false dt in
		let ie' = visitCabsInitExpression vis ie in
		  if s' != s || dt' != dt || ie' != ie then e.node <- NODE(CAST ((s', dt'), ie')); e
	| CALL (f, el) -> 
		let f' = ve f in
		let el' = mapNoCopy ve el in
		  if f' != f || el' != el then e.node <- NODE(CALL (f', el')); e
	| COMMA el -> 
		let el' = mapNoCopy ve el in
		  if el' != el then e.node <- NODE(COMMA (el')); e
	| CONSTANT _ -> e
	| PAREN e1 -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(PAREN (e1')); e 
	| VARIABLE s -> 
		let s' = vis#vvar s in
		  if s' != s then e.node <- NODE(VARIABLE s'); e
	| EXPR_SIZEOF (e1) -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(EXPR_SIZEOF (e1')); e
	| TYPE_SIZEOF (s, dt) -> 
		let s' = visitCabsSpecifier vis s in
		let dt' = visitCabsDeclType vis false dt in
		  if s' != s || dt' != dt then e.node <- NODE(TYPE_SIZEOF (s' ,dt')); e
	| EXPR_ALIGNOF (e1) -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(EXPR_ALIGNOF (e1')); e
	| TYPE_ALIGNOF (s, dt) -> 
		let s' = visitCabsSpecifier vis s in
		let dt' = visitCabsDeclType vis false dt in
		  if s' != s || dt' != dt then e.node <- NODE(TYPE_ALIGNOF (s' ,dt')); e
	| INDEX (e1, e2) -> 
		let e1' = ve e1 in
		let e2' = ve e2 in
		  if e1' != e1 || e2' != e2 then e.node <- NODE(INDEX (e1', e2')); e
	| MEMBEROF (e1, n) -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(MEMBEROF (e1', n)); e
	| MEMBEROFPTR (e1, n) -> 
		let e1' = ve e1 in
		  if e1' != e1 then e.node <- NODE(MEMBEROFPTR (e1', n)); e
	| GNU_BODY b -> 
		let b' = visitCabsBlock vis b in
		  if b' != b then e.node <- NODE(GNU_BODY b'); e
	| EXPR_PATTERN _ -> e
        
and visitCabsInitExpression vis (ie: init_expression) : init_expression = 
  doVisit vis vis#vinitexpr childrenInitExpression ie

and childrenInitExpression vis ie = 
  let rec childrenInitWhat iw = 
    match iw with
	  NEXT_INIT -> iw
    | INFIELD_INIT (n, iw1) -> 
        let iw1' = childrenInitWhat iw1 in
		  if iw1' != iw1 then INFIELD_INIT (n, iw1') else iw
    | ATINDEX_INIT (e, iw1) -> 
        let e' = visitCabsExpression vis e in
        let iw1' = childrenInitWhat iw1 in
		  if e' != e || iw1' != iw1 then ATINDEX_INIT (e', iw1') else iw
    | ATINDEXRANGE_INIT (e1, e2) -> 
        let e1' = visitCabsExpression vis e1 in
        let e2' = visitCabsExpression vis e2 in
		  if e1' != e1 || e2' != e2 then ATINDEXRANGE_INIT (e1', e2') else iw
  in
	match ie with 
	  NO_INIT -> ie
	| SINGLE_INIT e -> 
		let e' = visitCabsExpression vis e in
		  if e' != e then SINGLE_INIT e' else ie
	| COMPOUND_INIT il -> 
		let childrenOne ((iw, ie) as input) = 
		  let iw' = childrenInitWhat iw in
		  let ie' = visitCabsInitExpression vis ie in
			if iw' != iw || ie' != ie then (iw', ie') else input
		in
		let il' = mapNoCopy childrenOne il in
		  if il' != il then COMPOUND_INIT il' else ie
			

and visitCabsAttribute vis (a: attribute) : attribute list = 
  doVisitList vis vis#vattr childrenAttribute a

and childrenAttribute vis input = 
  let n, el = input in
  let el' = mapNoCopy (visitCabsExpression vis) el in
	if el' != el then (n, el') else input
	  
and visitCabsAttributes vis (al: attribute list) : attribute list = 
  mapNoCopyList (visitCabsAttribute vis) al

and childrenTreeNode vis (tn : tree_node node) : tree_node node = 
  match dn tn with
	Globals(defs) -> {tn with node = NODE(Globals(List.flatten(List.map (fun d -> (visitCabsDefinition vis d)) defs))) }
  | Stmts(s) -> { tn with node = NODE(Stmts(List.flatten(List.map (fun s -> (visitCabsStatement vis s)) s))) }
  | Exps(e) -> { tn with node = NODE(Exps(List.map (fun e -> visitCabsExpression vis e) e)) }

and childrenDirective vis (d : directive node) : directive node = 
  match dn d with
  | PREIF(e1,m1,m2,l) -> {d with node = NODE(PREIF(visitCabsExpression vis e1,
												   visitMacro vis m1, visitMacro vis m2, l)) }
  | PREIFNDEF(e1,m1,m2,l) -> { d with node = NODE(PREIFNDEF(visitCabsExpression vis e1,
												   visitMacro vis m1, visitMacro vis m2, l)) }
  | PREDEFINE(e1,elist,m,l) -> { d with node = NODE(PREDEFINE(visitCabsExpression vis e1,
															 List.map (fun e -> visitCabsExpression vis e) elist,
															 visitMacro vis m, l)) }
  | PREUNDEF(e1,l) -> { d with node = NODE(PREUNDEF(visitCabsExpression vis e1, l)) }
  | MACRO(elist,l) -> { d with node = NODE(MACRO(List.map (fun e -> visitCabsExpression vis e) elist, l)) }
  | _ -> d

and visitCabsFile (vis: cabsVisitor) ((fname, f): file) : file =  
  (fname, mapNoCopyList (visitCabsDefinition vis) f)

and visitDirective (vis : cabsVisitor) (d : directive node ) : directive node = 
  doVisit vis vis#vdirective childrenDirective d

and visitMacro (vis : cabsVisitor) (m : macro) : macro = 
  doVisit vis vis#vmacro childrenMacro m

and childrenMacro vis macro = 
  match macro with
  | MACDIR(d) -> MACDIR(visitDirective vis d)
  | MACSTMT(slist) -> MACSTMT(List.map (visitStatement vis) slist)
  | MACEXP(elist) -> MACEXP(List.map (visitCabsExpression vis) elist)
  | MACDEF(dlist) -> MACDEF(List.flatten (List.map (visitCabsDefinition vis) dlist))
  | MACEMPTY -> MACEMPTY

and visitStatement vis stmt = 
  let rec compose = function 
	| [] -> nd(NOP(cabslu))
	| [stmt] -> stmt
	| ss -> nd(BLOCK({blabels = []; battrs=[]; bstmts=ss},cabslu))
  in
	compose (doVisitList vis vis#vstmt childrenStatement stmt) 

let visitTreeNode vis (tn: tree_node node) : tree_node node =  
  doVisit vis vis#vtreenode childrenTreeNode tn

let visitTree vis ((fname, f): tree) : tree = 
  (fname, (List.map (visitTreeNode vis) f))


