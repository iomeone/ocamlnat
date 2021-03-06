(***********************************************************************)
(*                                                                     *)
(*                              ocamlnat                               *)
(*                                                                     *)
(*                  Benedikt Meurer, University of Siegen              *)
(*                                                                     *)
(*    Copyright 2011 Lehrstuhl für Compilerbau und Softwareanalyse,    *)
(*    Universität Siegen. All rights reserved. This file is distri-    *)
(*    buted under the terms of the Q Public License version 1.0.       *)
(*                                                                     *)
(***********************************************************************)

(* Common functions for jitting code *)

open Cmm
open Emitaux
open Jitlink
open Linearize

(* Native addressing *)

module Addr =
struct
  include Nativeint

  external of_int64: int64 -> t = "%int64_to_nativeint"
  external to_int64: t -> int64 = "%int64_of_nativeint"

  let add_int x y =
    add x (of_int y)

  let sub_int x y =
    sub x (of_int y)
end

(* String extensions *)

module String =
struct
  include String

  external unsafe_get16: t -> int -> int = "camlnat_str_get16" "noalloc"
  external unsafe_get32: t -> int -> int32 = "camlnat_str_get32"
  external unsafe_get64: t -> int -> int64 = "camlnat_str_get64"
  external unsafe_set16: t -> int -> int -> unit = "camlnat_str_set16" "noalloc"
  external unsafe_set32: t -> int -> int32 -> unit = "camlnat_str_set32" "noalloc"
  external unsafe_set64: t -> int -> int64 -> unit = "camlnat_str_set64" "noalloc"
end

(* Memory management *)

module Memory =
struct
  type t = Addr.t

  external alignment: unit -> int = "camlnat_mem_alignment" "noalloc"
  external reserve: int -> t = "camlnat_mem_reserve"
  external prepare: t -> string -> int -> unit = "camlnat_mem_prepare" "noalloc"
  external cacheflush: t -> int -> unit = "camlnat_mem_cacheflush" "noalloc"
  external commit: t -> int -> unit = "camlnat_mem_commit" "noalloc"

  let mask = alignment() - 1

  let align n =
    (n + mask) land (lnot mask)
end

(* Symbol management *)

module Symbol =
struct
  type t = string

  external exec: t -> Obj.t = "camlnat_sym_exec"
  external load: t -> Obj.t = "camlnat_sym_load"
  external add: t -> Addr.t -> unit = "camlnat_sym_add" "noalloc"
  external get: t -> Addr.t = "camlnat_sym_get"
end

(* Execution *)

type evaluation_outcome = Result of Obj.t | Exception of exn

let jit_execsym sym =
  try Result(Symbol.exec sym)
  with exn -> Exception exn

let jit_loadsym sym =
  try Symbol.load sym
  with Failure s -> raise (Error(Undefined_global s))

(* Sections *)

type section =
  { mutable sec_buf: string;
    mutable sec_pos: int;
    mutable sec_addr: Addr.t }

let grow_section sec pos =
  let len = String.length sec.sec_buf in
  if pos > len then begin
    let buf = String.create (len * 2) in
    assert ((String.length buf) mod 1024 == 0);
    String.unsafe_blit sec.sec_buf 0 buf 0 pos;
    sec.sec_buf <- buf
  end;
  sec.sec_pos <- pos

let new_section() =
  { sec_buf = String.create 1024;
    sec_pos = 0;
    sec_addr = 0n }

let reset_section sec =
  sec.sec_buf <- String.create 1024;
  sec.sec_pos <- 0

let text_sec = new_section()
let data_sec = new_section()
let curr_sec = ref text_sec

let jit_text() = curr_sec := text_sec
let jit_data() = curr_sec := data_sec

(* Labels and symbols *)

let labels = ref ([] : (label * (section * int)) list)
let globals = ref ([] : string list)
let symbols = ref ([] : (string * (section * int)) list)

let addr_of_label lbl =
  let (sec, ofs) = List.assoc lbl !labels in
  Addr.add_int sec.sec_addr ofs

let addr_of_symbol sym =
  try
    (* Try or own symbols first *)
    let (sec, ofs) = List.assoc sym !symbols in
    Addr.add_int sec.sec_addr ofs
  with
    Not_found ->
      (* Fallback to the global symbol table *)
      try Symbol.get sym
      with Failure s -> raise (Error(Undefined_global s))

let symbol_name sym =
  let buf = Buffer.create (String.length sym) in
  String.iter
    (function
        ('A'..'Z' | 'a'..'z' | '0'..'9' | '_') as c -> Buffer.add_char buf c
      | c -> Printf.bprintf buf "$%02x" (Char.code c))
    sym;
  Buffer.contents buf

