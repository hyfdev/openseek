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
/// The two queues that make one remote subscription. Opening them also
/// installs the readiness frame: because the fresh bounded outbound queue is
/// empty, that `put` cannot suspend, so no hub publisher can run between
/// subscribe and readiness. Forwarders may only start after this returns.
priv struct ClientSubscription {
  out : @async.Queue[Outgoing]
  notifications : @async.Queue[@api.Notification]
}

///|
async fn open_client_subscription(state : @api.ApiState) -> ClientSubscription {
  let out : @async.Queue[Outgoing] = Queue(kind=Blocking(OutboundQueueCapacity))
  let notifications = state.subscribe()
  // Readiness doubles as the resync hint: the client treats
  // `agent.connected` as "state may have changed, reload". Queue it before
  // any notification forwarder exists, making it this subscription's first
  // outbound frame even if the hub publishes immediately after subscribe.
  out.put(Notify({ method_: "agent.connected", params: Json::empty_object() }))
  { out, notifications }
}

///|
/// An inbound frame, classified for routing.
priv enum Inbound {
  // The raw `id` (echoed back verbatim), the method, and the params.
  Request(Json, String, Json)
  // A client notification: method and params. The sole recognized one is
  // the connection-scoped capability negotiation; unknown notifications
  // remain harmless and are dropped.
  ClientNotification(String, Json)
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
  let subscription = open_client_subscription(state)
  let out = subscription.out
  let notifications = subscription.notifications
  // Local to this WebSocket. The hub and every other transport continue to
  // see the complete legacy stream.
  let durable_session_events = Ref(false)
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
        guard notification_for_client(notification, durable_session_events.val)
          is Some(notification) else {
          continue
        }
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
        ClientNotification(method_, params) =>
          match durable_session_events_capability(method_, params) {
            Some(enabled) => durable_session_events.val = enabled
            None => ()
          }
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
    None => ClientNotification(method_, params)
  }
}

