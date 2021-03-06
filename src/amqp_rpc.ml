open Amqp_thread
module Connection = Amqp_connection
module Channel = Amqp_channel
module Queue = Amqp_queue
module Exchange = Amqp_exchange
module Message = Amqp_message
open Amqp_types
open Amqp_spec.Basic

module Client = struct

  type t = { queue: Queue.t;
             channel: [ `Ok ] Channel.t;
             id: string;
             outstanding: (string, Message.message option Ivar.t) Hashtbl.t;
             mutable counter: int;
             consumer: [ `Ok ] Queue.consumer;
           }

  let handle_reply t ok (content, body) =
    let reply = match ok with
      | true -> Some (content, body)
      | false -> None
    in
    match content.Content.correlation_id with
    | Some id ->
      begin match Hashtbl.find t.outstanding id with
        | var ->
          Ivar.fill var reply;
          Hashtbl.remove t.outstanding id;
          return ()
        | exception Not_found -> failwith ("Unknown correlation id: " ^ id)
      end
    | None -> failwith "No correlation id set"

  let init ~id connection =
    Connection.open_channel ~id:"rpc_client" Channel.no_confirm connection >>= fun channel ->
    let id = Printf.sprintf "%s.%s" (Channel.id channel) id in
    Queue.declare channel
      ~exclusive:true
      ~auto_delete:true
      id >>= fun queue ->

    Queue.bind channel queue Exchange.amq_match (`Headers ["reply_to", VLongstr (Queue.name queue)]) >>= fun () ->

    Queue.consume ~id:"rpc_client" ~no_ack:true ~exclusive:true channel queue >>= fun (consumer, reader) ->
    let t = { queue; channel; id; outstanding = Hashtbl.create 0; counter = 0; consumer } in
    spawn (Pipe.iter reader ~f:(fun { Message.message; routing_key; _ } -> handle_reply t (routing_key = Queue.name queue) message));
    spawn (Pipe.iter (Channel.on_return channel) ~f:(fun (_, message) -> handle_reply t false message));
    return t

  let call t ~ttl ~routing_key ~headers exchange (header, body) =
    let correlation_id = Printf.sprintf "%s.%d" t.id t.counter in
    t.counter <- t.counter + 1;
    (* Register handler for the reply before sending the query *)
    let var = Ivar.create () in
    Hashtbl.add t.outstanding correlation_id var;
    let expiration = Some (string_of_int ttl) in
    (* Set headers so we can get timedout messages *)
    let header = { header with Content.correlation_id = Some correlation_id;
                               expiration;
                               reply_to = Some (Queue.name t.queue);
                               headers = Some (Message.string_header "reply_to" (Queue.name t.queue) :: headers)
                 }
    in
    Exchange.publish t.channel ~mandatory:true ~routing_key exchange (header, body) >>= function
    | `Ok -> Ivar.read var

  (** Release resources *)
  let close t =
    Hashtbl.iter (fun _ var -> Ivar.fill var None) t.outstanding;
    Amqp_queue.cancel t.consumer >>= fun () ->
    Amqp_queue.delete t.channel t.queue >>= fun () ->
    Channel.close t.channel >>= fun () ->
    return ()
end

module Server = struct

  open Amqp_spec.Basic
  (* The server needs a queue name and a handler *)

  type 'a t = { consumer: 'a Queue.consumer }

  let queue_argument = Queue.dead_letter_exchange (Exchange.name Exchange.amq_match)

  let start ?(async=false) ?(discard_redelivered=false) channel queue handler =
    let handler ({ Message.message = (content, body); redelivered; _} as message) =

      let routing_key = match content.Content.reply_to with
        | Some r -> r
        | None -> failwith "Missing reply_to in reposnse"
      in

      let correlation_id = content.Content.correlation_id in
      match redelivered && discard_redelivered with
       | false -> begin
          handler (content, body) >>= fun (content, body) ->
          let content = { content with Content.correlation_id } in
          Exchange.publish channel Exchange.default ~routing_key (content, body) >>= function
          | `Ok -> Message.ack channel message
          | `Failed -> Message.reject ~requeue:true channel message
         end
       | true ->
           Message.reject ~requeue:false channel message
    in
    (* Start consuming. *)
    Queue.consume ~id:"rpc_server" channel queue >>= fun (consumer, reader) ->
    let read = match async with
      | true -> Pipe.iter_without_pushback reader ~f:(fun m -> spawn (handler m))
      | false -> Pipe.iter reader ~f:handler
    in
    spawn read;
    return { consumer }

  let stop t =
    Queue.cancel t.consumer
end