let jit_label lbl =
  let sec = !curr_sec in
  assert (not (List.mem_assoc lbl !labels));
  labels := (lbl, (sec, sec.sec_pos)) :: !labels

let jit_symbol sym =
  let sec = !curr_sec in
  let sym = symbol_name sym in
  assert (not (List.mem_assoc sym !symbols));
  symbols := (sym, (sec, sec.sec_pos)) :: !symbols

let jit_global sym =
  let sym = symbol_name sym in
  globals := sym :: !globals

(* Tags *)

module Tag =
struct
  type t = Obj.t

  external is_label: t -> bool = "%obj_is_int"
  let is_symbol tag = not (is_label tag)

  external of_label: label -> t = "%identity"
  let of_symbol sym = Obj.magic (symbol_name sym)

  let to_addr tag =
    if is_label tag
    then addr_of_label (Obj.obj tag)
    else addr_of_symbol (Obj.obj tag)
end

(* Relocations *)

type relocfn = (*S*)Addr.t -> (*P*)Addr.t -> (*A*)int32 -> int32
type reloc =
    R_ABS_32 of Tag.t           (* 32bit absolute *)
  | R_ABS_64 of Tag.t           (* 64bit absolute *)
  | R_REL_32 of Tag.t           (* 32bit relative *)
  | R_FUN_32 of Tag.t * relocfn (* 32bit custom *)

let relocs = ref ([] : (section * int * reloc) list)

let jit_reloc reloc =
  let sec = !curr_sec in
  relocs := (sec, sec.sec_pos, reloc) :: !relocs

let patch_reloc (sec, ofs, rel) =
  match rel with
    R_ABS_32 tag ->
      let a = Tag.to_addr tag in
      assert (a >= -2147483648n && a <= 2147483647n);
      let d = String.unsafe_get32 sec.sec_buf ofs in
      let x = Int32.add (Addr.to_int32 a) d in
      String.unsafe_set32 sec.sec_buf ofs x
  | R_ABS_64 tag ->
      let a = Addr.to_int64 (Tag.to_addr tag) in
      let d = String.unsafe_get64 sec.sec_buf ofs in
      let x = Int64.add a d in
      String.unsafe_set64 sec.sec_buf ofs x
  | R_REL_32 tag ->
      let s = Tag.to_addr tag in
      let p = Addr.add_int sec.sec_addr ofs in
      let a = Addr.of_int32 (String.unsafe_get32 sec.sec_buf ofs) in
      let x = Addr.add (Addr.sub s p) a in
      assert (x >= -2147483648n && x <= 2147483647n);
      String.unsafe_set32 sec.sec_buf ofs (Addr.to_int32 x)
  | R_FUN_32(tag, fn) ->
      let s = Tag.to_addr tag in
      let p = Addr.add_int sec.sec_addr ofs in
      let a = String.unsafe_get32 sec.sec_buf ofs in
      String.unsafe_set32 sec.sec_buf ofs (fn s p a)

(* Data types *)

let jit_int8 n =
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  grow_section sec (pos + 1);
  String.unsafe_set sec.sec_buf pos (Char.unsafe_chr n)

let jit_int8n n =
  jit_int8 (Nativeint.to_int n)

let jit_int16 n =
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  grow_section sec (pos + 2);
  String.unsafe_set16 sec.sec_buf pos n

let jit_int16n n =
  jit_int16 (Nativeint.to_int n)

let jit_int32l n =
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  grow_section sec (pos + 4);
  String.unsafe_set32 sec.sec_buf pos n

let jit_int32 n =
  jit_int32l (Int32.of_int n)

let jit_int32n n =
  jit_int32l (Nativeint.to_int32 n)

let jit_int64L n =
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  grow_section sec (pos + 8);
  String.unsafe_set64 sec.sec_buf pos n

let jit_int64 n =
  jit_int64L (Int64.of_int n)

let jit_int64n n =
  jit_int64L (Int64.of_nativeint n)

let jit_ascii str =
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  let len = String.length str in
  grow_section sec (pos + len);
  String.unsafe_blit str 0 sec.sec_buf pos len

let jit_asciz s =
  jit_ascii s;
  jit_int8 0

(* Alignment *)

let jit_fill x n = 
  let sec = !curr_sec in
  let pos = sec.sec_pos in
  grow_section sec (pos + n);
  String.unsafe_fill sec.sec_buf pos n (Char.unsafe_chr x)

