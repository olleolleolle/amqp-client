let (>>=) = Lwt.(>>=)
let (>>|) = Lwt.(>|=)
let return = Lwt.return
let after ms = Lwt_unix.sleep (ms /. 1000.0)
let spawn t = Lwt.ignore_result t

module Ivar = struct
  type 'a state = Empty of 'a Lwt_condition.t
                | Full of 'a
  type 'a t = { mutable state: 'a state }
  let create () =
    { state = Empty (Lwt_condition.create ()) }

  let create_full v = { state = Full v }

  let fill t v =
    match t.state with
    | Empty c -> Lwt_condition.broadcast c v;
      t.state <- Full v
    | Full _ -> failwith "Var already filled"

  let read t =
    match t.state with
    | Empty c ->
      Lwt_condition.wait c >>= fun v ->
      return v
    | Full v ->
      return v

  let is_full t =
    match t.state with
    | Empty _ -> false
    | Full _ -> true

  let fill_if_empty t v =
    if (not (is_full t)) then
      fill t v
end

module Deferred = struct
  type 'a t = 'a Lwt.t
  let all_unit = Lwt.join
  let try_with f =
    let open Lwt in
    let var = Ivar.create () in
    let hook = !async_exception_hook in
    async_exception_hook := (Ivar.fill var);
    catch (fun () -> (f () >>= fun r -> return (`Ok r)) <?>
           (Ivar.read var >>= fun e -> return (`Error e)))
      (fun exn -> return (`Error exn)) >>= fun x ->
    async_exception_hook := hook;
    return x

  module List = struct
    let init ~f n =
      let rec inner = function
        | i when i = n -> []
        | i -> i :: inner (i + 1)
      in
      inner 0 |> Lwt_list.map_p f
    let iter ~f l = Lwt_list.iter_p f l
  end
end

module Log = struct
  let section = Lwt_log.Section.make "amqp_client"

  let debug fmt = Lwt_log.ign_debug_f ~section fmt
  let info fmt = Lwt_log.ign_info_f ~section fmt
  let error fmt = Lwt_log.ign_error_f ~section fmt
end

(* Pipes. Bound are not implemented yet .*)
module Pipe = struct
  type 'a elem = Data of 'a
               | Flush of unit Lwt_condition.t

  module Reader = struct
    type 'a t = 'a elem Lwt_stream.t
  end
  module Writer = struct
    type 'a t = 'a elem option -> unit
  end

  let create () =
    let stream, push = Lwt_stream.create () in
    ( stream, push )

  (** Not supported yet *)
  let set_size_budget _t _budget = ()

  (* Can be readers and writers. *)
  let flush t =
    let cond = Lwt_condition.create () in
    t (Some (Flush cond));
    Lwt_condition.wait cond

  let rec read t =
    Lwt_stream.get t >>= function
    | None -> return `Eof
    | Some Data d -> return (`Ok d)
    | Some Flush cond ->
      Lwt_condition.signal cond ();
      read t

  let write_without_pushback t data =
    t (Some (Data data))

  let write t  data =
    write_without_pushback t data;
    return ()

  (* Pipe of pipes. Must spawn more *)
  let interleave_pipe t =
    let (reader, writer) = create () in
    let rec copy t =
      Lwt_stream.get t >>= function
      | Some n ->
        writer (Some n);
        copy t
      | None -> return ()
    in
    let run = function
      | Data t -> copy t
      | Flush _ ->
        failwith "Cannot flush this one"
    in
    spawn (Lwt_stream.iter_p run t);
    reader


  let transfer_in ~from:queue t =
    Queue.iter (write_without_pushback t) queue;
    return ()

  let close t =
    let cond = Lwt_condition.create () in
    t (Some (Flush cond));
    t None;
    Lwt_condition.wait cond

  let iter t ~f =
    let rec inner () =
      read t >>= function
      | `Eof -> return ()
      | `Ok d -> f d >>= fun () ->
        inner ()
    in
    inner ()

  let iter_without_pushback t ~f =
    let rec inner () =
      read t >>= function
      | `Eof -> return ()
      | `Ok d -> f d; inner ()
    in
    inner ()

end

module Reader = struct
  type t = Lwt_io.input_channel
  let close t = Lwt_io.close t

  let read input buf : [ `Eof of int | `Ok ] Deferred.t =
    let len = Bytes.length buf in
    let rec inner = function
      | n when n = len ->
          return `Ok
      | n -> begin
          Lwt.catch (fun () -> Lwt_io.read_into input buf n (len - n)) (fun _exn -> return 0) >>= function
          | 0 -> return (`Eof n)
          | read -> inner (n + read)
        end
    in
    inner 0
end

module Writer = struct
  type t = string Pipe.Writer.t
  let close t = Pipe.close t
  let flush t = Pipe.flush t
  let write t data = Pipe.write_without_pushback t data
end

module Tcp = struct

  let connect ?nodelay host port =
    let fd = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    Lwt_unix.gethostbyname host >>= fun entry ->
    let sock_addr = (Lwt_unix.ADDR_INET (entry.Lwt_unix.h_addr_list.(0), port)) in
    Lwt_io.open_connection ~fd sock_addr >>= fun (ic, oc) ->
    (* Start a process that writes *)
    let (reader, writer) = Pipe.create () in
    spawn (Pipe.iter ~f:(fun str ->
        Lwt_io.write oc str) reader);

    (match nodelay with
     | Some () -> Lwt_unix.(setsockopt fd TCP_NODELAY true)
     | None -> ());
    return (ic, writer)

end

module Scheduler = struct
  let cond = Lwt_condition.create ()
  let go () = Lwt_main.run (Lwt_condition.wait cond) |> ignore
  let shutdown (n : int) = Lwt_condition.signal cond n
end
