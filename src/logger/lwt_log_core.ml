(* Lightweight thread library for OCaml
 * http://www.ocsigen.org/lwt
 * Module Lwt_log
 * Copyright (C) 2002 Shawn Wagner <raevnos@pennmush.org>
 *               2009 Jérémie Dimino <jeremie@dimino.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

(* This code is an adaptation of [syslog-ocaml] *)

open Lwt

(* Errors happening in this module are always logged to [stderr]: *)
let log_intern fmt =
  Printf.eprintf ("Lwt_log: " ^^ fmt ^^ "\n%!")

(* +-----------------------------------------------------------------+
   | Log levels                                                      |
   +-----------------------------------------------------------------+ *)

type level =
  | Debug
  | Info
  | Notice
  | Warning
  | Error
  | Fatal

let string_of_level = function
  | Debug -> "debug"
  | Info -> "info"
  | Notice -> "notice"
  | Warning -> "warning"
  | Error -> "error"
  | Fatal -> "fatal"

(* +-----------------------------------------------------------------+
   | Patterns and rules                                              |
   +-----------------------------------------------------------------+ *)

type pattern = string list
    (* A pattern is represented by a list of literals:

       For example ["foo*bar*"] is represented by ["foo"; "bar"; ""]. *)

let sub_equal str ofs patt =
  let str_len = String.length str and patt_len = String.length patt in
  let rec loop ofs ofs_patt =
    ofs_patt = patt_len || (str.[ofs] = patt.[ofs_patt] && loop (ofs + 1) (ofs_patt + 1))
  in
  ofs + patt_len <= str_len && loop ofs 0

let pattern_match pattern string =
  let length = String.length string in
  let rec loop offset pattern =
    if offset = length then
      pattern = [] || pattern = [""]
    else
      match pattern with
        | [] ->
            false
        | literal :: pattern ->
            let literal_length = String.length literal in
            let max_offset = length - literal_length in
            let rec search offset =
              offset <= max_offset
              && ((sub_equal string offset literal && loop (offset + literal_length) pattern)
                  || search (offset + 1))
            in
            search offset
  in
  match pattern with
    | [] ->
        string = ""
    | literal :: pattern ->
        sub_equal string 0 literal && loop (String.length literal) pattern

let split pattern =
  let len = String.length pattern in
  let rec loop ofs =
    if ofs = len then
      [""]
    else
      match try Some(String.index_from pattern ofs '*') with Not_found -> None with
        | Some ofs' ->
            String.sub pattern ofs (ofs' - ofs) :: loop (ofs' + 1)
        | None ->
            [String.sub pattern ofs (len - ofs)]
  in
  loop 0


let rules = ref []

let load_rules str =
  let rec loop = function
    | [] ->
      []
    | (pattern, level) :: rest ->
      let pattern = split pattern in
      match String.lowercase level with
        | "debug" -> (pattern, Debug) :: loop rest
        | "info" -> (pattern, Info) :: loop rest
        | "notice" -> (pattern, Notice) :: loop rest
        | "warning" -> (pattern, Warning) :: loop rest
        | "error" -> (pattern, Error) :: loop rest
        | "fatal" -> (pattern, Fatal) :: loop rest
        | level -> log_intern "invalid log level (%s)" level; loop rest
  in
  match Lwt_log_rules.rules (Lexing.from_string str) with
    | None -> Printf.eprintf "Invalid contents of the LWT_LOG variable\n%!"
    | Some l -> rules := loop l

let _ =
  match try Some(Sys.getenv "LWT_LOG") with Not_found -> None with
    | Some str -> load_rules str
    | None -> ()

(* +-----------------------------------------------------------------+
   | Sections                                                        |
   +-----------------------------------------------------------------+ *)

module Section =
struct
  type t = {
    name : string;
    mutable level : level;
    mutable modified : bool;
  }

  type section = t

  module Sections = Weak.Make(struct
                                type t = section
                                let equal a b = a.name = b.name
                                let hash s = Hashtbl.hash s.name
                              end)

  let sections = Sections.create 32

  let find_level name =
    let rec loop = function
      | [] ->
          Notice
      | (pattern, level) :: rest ->
          if pattern_match pattern name then
            level
          else
            loop rest
    in
    loop !rules

  let recompute_levels () =
    Sections.iter
      (fun section ->
         if not section.modified then
           section.level <- find_level section.name)
      sections

  let make name =
    let section = { name = name; level = Notice; modified = false } in
    try
      Sections.find sections section
    with Not_found ->
      section.level <- find_level name;
      Sections.add sections section;
      section

  let name section = section.name

  let main = make "main"

  let level section = section.level

  let set_level section level =
    section.level <- level;
    section.modified <- true

  let reset_level section =
    if section.modified then begin
      section.modified <- false;
      section.level <- find_level section.name
    end
end

type section = Section.t

let add_rule pattern level =
  rules := (split pattern, level) :: !rules;
  Section.recompute_levels ()

let append_rule pattern level =
  rules := !rules @ [(split pattern, level)];
  Section.recompute_levels ()

(* +-----------------------------------------------------------------+
   | Loggers                                                         |
   +-----------------------------------------------------------------+ *)

exception Logger_closed

type logger = {
  mutable lg_closed : bool;
  lg_output : section -> level -> string list -> unit Lwt.t;
  lg_close : unit Lwt.t Lazy.t;
}

let close logger =
  logger.lg_closed <- true;
  Lazy.force logger.lg_close

let make ~output ~close =
  {
    lg_closed = false;
    lg_output = output;
    lg_close = Lazy.lazy_from_fun close;
  }

let broadcast loggers =
  make
    ~output:(fun section level lines ->
               Lwt_list.iter_p (fun logger -> logger.lg_output section level lines) loggers)
    ~close:return

let dispatch f =
  make
    ~output:(fun section level lines -> (f section level).lg_output section level lines)
    ~close:return

(* +-----------------------------------------------------------------+
   | Templates                                                       |
   +-----------------------------------------------------------------+ *)

type template = string

let location_key = Lwt.new_key ()

let render ~buffer ~template ~section ~level ~message =
  let file, line, column =
    match Lwt.get location_key with
      | Some loc -> loc
      | None -> ("<unknown>", -1, -1)
  in
  Buffer.add_substitute buffer
    (function
      | "message" -> message
      | "level" -> string_of_level level
      | "section" -> Section.name section
      | "loc-file" -> file
      | "loc-line" -> string_of_int line
      | "loc-column" -> string_of_int column
      | var -> Printf.ksprintf invalid_arg "Lwt_log.render_buffer: unknown variable %S" var)
    template

(* +-----------------------------------------------------------------+
   | Predefined loggers                                              |
   +-----------------------------------------------------------------+ *)

let null =
  make
    ~output:(fun section level lines -> return ())
    ~close:return

let default = ref null


(* +-----------------------------------------------------------------+
   | Logging functions                                               |
   +-----------------------------------------------------------------+ *)

let split str =
  let len = String.length str in
  let rec aux i =
    if i >= len then
      []
    else
      let j = try String.index_from str i '\n' with Not_found -> String.length str in
      String.sub str i (j - i) :: aux (j + 1)
  in
  aux 0

let log ?exn ?(section=Section.main) ?location ?logger ~level message =
  let logger = match logger with
    | None -> !default
    | Some logger -> logger
  in
  if logger.lg_closed then
    raise_lwt Logger_closed
  else if level >= section.Section.level then
    match exn with
      | None ->
          Lwt.with_value location_key location (fun () -> logger.lg_output section level (split message))
      | Some exn ->
          let message = message ^ ": " ^ Printexc.to_string exn in
          let message =
            if Printexc.backtrace_status () then
              match Printexc.get_backtrace () with
                | "" -> message
                | backtrace -> message ^ "\nbacktrace:\n" ^ backtrace
            else
              message
          in
          Lwt.with_value location_key location (fun () -> logger.lg_output section level (split message))
  else
    return ()

let log_f ?exn ?section ?location ?logger ~level format =
  Printf.ksprintf (log ?exn ?section ?location ?logger ~level) format

let ign_log ?exn ?section ?location ?logger ~level message =
  try
    ignore (log ?exn ?section ?location ?logger ~level message)
  with _ ->
    ()

let ign_log_f ?exn ?section ?location ?logger ~level format =
  Printf.ksprintf (ign_log ?exn ?section ?location ?logger ~level) format

let debug ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Debug msg
let debug_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (debug ?exn ?section ?location ?logger) fmt
let info ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Info msg
let info_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (info ?exn ?section ?location ?logger) fmt
let notice ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Notice msg
let notice_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (notice ?exn ?section ?location ?logger) fmt
let warning ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Warning msg
let warning_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (warning ?exn ?section ?location ?logger) fmt
let error ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Error msg
let error_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (error ?exn ?section ?location ?logger) fmt
let fatal ?exn ?section ?location ?logger msg = log ?exn ?section ?location ?logger ~level:Fatal msg
let fatal_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (fatal ?exn ?section ?location ?logger) fmt

let ign_debug ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Debug msg
let ign_debug_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_debug ?exn ?section ?location ?logger) fmt
let ign_info ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Info msg
let ign_info_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_info ?exn ?section ?location ?logger) fmt
let ign_notice ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Notice msg
let ign_notice_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_notice ?exn ?section ?location ?logger) fmt
let ign_warning ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Warning msg
let ign_warning_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_warning ?exn ?section ?location ?logger) fmt
let ign_error ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Error msg
let ign_error_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_error ?exn ?section ?location ?logger) fmt
let ign_fatal ?exn ?section ?location ?logger msg = ign_log ?exn ?section ?location ?logger ~level:Fatal msg
let ign_fatal_f ?exn ?section ?location ?logger fmt = Printf.ksprintf (ign_fatal ?exn ?section ?location ?logger) fmt
