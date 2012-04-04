open Asm
open AST
open BinPos
open ELF_types
open Lens
open Library

type log_entry =
  | DEBUG of string
  | ERROR of string
  | WARNING of string

type byte_chunk_desc =
  | ELF_header
  | ELF_progtab
  | ELF_shtab
  | ELF_section_strtab
  | ELF_symbol_strtab
  | Symtab_data of elf32_sym
  | Symtab_function of elf32_sym
  | Data_symbol of elf32_sym
  | Function_symbol of elf32_sym
  | Zero_symbol
  | Stub of string
  | Jumptable
  | Float_literal of float
  | Padding
  | Unknown of string

(** This framework is carried along while analyzing the whole ELF file.
*)
type e_framework = {
  elf: elf;
  log: log_entry list;
  (** Every time a chunk of the ELF file is checked, it is added to this list.
      The first two fields are the start and stop offsets, the third is an
      alignment constraint, the last is a description. *)
  chkd_bytes_list: (int32 * int32 * int * byte_chunk_desc) list;
  chkd_fun_syms: bool array;
  chkd_data_syms: bool array;
}

module PosOT = struct
  type t = positive
  let compare = Pervasives.compare
end

module PosMap = Map.Make(PosOT)

(** This framework is carried along while analyzing one .sdump file, which
    may contain multiple functions. *)
type s_framework = {
  ef: e_framework;
  program: Asm.program;
  (** Maps every CompCert ident to a string. This will not be the exact name of
      the symbol in the ELF file though: CompCert does some mangling for
      variadic functions, and some linkers do some versioning in their symbols.
  *)
  ident_to_name: (ident, string) Hashtbl.t;
  (** Maps a CompCert ident to a list of candidates symbol indices. We can only
      try to match symbols by name until we begin the analysis, so multiple
      static symbols might match a given name. The list will be narrowed down
      as we learn more about the contents of the symbol.
  *)
  ident_to_sym_ndx: (int list) PosMap.t;
  (** CompCert generates stubs for some functions, which we will aggregate as we
      discover them. *)
  stub_ident_to_vaddr: int32 PosMap.t;
  (** This structure is imported from CompCert's .sdump, and describes each
      atom. *)
  atoms: (ident, C2C.atom_info) Hashtbl.t;
}

(** This framework is carried while analyzing a single function. *)
type f_framework = {
  sf: s_framework;
  (** The symbol index of the current function. *)
  this_sym_ndx: int;
  (** The CompCert ident of the current function. *)
  this_ident: ident;
  (** A mapping from local labels to virtual addresses. *)
  label_to_vaddr: int32 PosMap.t;
  (** A list of all the labels encountered while processing the body. *)
  label_list: label list;
}

(** A few lenses that prove useful for manipulating frameworks.
*)

let sf_ef: (s_framework, e_framework) Lens.t = {
  get = (fun sf -> sf.ef);
  set = (fun ef sf -> { sf with ef = ef });
}

let ff_sf: (f_framework, s_framework) Lens.t = {
  get = (fun ff -> ff.sf);
  set = (fun sf ff -> { ff with sf = sf });
}

let ff_ef = ff_sf |-- sf_ef

let log = {
  get = (fun ef -> ef.log);
  set = (fun l ef -> { ef with log = l });
}

let ident_to_sym_ndx = {
  get = (fun sf -> sf.ident_to_sym_ndx);
  set = (fun i sf -> { sf with ident_to_sym_ndx = i });
}

let stub_ident_to_vaddr = {
  get = (fun sf -> sf.stub_ident_to_vaddr);
  set = (fun i sf -> { sf with stub_ident_to_vaddr = i });
}

(** Adds a range to the checked bytes list.
*)
let add_range (start: int32) (length: int32) (align: int) (bcd: byte_chunk_desc)
    (efw: e_framework): e_framework =
  assert (0l <= start && 0l < length);
  let stop = Int32.(sub (add start length) 1l) in
  {
    efw with
      chkd_bytes_list =
      (* Float constants can appear several times in the code, we don't
         want to add them multiple times *)
      if (List.exists
            (fun (a, b, _, _) -> a = start && b = stop)
            efw.chkd_bytes_list)
      then efw.chkd_bytes_list
      else (start, stop, align, bcd) :: efw.chkd_bytes_list;
  }

(** Some useful combinators to make it all work.
*)

(* external ( >>> ) : 'a -> ('a -> 'b) -> 'b = "%revapply" *)
let ( >>> ) (a: 'a) (f: 'a -> 'b): 'b = f a

let ( >>? ) (a: 'a on_success) (f: 'a -> 'b): 'b on_success =
  match a with
  | ERR(s) -> ERR(s)
  | OK(x) -> OK(f x)

let ( >>= ) (a: 'a on_success) (f: 'a -> 'b on_success): 'b on_success =
  match a with
  | ERR(s) -> ERR(s)
  | OK(x) -> f x

let ( ^%=? ) (lens: ('a, 'b) Lens.t) (transf: 'b -> 'b on_success)
    (arg: 'a): 'a on_success =
  let focus = arg |. lens in
  match transf focus with
  | OK(res) -> OK((lens ^= res) arg)
  | ERR(s) -> ERR(s)

(** Finally, some printers.
*)

let string_of_log_entry show_debug = function
| DEBUG(s)   -> if show_debug then s else ""
| ERROR(s)   -> "ERROR: " ^ s
| WARNING(s) -> "WARNING: " ^ s

let string_of_byte_chunk_desc = function
| ELF_header -> "ELF header"
| ELF_progtab -> "ELF program header table"
| ELF_shtab -> "ELF section header table"
| ELF_section_strtab -> "ELF section string table"
| ELF_symbol_strtab -> "ELF symbol string table"
| Symtab_data(s) -> "Data symbol table entry: " ^ s.st_name
| Symtab_function(s) -> "Function symbol table entry: " ^ s.st_name
| Data_symbol(s) -> "Data symbol: " ^ s.st_name
| Function_symbol(s) -> "Function symbol: " ^ s.st_name
| Zero_symbol -> "Symbol 0"
| Stub(s) -> "Stub for: " ^ s
| Jumptable -> "Jump table"
| Float_literal(f) -> "Float literal: " ^ string_of_float f
| Padding -> "Padding"
| Unknown(s) -> "   ???   " ^ s

