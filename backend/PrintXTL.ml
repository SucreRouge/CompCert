(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Pretty-printer for XTL *)

open Format
open Camlcoq
open Datatypes
open Maps
open AST
open Registers
open Op
open Locations
open PrintAST
open PrintOp
open XTL

let mreg pp r =
  match Machregsaux.name_of_register r with
  | Some s -> fprintf pp "%s" s
  | None -> fprintf pp "<unknown machreg>"

let short_name_of_type = function Tint -> 'i' | Tfloat -> 'f' | Tlong -> 'l'

let loc pp = function
  | R r -> mreg pp r
  | S(Local, ofs, ty) ->
      fprintf pp "L%c%ld" (short_name_of_type ty) (camlint_of_coqint ofs)
  | S(Incoming, ofs, ty) ->
      fprintf pp "I%c%ld" (short_name_of_type ty) (camlint_of_coqint ofs)
  | S(Outgoing, ofs, ty) ->
      fprintf pp "O%c%ld" (short_name_of_type ty) (camlint_of_coqint ofs)

let current_alloc = ref (None: (var -> loc) option)
let current_liveness = ref (None: VSet.t PMap.t option)

let reg pp r ty =
  match !current_alloc with
  | None -> fprintf pp "x%ld" (P.to_int32 r)
  | Some alloc -> fprintf pp "x%ld{%a}" (P.to_int32 r) loc (alloc (V(r, ty)))

let var pp = function
  | V(r, ty) -> reg pp r ty
  | L l -> loc pp l

let rec vars pp = function
  | [] -> ()
  | [r] -> var pp r
  | r1::rl -> fprintf pp "%a, %a" var r1 vars rl

let ros pp = function
  | Coq_inl r -> var pp r
  | Coq_inr s -> fprintf pp "\"%s\"" (extern_atom s)

let liveset pp lv =
  fprintf pp "@[<hov 2>{";
  VSet.iter (function V(r, ty) -> fprintf pp "@ x%ld" (P.to_int32 r)
                    | L l -> ())
    lv;                  
  fprintf pp " }@]"

let print_succ pp s dfl =
  let s = P.to_int32 s in
  if s <> dfl then fprintf pp "goto %ld" s

let print_instruction pp succ = function
  | Xmove(src, dst) ->
      fprintf pp "%a = %a;" var dst var src
  | Xreload(src, dst) ->
      fprintf pp "%a =r %a;" var dst var src
  | Xspill(src, dst) ->
      fprintf pp "%a =s %a;" var dst var src
  | Xparmove(srcs, dsts, t1, t2) ->
      fprintf pp "(%a) = (%a) using %a, %a;" vars dsts vars srcs var t1 var t2
  | Xop(op, args, res) ->
      fprintf pp "%a = %a;" var res (print_operation var) (op, args)
  | Xload(chunk, addr, args, dst) ->
      fprintf pp "%a = %s[%a];"
         var dst (name_of_chunk chunk) (print_addressing var) (addr, args)
  | Xstore(chunk, addr, args, src) ->
      fprintf pp "%s[%a] = %a;"
         (name_of_chunk chunk) (print_addressing var) (addr, args) var src
  | Xcall(sg, fn, args, res) ->
      fprintf pp "%a = call %a(%a);" vars res ros fn vars args
  | Xtailcall(sg, fn, args) ->
      fprintf pp "tailcall %a(%a);" ros fn vars args
  | Xbuiltin(ef, args, res) ->
      fprintf pp "%a = builtin %s(%a);"
        vars res (name_of_external ef) vars args
  | Xbranch s ->
      print_succ pp s succ
  | Xcond(cond, args, s1, s2) ->
      fprintf pp "if (%a) goto %ld else goto %ld"
        (print_condition var) (cond, args)
        (P.to_int32 s1) (P.to_int32 s2)
  | Xjumptable(arg, tbl) ->
      let tbl = Array.of_list tbl in
      fprintf pp "@[<v 2>jumptable (%a)" var arg;
      for i = 0 to Array.length tbl - 1 do
        fprintf pp "@ case %d: goto %ld" i (P.to_int32 tbl.(i))
      done;
      fprintf pp "@]"
  | Xreturn args ->
      fprintf pp "return %a" vars args

let rec print_instructions pp succ = function
  | [] -> ()
  | [i] -> print_instruction pp succ i
  | i :: il ->
      print_instruction pp succ i;
      fprintf pp "@ ";
      print_instructions pp succ il

let print_block pp (pc, blk) =
  fprintf pp "%5ld: @[<hov 0>" pc;
  print_instructions pp (Int32.pred pc) blk;
  fprintf pp "@]@ ";
  match !current_liveness with
  | None -> ()
  | Some liveness -> fprintf pp "%a@ " liveset (PMap.get (P.of_int32 pc) liveness)

let print_function pp ?alloc ?live f =
  current_alloc := alloc;
  current_liveness := live;
  fprintf pp "@[<v 2>f() {@ ";
  let instrs =
    List.sort
      (fun (pc1, _) (pc2, _) -> Pervasives.compare pc2 pc1)
      (List.map
        (fun (pc, i) -> (P.to_int32 pc, i))
        (PTree.elements f.fn_code)) in
  print_succ pp f.fn_entrypoint 
    (match instrs with (pc1, _) :: _ -> pc1 | [] -> -1l);
  List.iter (print_block pp) instrs;
  fprintf pp "@;<0 -2>}@]@.";
  current_alloc := None;
  current_liveness := None
