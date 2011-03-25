(*
 * shell.ml
 * --------
 * Copyright : (c) 2011, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of Lambda-Term.
 *)

(* A mini shell *)

open CamomileLibraryDyn.Camomile
open React
open Lwt
open Lt_style
open Lt_text
open Lt_geom

(* +-----------------------------------------------------------------+
   | Prompt creation                                                 |
   +-----------------------------------------------------------------+ *)

(* The function [make_prompt] creates the prompt. Parameters are:

   - size: the current size of the terminal.
   - exit_code: the exit code of the last executed command.
   - time: the current time. *)
let make_prompt size exit_code time =
  let tm = Unix.localtime time in
  let code = string_of_int exit_code in

  (* Replace the home directory by "~" in the current path. *)
  let path = Sys.getcwd () in
  let path =
    try
      let home = Sys.getenv "HOME" in
      if Zed_utf8.starts_with path home then
        Zed_utf8.replace path 0 (Zed_utf8.length home) "~"
      else
        path
    with Not_found ->
      path
  in

  (* Shorten the path if it is too large for the size of the
     terminal. *)
  let path_len = Zed_utf8.length path in
  let size_for_path = size.columns - 24 - Zed_utf8.length code in
  let path =
    if path_len > size_for_path then
      if size_for_path >= 2 then
        ".." ^ Zed_utf8.after path (path_len - size_for_path + 2)
      else
        path
    else
      path
  in

  eval [
    B_bold true;

    B_fg lblue;
    S"─( ";
    B_fg lmagenta; S(Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec); E_fg;
    S" )─< ";
    B_fg lyellow; S path; E_fg;
    S" >─";
    S(Zed_utf8.make
        (size.columns - 24 - Zed_utf8.length code - Zed_utf8.length path)
        (UChar.of_int 0x2500));
    S"[ ";
    B_fg(if exit_code = 0 then lwhite else lred); S code; E_fg;
    S" ]─";
    E_fg;

    B_fg lred; S(try Sys.getenv "USER" with Not_found -> ""); E_fg;
    B_fg lgreen; S"@"; E_fg;
    B_fg lblue; S(Unix.gethostname ()); E_fg;
    B_fg lgreen; S" $ "; E_fg;

    E_bold;
  ]

(* +-----------------------------------------------------------------+
   | Listing binaries of the path for completion                     |
   +-----------------------------------------------------------------+ *)

module String_set = Set.Make(String)

let colon_re = Str.regexp ":"
let get_paths () =
  try
    Str.split colon_re (Sys.getenv "PATH")
  with Not_found ->
    []

(* Get the set of all binaries with a name starting with [prefix]. *)
let binaries = lazy(
  Lwt_list.fold_left_s
    (fun set dir ->
       Lwt_stream.fold
         (fun file set ->
            if file <> "." && file <> ".." then
              String_set.add file set
            else
              set)
         (Lwt_unix.files_of_directory dir)
         set)
    String_set.empty
    (get_paths ())
  >|= String_set.elements
)

(* +-----------------------------------------------------------------+
   | Customization of the read-line engine                           |
   +-----------------------------------------------------------------+ *)

(* Signal updated every second with the current time. *)
let time =
  let time, set_time = S.create (Unix.time ()) in
  (* Update the time every second. *)
  ignore (Lwt_engine.on_timer 1.0 true (fun _ -> set_time (Unix.time ())));
  time

class read_line ~term ~history ~exit_code = object(self)
  inherit Lt_read_line.read_line ~history ()
  inherit [Zed_utf8.t] Lt_read_line.term term

  method completion =
    let prefix  = Zed_rope.to_string self#input_prev in
    lwt binaries = Lazy.force binaries in
    let binaries = List.filter (fun file -> Zed_utf8.starts_with file prefix) binaries in
    return (0, List.map (fun file -> (file, " ")) binaries)

  initializer
    self#set_prompt (S.l2 (fun size time -> make_prompt size exit_code time) self#size time)
end

(* +-----------------------------------------------------------------+
   | Main loop                                                       |
   +-----------------------------------------------------------------+ *)

let rec loop term history exit_code =
  lwt command = (new read_line ~term ~history ~exit_code)#run in
  lwt status = Lwt_process.exec (Lwt_process.shell command) in
  loop
    term
    (Lt_read_line.add_entry command history)
    (match status with
       | Unix.WEXITED code -> code
       | Unix.WSIGNALED code -> code
       | Unix.WSTOPPED code -> code)

(* +-----------------------------------------------------------------+
   | Entry point                                                     |
   +-----------------------------------------------------------------+ *)

lwt () =
  try_lwt
    lwt term = Lazy.force Lt_term.stdout in
    loop term [] 0
  with Lt_read_line.Interrupt ->
    return ()