(** Async compatability layer *)

open Async.Std

module Deferred = struct
  type 'a t = 'a Deferred.t
  let all_unit = Deferred.all_unit
  let try_with f = Monitor.try_with ~extract_exn:true f >>= function
    | Core.Std.Result.Ok v -> return (`Ok v)
    | Core.Std.Result.Error exn -> return (`Error exn)

  module List = struct
    let init ~f n = Deferred.List.init ~f n
    let iter ~f l = Deferred.List.iter ~f l
  end

end

let (>>=) = (>>=)
let (>>|) = (>>|)
let return a = return a
let after ms = after (Core.Std.Time.Span.of_ms ms)
let spawn t = don't_wait_for t

module Ivar = struct
  type 'a t = 'a Ivar.t
  let create = Ivar.create
  let create_full = Ivar.create_full
  let fill = Ivar.fill
  let read t = Ivar.read t
  let is_full = Ivar.is_full
  let fill_if_empty = Ivar.fill_if_empty
end

module Reader = struct
  type t = Reader.t
  let close = Reader.close
  let read t buf = Reader.really_read t buf
end

module Writer = struct
  type t = Writer.t
  let write t buf = Writer.write t buf
  let close t = Writer.close t
  let flush t = Writer.flushed t
end

module Tcp = struct
  let connect ?nodelay host port =
    let addr = Tcp.to_host_and_port host port in
    Tcp.connect ~buffer_age_limit:`Unlimited addr >>= fun (s, r, w) ->
    (match nodelay with
     | Some () -> Socket.setopt s Socket.Opt.nodelay true
     | None -> ());
    return (r, w)
end

module Log = struct
  (* Use of a predefiend tag allows the caller to disable logging if needed *)
  let tags = ["library", "amqp_client"]
  let debug fmt = Async.Std.Log.Global.debug ~tags fmt
  let info fmt = Async.Std.Log.Global.info ~tags fmt
  let error fmt = Async.Std.Log.Global.error ~tags fmt
end

(* Pipes *)
module Pipe = struct
  let create () = Pipe.create ()
  let set_size_budget t = Pipe.set_size_budget t
  let flush t = Pipe.downstream_flushed t >>= fun _ -> return ()
  let interleave_pipe t = Pipe.interleave_pipe t
  let write r elm = Pipe.write r elm
  let write_without_pushback r elm = Pipe.write_without_pushback r elm

  let transfer_in ~from t =
    Queue.iter (write_without_pushback t) from;
    return ()

  let close t = Pipe.close t; flush t >>= fun _ -> return ()
  let read r = Pipe.read r
  let iter r ~f = Pipe.iter r ~f
  let iter_without_pushback r ~f = Pipe.iter_without_pushback r ~f

  module Writer = struct
    type 'a t = 'a Pipe.Writer.t
  end
  module Reader = struct
    type 'a t = 'a Pipe.Reader.t
  end

end

module Scheduler = struct
  let go () = Scheduler.go () |> ignore
  let shutdown n = Shutdown.shutdown n
end