///|
/// Decode the one optional client capability this WebSocket understands.
/// Missing, malformed, and unknown notifications leave the connection's
/// legacy default untouched; an explicit false can turn a prior opt-in off.
fn durable_session_events_capability(method_ : String, params : Json) -> Bool? {
  guard method_ == "client.capabilities" && params is Object(fields) else {
    return None
  }
  match fields.get("durable_session_events") {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
/// Apply the optional connection's delivery profile at the WebSocket edge.
/// Full semantic transcript objects have a canonical `session.event` twin;
/// deltas, metrics, errors, acknowledgements, and lifecycle state pass
/// through. Lifecycle frames carrying large durable text are copied and
/// trimmed so the hub's original notification stays untouched.
fn notification_for_client(
  notification : @api.Notification,
  durable_session_events : Bool,
) -> @api.Notification? {
  if !durable_session_events {
    return Some(notification)
  }
  let method_ = notification.method_
  let params = notification.params
  // A session-less run has no store and therefore no `session.event` twin.
  // Keep its legacy semantic stream intact even on an opted-in connection;
  // the same browser may interleave durable and ephemeral runs.
  let has_durable_session = params is Object(fields) &&
    fields.get("session") is Some(String(session)) &&
    !session.is_empty()
  if method_ == "agent.event" &&
    has_durable_session &&
    params is Object(fields) &&
    fields.get("event") is Some(Object(event)) &&
    event.get("event") is Some(String(event_name)) {
    match event_name {
      // These full messages also settle the preceding delta streams. Keep
      // that state transition while removing the durable text itself.
      "reasoning_message" | "assistant_message" => {
        let lifecycle_event = event.copy()
        lifecycle_event["content"] = Json::string("")
        let lifecycle = fields.copy()
        lifecycle["event"] = Json::object(lifecycle_event)
        return Some({ method_, params: Json::object(lifecycle) })
      }
      "tool_result"
      | "auto_compaction_finished"
      // The separate `agent.finished` frame below keeps the terminal state.
      | "agent_finished"
      | "context_yield" => return None
      // The summary is durable, but this frame also clears the client's
      // compaction lifecycle state; retain its shape with an empty summary.
      "compaction_finished" => {
        let lifecycle_event = event.copy()
        lifecycle_event["summary"] = Json::string("")
        let lifecycle = fields.copy()
        lifecycle["event"] = Json::object(lifecycle_event)
        return Some({ method_, params: Json::object(lifecycle) })
      }
      _ => ()
    }
  }
  // `agent.finished` has no session identity, so the edge cannot prove that
  // its answer has a canonical twin. Preserve the answer for every run.
  if method_ == "agent.started" &&
    has_durable_session &&
    params is Object(fields) {
    // Keep the field so clients with a required-string decoder still accept
    // the run lifecycle frame; the prompt itself arrives as a commit.
    let lifecycle = fields.copy()
    lifecycle["task"] = Json::string("")
    return Some({ method_, params: Json::object(lifecycle) })
  }
  Some(notification)
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

///|
async test "readiness precedes the first forwarded hub notification" {
  let state = @api.ApiState::new(engine="unused")
  let subscription = open_client_subscription(state)
  defer state.unsubscribe(subscription.notifications)
  state.publish("session.event", { "sequence": 1 })
  let notification = subscription.notifications.get()
  assert_true(subscription.out.try_put(Notify(notification)))
  guard subscription.out.get() is Notify(readiness) else {
    fail("expected readiness notification")
  }
  assert_eq(readiness.method_, "agent.connected")
  guard subscription.out.get() is Notify(forwarded) else {
    fail("expected forwarded notification")
  }
  assert_eq(forwarded.method_, "session.event")
}

///|
test "classify keeps client notification method and params" {
  let message : Json = {
    "jsonrpc": "2.0",
    "method": "client.capabilities",
    "params": { "durable_session_events": true },
  }
  match classify(message.stringify()) {
    ClientNotification(
      "client.capabilities",
      { "durable_session_events": True, .. }
    ) => ()
    _ => fail("expected a client capability notification")
  }
}

///|
test "durable session capability accepts booleans only" {
  assert_eq(
    durable_session_events_capability("client.capabilities", {
      "durable_session_events": true,
    }),
    Some(true),
  )
  assert_eq(
    durable_session_events_capability("client.capabilities", {
      "durable_session_events": false,
    }),
    Some(false),
  )
  assert_eq(
    durable_session_events_capability("client.capabilities", {
      "durable_session_events": "true",
    }),
    None,
  )
  assert_eq(
    durable_session_events_capability("client.other", {
      "durable_session_events": true,
    }),
    None,
  )
}

///|
fn expect_notification(value : @api.Notification?) -> @api.Notification raise {
  guard value is Some(notification) else { fail("expected a notification") }
  notification
}

///|
test "legacy clients retain the original notification" {
  let original = @api.Notification::{
    method_: "agent.event",
    params: {
      "session": "session-1",
      "event": { "event": "assistant_message", "content": "answer" },
    },
  }
  let delivered = expect_notification(notification_for_client(original, false))
  assert_true(physical_equal(delivered, original))
}

///|
test "durable clients omit only canonical transcript duplicates" {
  for
    event_name in [
      "tool_result", "auto_compaction_finished", "agent_finished", "context_yield",
    ] {
    assert_true(
      notification_for_client(
        {
          method_: "agent.event",
          params: {
            "session": "session-1",
            "event": { "event": Json::string(event_name) },
          },
        },
        true,
      )
      is None,
    )
  }
}

///|
test "durable clients retain streaming runtime and error events" {
  for
    event_name in [
      "agent_step", "assistant_delta", "reasoning_delta", "usage", "tool_call_decode_error",
      "background_notice", "runtime_update", "steer_applied", "steer_dropped", "agent_aborted",
      "max_steps_exhausted", "agent_setup_failed", "compaction_started", "compaction_failed",
      "unknown_future_event",
    ] {
    assert_true(
      notification_for_client(
        {
          method_: "agent.event",
          params: {
            "session": "session-1",
            "event": { "event": Json::string(event_name) },
          },
        },
        true,
      )
      is Some(_),
    )
  }
  assert_true(
    notification_for_client(
      { method_: "session.event", params: Json::empty_object() },
      true,
    )
    is Some(_),
  )
}

///|
test "durable lifecycle frames keep state and trim transcript text" {
  let started = expect_notification(
    notification_for_client(
      {
        method_: "agent.started",
        params: {
          "run_id": "run-1",
          "session": "session-1",
          "task": "large prompt",
        },
      },
      true,
    ),
  )
  assert_eq(started.params, {
    "run_id": "run-1",
    "session": "session-1",
    "task": "",
  })
  let finished = expect_notification(
    notification_for_client(
      {
        method_: "agent.finished",
        params: {
          "run_id": "run-1",
          "status": "finished",
          "answer": "large answer",
        },
      },
      true,
    ),
  )
  assert_eq(finished.params, {
    "run_id": "run-1",
    "status": "finished",
    "answer": "large answer",
  })
  let compacted = expect_notification(
    notification_for_client(
      {
        method_: "agent.event",
        params: {
          "session": "session-1",
          "event": {
            "event": "compaction_finished",
            "summary": "large summary",
          },
        },
      },
      true,
    ),
  )
  assert_eq(compacted.params, {
    "session": "session-1",
    "event": { "event": "compaction_finished", "summary": "" },
  })
  for event_name in ["reasoning_message", "assistant_message"] {
    let settled = expect_notification(
      notification_for_client(
        {
          method_: "agent.event",
          params: {
            "session": "session-1",
            "event": {
              "event": Json::string(event_name),
              "content": "large content",
            },
          },
        },
        true,
      ),
    )
    assert_eq(settled.params, {
      "session": "session-1",
      "event": { "event": Json::string(event_name), "content": "" },
    })
  }
}

///|
test "durable capability preserves session-less transcript events" {
  let started_params : Json = {
    "run_id": "run-ephemeral",
    "task": "ephemeral prompt",
  }
  let started = expect_notification(
    notification_for_client(
      { method_: "agent.started", params: started_params },
      true,
    ),
  )
  assert_eq(started.params, started_params)
  for
    event_name in [
      "reasoning_message", "assistant_message", "tool_result", "agent_finished",
      "context_yield",
    ] {
    let params : Json = {
      "event": {
        "event": Json::string(event_name),
        "content": "ephemeral content",
      },
    }
    let delivered = expect_notification(
      notification_for_client({ method_: "agent.event", params }, true),
    )
    assert_eq(delivered.params, params)
  }
}

///|
test "empty session is not treated as durable" {
  let params : Json = {
    "session": "",
    "event": { "event": "tool_result", "content": "ephemeral result" },
  }
  let delivered = expect_notification(
    notification_for_client({ method_: "agent.event", params }, true),
  )
  assert_eq(delivered.params, params)
}
