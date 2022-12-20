open QCheck
open STM

module SConf =
struct
  type cmd =
    | File_exists of string list
    | Mkdir of string list * string * int
    | Rmdir of string list * string
    | Readdir of string list
    | Touch of string list * string * int
    [@@deriving show { with_path = false }]

  module Map_names = Map.Make (String)

  type filesys =
    | Directory of {perm: int; fs_map: filesys Map_names.t}
    | File of {perm: int}

  type state = filesys

  type sut   = unit

  let (/) = Filename.concat

  let update_map_name map_name k v = Map_names.add k v (Map_names.remove k map_name)

  let arb_cmd _s  =
    let name_gen = Gen.(oneofl ["aaa" ; "bbb" ; "ccc" ; "ddd" ; "eee"]) in
    let path_gen = Gen.map (fun path -> path) (Gen.list_size (Gen.int_bound 5) name_gen) in (* can be empty *)
    let perm_gen = Gen.return 0o777 in
    QCheck.make ~print:show_cmd
      Gen.(oneof
            [
                map (fun path -> File_exists path) path_gen ;
                map3 (fun path new_dir_name perm -> Mkdir (path, new_dir_name, perm)) path_gen name_gen perm_gen;
                map2 (fun path delete_dir_name -> Rmdir (path, delete_dir_name)) path_gen name_gen;
                map (fun path -> Readdir path) path_gen;
                map3 (fun path new_file_name perm -> Touch (path, new_file_name, perm)) path_gen name_gen perm_gen;
            ])

  let static_path = Sys.getcwd ()

  let init_state  = Directory {perm = 0o777; fs_map = Map_names.empty}

  let rec find_opt_model fs path =
    match fs with
    | File f ->
      if path = []
      then Some (File f)
      else None
    | Directory d ->
      (match path with
      | []       -> Some (Directory d)
      | hd :: tl ->
        (match Map_names.find_opt hd d.fs_map with
        | None    -> None
        | Some fs -> find_opt_model fs tl))

  let mem_model fs path = find_opt_model fs path <> None

  let rec mkdir_model fs path new_dir_name perm =
    match fs with
    | File _ -> fs
    | Directory d ->
      (match path with
      | [] ->
        let new_dir = Directory {perm; fs_map = Map_names.empty} in
        Directory {d with fs_map = Map_names.add new_dir_name new_dir d.fs_map}
      | next_in_path :: tl_path ->
        (match Map_names.find_opt next_in_path d.fs_map with
        | None -> fs
        | Some sub_fs ->
          let nfs = mkdir_model sub_fs tl_path new_dir_name perm in
          if nfs = sub_fs
          then fs
          else
            let new_map = Map_names.remove next_in_path d.fs_map in
            let new_map = Map_names.add next_in_path nfs new_map in
            Directory {d with fs_map = new_map}))

  let readdir_model fs path =
    match find_opt_model fs path with
    | None    -> None
    | Some fs ->
      (match fs with
      | File _ -> None
      | Directory d -> Some (Map_names.fold (fun k _ l -> k::l) d.fs_map []))

  let rec rmdir_model fs path delete_dir_name =
    match fs with
    | File _      -> fs
    | Directory d ->
      (match path with
      | [] ->
        (match Map_names.find_opt delete_dir_name d.fs_map with
        | Some (Directory target) when Map_names.is_empty target.fs_map ->
          Directory {d with fs_map = Map_names.remove delete_dir_name d.fs_map}
        | None | Some (File _) | Some (Directory _) -> fs)
      | next_in_path :: tl_path ->
        (match Map_names.find_opt next_in_path d.fs_map with
        | None        -> fs
        | Some sub_fs ->
          let nfs = rmdir_model sub_fs tl_path delete_dir_name in
          if nfs = sub_fs
          then fs
          else Directory {d with fs_map = (update_map_name d.fs_map next_in_path nfs)}))

  let rec touch_model fs path new_file_name perm =
    match fs with
    | File _      -> fs
    | Directory d ->
      (match path with
      | [] ->
        let new_file = File {perm} in
        Directory {d with fs_map = Map_names.add new_file_name new_file d.fs_map}
      | next_in_path :: tl_path ->
        (match Map_names.find_opt next_in_path d.fs_map with
        | None        -> fs
        | Some sub_fs ->
          let nfs = touch_model sub_fs tl_path new_file_name perm in
          if nfs = sub_fs
          then fs
          else Directory {d with fs_map = update_map_name d.fs_map next_in_path nfs}))

  let next_state c fs =
    match c with
    | File_exists _path -> fs
    | Mkdir (path, new_dir_name, perm) ->
      if mem_model fs (path @ [new_dir_name])
      then fs
      else mkdir_model fs path new_dir_name perm
    | Rmdir (path,delete_dir_name) ->
      if mem_model fs (path @ [delete_dir_name])
      then rmdir_model fs path delete_dir_name
      else fs
    | Readdir _path -> fs
    | Touch (path, new_file_name, perm) ->
      if mem_model fs (path @ [new_file_name])
      then fs
      else touch_model fs path new_file_name perm

  let init_sut () =
    match Sys.os_type with
    | "Unix" -> ignore (Sys.command ("mkdir " ^ (static_path / "sandbox_root")))
    | "Win32" -> ignore (Sys.command ("mkdir " ^ (static_path / "sandbox_root")))
    | v -> failwith ("Sys tests not working with " ^ v)

  let cleanup _ =
    match Sys.os_type with
    | "Unix" -> ignore (Sys.command ("rm -rf " ^ (static_path / "sandbox_root")))
    | "Win32" -> ignore (Sys.command ("powershell -Command \"Remove-Item '" ^ (static_path / "sandbox_root") ^ "' -Recurse -Force\""))
    | v -> failwith ("Sys tests not working with " ^ v)

  let precond _c _s = true

  let p path =  (List.fold_left (/) (static_path / "sandbox_root") path)

  let run c _file_name =
    match c with
    | File_exists path -> Res (bool, Sys.file_exists (p path))
    | Mkdir (path, new_dir_name, perm) ->
      Res (result unit exn, protect (Sys.mkdir ((p path) / new_dir_name)) perm)
    | Rmdir (path, delete_dir_name) ->
      Res (result unit exn, protect (Sys.rmdir) ((p path) / delete_dir_name))
    | Readdir path ->
      Res (result (array string) exn, protect (Sys.readdir) (p path))
    | Touch (path, new_file_name, _perm) ->
      (match Sys.os_type with
      | "Unix" -> Res (int, Sys.command ("touch " ^ (p path) / new_file_name ^ " 2>/dev/null"))
      | "Win32" -> Res (int, Sys.command ("type nul >> \"" ^ (p path / new_file_name) ^ "\""))
      | v -> failwith ("Sys tests not working with " ^ v))

  let fs_is_a_dir fs = match fs with | Directory _ -> true | File _ -> false

  let path_is_a_dir fs path =
    match find_opt_model fs path with
    | None -> false
    | Some target_fs -> fs_is_a_dir target_fs

  let postcond c (fs: filesys) res =
    match c, res with
    | File_exists path, Res ((Bool,_),b) -> b = mem_model fs path
    | Mkdir (path, new_dir_name, _perm), Res ((Result (Unit,Exn),_), res) ->
      let complete_path = (path @ [new_dir_name]) in
      (match res with
      | Error err ->
        (match err with
        | Sys_error s ->
          (s = (p complete_path) ^ ": Permission denied") ||
          (s = (p complete_path) ^ ": File exists" && mem_model fs complete_path) ||
          (s = (p complete_path) ^ ": No such file or directory" && not (mem_model fs path)) ||
          (s = (p complete_path) ^ ": Not a directory" && not (path_is_a_dir fs complete_path))
          | _ -> false)
        | Ok () -> mem_model fs path && path_is_a_dir fs path && not (mem_model fs complete_path))
    | Rmdir (path, delete_dir_name), Res ((Result (Unit,Exn),_), res) ->
      let complete_path = (path @ [delete_dir_name]) in
      (match res with
      | Error err ->
        (match err with
          | Sys_error s ->
            (s = (p complete_path) ^ ": Directory not empty" && not (readdir_model fs complete_path = Some [])) ||
            (s = (p complete_path) ^ ": No such file or directory" && not (mem_model fs complete_path)) ||
            (s = (p complete_path) ^ ": Not a directory" && not (path_is_a_dir fs complete_path))
          | _ -> false)
      | Ok () ->
          mem_model fs complete_path && path_is_a_dir fs complete_path && readdir_model fs complete_path = Some [])
    | Readdir path, Res ((Result (Array String,Exn),_), res) ->
      (match res with
      | Error err ->
        (match err with
          | Sys_error s ->
            (s = (p path) ^ ": Permission denied") ||
            (s = (p path) ^ ": No such file or directory" && not (mem_model fs path)) ||
            (s = (p path) ^ ": Not a directory" && not (path_is_a_dir fs path))
          | _ -> false)
      | Ok array_of_subdir ->
        mem_model fs path && path_is_a_dir fs path &&
        (match readdir_model fs path with
        | None   -> false
        | Some l ->
          List.sort String.compare l
          = List.sort String.compare (Array.to_list array_of_subdir)))
    | Touch (path, _new_file_name, _perm), Res ((Int,_),n) ->
      if n = 0
      then (mem_model fs path && path_is_a_dir fs path)
      else (not (mem_model fs path) || not (path_is_a_dir fs path))
    | _,_ -> false
end

module Sys_seq = STM_sequential.Make(SConf)
module Sys_dom = STM_domain.Make(SConf)

;;
QCheck_base_runner.run_tests_main [
    Sys_seq.agree_test     ~count:1000  ~name:"STM Sys test sequential";
    Sys_dom.agree_test_par ~count:200   ~name:"STM Sys test parallel"
  ]
