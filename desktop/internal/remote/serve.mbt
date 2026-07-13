// One remote client's connection: JSON-RPC 2.0 over a WebSocket the host
// dialed out through the relay (docs/remote-protocol.md). Requests fan out
// to the shared dispatcher concurrently; notifications flow back from the
// hub. The bridge and this file are the only two transports, and everything
// below the envelope is `@api.dispatch`.

///|
/// Everything the single writer task sends, encoded only at the writer so
/// no other task ever touches the socket.
priv enum Outgoing {
  // A complete JSON-RPC response envelope, built where the request ran.
  Response(Json)
  Notify(@api.Notification)
}

///|
/// An inbound frame, classified for routing.
priv enum Inbound {
  // The raw `id` (echoed back verbatim), the method, and the params.
  Request(Json, String, Json)
  // A client notification — the catalog defines none, so these are dropped.
  ClientNotification
  // Not JSON at all (-32700).
  Unparsable
  // JSON, but not a JSON-RPC request (-32600).
  Invalid
}

///|
/// The client stopped draining and its outbound queue stood full; raising
/// this out of the notification pump is how the connection gets torn down.
priv suberror SlowClient {
  SlowClient(String)
}

///|
const PingIntervalMs = 30_000

///|
/// How many outbound frames may queue before writers suspend. This is also
/// the slow-client limit: a socket that stalls long enough to fill it gets
/// the connection torn down (the pump must not block on a full queue — a
/// blocked `put` cannot be woken by the hub closing the subscription).
const OutboundQueueCapacity = 64

///|
/// JSON-RPC error codes (docs/remote-protocol.md).
const CodeParseError = -32700

///|
const CodeInvalidRequest = -32600

///|
const CodeMethodNotFound = -32601

///|
const CodeInvalidParams = -32602

///|
const CodeInternalError = -32603

///|
const CodeEngineError = -32000

///|
const CodeHostError = -32001

///|
/// Serve one client connection until it closes (or the hub kicks it for
/// not draining notifications). Raises when the connection dies; the
/// caller owns reconnection policy.
pub async fn serve_client(
  state : @api.ApiState,
  conn : @websocket.Conn,
) -> Unit {
  let out : @async.Queue[Outgoing] = Queue(kind=Blocking(OutboundQueueCapacity))
  let notifications = state.subscribe()
  defer state.unsubscribe(notifications)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        let item = out.get()
        conn.send_text(encode_outgoing(item))
      }
    })
    group.spawn_bg(() => {
      // Tears the connection down either way it ends — the client
      // reconnects into a resync: the hub kicking this subscriber (queue
      // closed → `get` raises), or the outbound queue standing full (the
      // socket has stalled for `OutboundQueueCapacity` frames, and the
      // protocol promises a disconnect over a silent gap in the stream).
      for ;; {
        let notification = notifications.get()
        guard out.try_put(Notify(notification)) else {
          raise SlowClient("client not draining notifications")
        }
      }
    })
    group.spawn_bg(() => {
      // Protocol-level keepalive: a dead middlebox connection surfaces as a
      // failed ping write instead of lingering forever.
      for ;; {
        @async.sleep(PingIntervalMs)
        conn.ping()
      }
    })
    // Readiness doubles as the resync hint: the client treats
    // `agent.connected` as "state may have changed, reload".
    out.put(
      Notify({ method_: "agent.connected", params: Json::empty_object() }),
    )
    for ;; {
      let message = conn.recv()
      guard message.kind is Text else {
        // The protocol is JSON text; a binary frame is a peer bug.
        continue
      }
      let text = message.read_all().text()
      match classify(text) {
        Request(id, method_, params) =>
          // Each request runs in its own task so a slow op (an engine
          // start, a big file read) never blocks the reader; replies are
          // correlated by id, not order.
          group.spawn_bg(() => {
            out.put(Response(run_request(state, id, method_, params)))
          })
        ClientNotification => ()
        Unparsable =>
          out.put(
            Response(
              error_envelope(Json::null(), CodeParseError, "unparsable frame"),
            ),
          )
        Invalid =>
          out.put(
            Response(
              error_envelope(
                Json::null(),
                CodeInvalidRequest,
                "not a JSON-RPC request",
              ),
            ),
          )
      }
    }
  })
}

///|
fn encode_outgoing(item : Outgoing) -> String {
  let envelope : Json = match item {
    Response(envelope) => envelope
    Notify(notification) =>
      {
        "jsonrpc": "2.0",
        "method": Json::string(notification.method_),
        "params": notification.params,
      }
  }
  envelope.stringify()
}

///|
fn classify(text : String) -> Inbound {
  let message = @json.parse(text) catch { _ => return Unparsable }
  guard message is Object(fields) else { return Invalid }
  guard fields.get("method") is Some(String(method_)) else { return Invalid }
  let params = match fields.get("params") {
    Some(params) => params
    None => Json::empty_object()
  }
  match fields.get("id") {
    Some(id) => Request(id, method_, params)
    None => ClientNotification
  }
}

///|
/// Run one request through the dispatcher and shape the outcome as a
/// JSON-RPC response, mapping each typed failure to its protocol code.
async fn run_request(
  state : @api.ApiState,
  id : Json,
  method_ : String,
  params : Json,
) -> Json {
  let result = @api.dispatch(state, method_, params) catch {
    error if @async.is_being_cancelled() => raise error
    @api.UnknownMethod(name) =>
      return error_envelope(id, CodeMethodNotFound, "unknown method '\{name}'")
    @host.PayloadError(message) =>
      return error_envelope(id, CodeInvalidParams, message)
    @engine.EngineError(message) =>
      return error_envelope(id, CodeEngineError, message)
    @host.HostError(message) =>
      return error_envelope(id, CodeHostError, message)
    error =>
      return error_envelope(id, CodeInternalError, "internal error: \{error}")
  }
  { "jsonrpc": "2.0", "id": id, "result": result }
}

///|
fn error_envelope(id : Json, code : Int, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json::number(code.to_double()), "message": message },
  }
}