let jit_align x n =
  let sec = !curr_sec in
  let m = n - (sec.sec_pos mod n) in
  if m != n then
    jit_fill x m

(* Absolute addresses *)

let jit_tag_address tag =
  if Arch.size_addr == 4 then begin
    jit_reloc (R_ABS_32 tag);
    jit_int32l 0l
  end else begin
    jit_reloc (R_ABS_64 tag);
    jit_int64L 0L
  end

(* Jitting of data *)

let data l =
  jit_data();
  List.iter
     (function
        Cglobal_symbol s ->
          jit_global s
      | Cdefine_symbol s ->
          jit_symbol s
      | Cdefine_label lbl ->
          jit_label (100000 + lbl)
      | Cint8 n ->
          jit_int8 n
      | Cint16 n ->
          jit_int16 n
      | Cint32 n ->
          jit_int32n n
      | Cint n ->
          if Arch.size_addr == 4 then jit_int32n n else jit_int64n n
      | Csingle f ->
          jit_int32l (Int32.bits_of_float (float_of_string f))
      | Cdouble f ->
          jit_int64L (Int64.bits_of_float (float_of_string f))
      | Csymbol_address s ->
          jit_tag_address (Tag.of_symbol s)
      | Clabel_address lbl ->
          jit_tag_address (Tag.of_label (100000 + lbl))
      | Cstring s ->
          jit_ascii s
      | Cskip n ->
          jit_fill 0 n
      | Calign n ->
          jit_align 0 n)
     l

(* Beginning / end of an assembly *)

let begin_assembly() =
  (* Reset JIT state *)
  reset_section text_sec;
  reset_section data_sec;
  labels := [];
  globals := [];
  symbols := [];
  relocs := [];
  (* OCaml module prologue *)
  let sym = (Compilenv.make_symbol (Some "data_begin")) in
  jit_data();
  jit_global sym;
  jit_symbol sym;
  let sym = (Compilenv.make_symbol (Some "code_begin")) in
  jit_text();
  jit_global sym;
  jit_symbol sym

let efa =
  { efa_label = (fun lbl -> jit_tag_address (Tag.of_label lbl));
    efa_16 = jit_int16;
    efa_32 = jit_int32l;
    efa_word = if Arch.size_addr == 4 then jit_int32 else jit_int64;
    efa_align = jit_align 0;
    efa_label_rel = (fun lbl ofs ->
                       (* .long lbl - . + ofs *)
                       jit_reloc (R_REL_32(Tag.of_label lbl));
                       jit_int32l ofs);
    efa_def_label = jit_label;
    efa_string = jit_asciz }

let end_assembly() =
  (* OCaml module epilogue *)
  let sym = (Compilenv.make_symbol (Some "code_end")) in
  jit_text();
  jit_global sym;
  jit_symbol sym;
  let sym = (Compilenv.make_symbol (Some "data_end")) in
  jit_data();
  jit_global sym;
  jit_symbol sym;
  (* Emit the frametable if there are any frame descriptors *)
  if !frame_descriptors <> [] then begin
    let sym = (Compilenv.make_symbol (Some "frametable")) in
    jit_int32 0;
    jit_global sym;
    jit_symbol sym;
    emit_frames efa
  end;
  (* Pad sections to required alignment *)
  text_sec.sec_pos <- Memory.align text_sec.sec_pos;
  data_sec.sec_pos <- Memory.align data_sec.sec_pos;
  assert ((text_sec.sec_pos mod Memory.alignment()) == 0);
  assert ((data_sec.sec_pos mod Memory.alignment()) == 0);
  (* Reserve memory for the sections *)
  text_sec.sec_addr <- Memory.reserve (text_sec.sec_pos + data_sec.sec_pos);
  data_sec.sec_addr <- Addr.add_int text_sec.sec_addr text_sec.sec_pos;
  (* Patch all relocations *)
  List.iter patch_reloc !relocs;
  (* Prepare section content *)
  Memory.prepare text_sec.sec_addr text_sec.sec_buf text_sec.sec_pos;
  Memory.prepare data_sec.sec_addr data_sec.sec_buf data_sec.sec_pos;
  (* Flush the instruction cache *)
  Memory.cacheflush text_sec.sec_addr text_sec.sec_pos;
  (* Register global symbols *)
  List.iter
    (fun sym -> Symbol.add sym (addr_of_symbol sym))
    !globals;
  (* Commit memory *)
  Memory.commit text_sec.sec_addr (text_sec.sec_pos + data_sec.sec_pos)
