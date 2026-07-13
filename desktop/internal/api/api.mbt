// The one method dispatcher behind every transport. The proton bridge and
// each remote WebSocket feed the same catalog (docs/remote-protocol.md)
// through `dispatch`; they differ only in envelope. Errors stay typed so
// each transport maps them to its own vocabulary: `@host.PayloadError` =
// malformed params, `@engine.EngineError` / `@host.HostError` = the op
// failed, `UnknownMethod` = a name outside the catalog.

///|
/// A method name this host does not serve.
pub(all) suberror UnknownMethod {
  UnknownMethod(String)
}

///|
impl Show for UnknownMethod with fn output(self, logger) {
  match self {
    UnknownMethod(method_) => logger.write_string("unknown method '\{method_}'")
  }
}

///|
/// Everything the methods operate on: the engine manager (one serve process
/// per conversation), the host-op state (LSP pool, updates, watcher), and
/// the notification hub. One per host process.
struct ApiState {
  manager : @engine.EngineManager
  host : @host.HostState
  hub : Hub
  // Called for every finished run, alongside the notification fan-out — the
  // desktop posts its system notification here.
  on_finished : ((@engine.FinishedPayload) -> Unit)?
}

///|
/// `engine` is the engine executable; `executable` is the host's own
/// binary, which self-update uses to locate the running .app bundle (absent
/// or non-bundle layouts only lose the in-app install, never the
/// announcement).
pub fn ApiState::new(
  engine~ : String,
  runtime_dir? : @path.Path,
  executable? : String,
  on_finished? : (@engine.FinishedPayload) -> Unit,
) -> ApiState {
  {
    manager: @engine.new_engine_manager(engine, runtime_dir?),
    host: @host.new_host_state(engine, runtime_dir?, executable?),
    hub: Hub::new(),
    on_finished,
  }
}

///|
/// The engine event sink: fan out to every subscriber, and hand finished
/// runs to the notification hook.
pub fn ApiState::sink(self : ApiState) -> @engine.EventSink {
  self.hub.sink(on_finished?=self.on_finished)
}

///|
/// Register a notification subscriber: a bounded queue the hub pushes every
/// notification into. The caller drains it with `get` and MUST `unsubscribe`
/// when done (a defer next to the subscribe). A subscriber that stops
/// draining is kicked by the hub: its queue is closed, which ends the
/// drain loop.
pub fn ApiState::subscribe(self : ApiState) -> @async.Queue[Notification] {
  self.hub.subscribe()
}

///|
pub fn ApiState::unsubscribe(
  self : ApiState,
  queue : @async.Queue[Notification],
) -> Unit {
  self.hub.unsubscribe(queue)
}

///|
/// Publish one notification to every subscriber — the host pumps
/// (`lsp.diagnostics`, `fs.changed`) go through here.
pub fn ApiState::publish(
  self : ApiState,
  method_ : String,
  params : Json,
) -> Unit {
  self.hub.publish(method_, params)
}

///|
/// The host-op state, for the pumps spawned beside the dispatcher.
pub fn ApiState::host_state(self : ApiState) -> @host.HostState {
  self.host
}

///|
/// The engine manager, for the engine pump that owns the serve processes.
pub fn ApiState::manager(self : ApiState) -> @engine.EngineManager {
  self.manager
}

///|
fn[T : @json.FromJson] decode(params : Json) -> T raise {
  @json.from_json(params) catch {
    _ => raise @host.PayloadError("malformed request payload")
  }
}

///|
/// Serve one method call. Every transport funnels through here.
pub async fn dispatch(
  state : ApiState,
  method_ : String,
  params : Json,
) -> Json {
  match method_ {
    "agent.start" => {
      let payload : StartPayload = decode(params)
      @engine.start_run(state.sink(), state.manager, payload.to_request()).to_json()
    }
    "agent.cancel" => {
      let payload : CancelPayload = decode(params)
      @engine.cancel_run(state.manager, payload.to_request()).to_json()
    }
    "agent.steer" => {
      let payload : SteerPayload = decode(params)
      @engine.steer_run(state.manager, payload.to_request()).to_json()
    }
    "agent.compact" => {
      let payload : CompactPayload = decode(params)
      @engine.compact_run(state.manager, payload.to_request()).to_json()
    }
    "agent.runs" => state.hub.runs()
    "session.list" => @engine.list_sessions(state.manager).to_json()
    "session.load" => {
      let payload : LoadSessionPayload = decode(params)
      @engine.load_session(state.manager, payload.to_request()).to_json()
    }
    "session.list_archived" =>
      @engine.archived_sessions(state.manager).to_json()
    "session.archive" => {
      let payload : SessionPayload = decode(params)
      @engine.archive_session(state.manager, payload.session).to_json()
    }
    "session.unarchive" => {
      let payload : SessionPayload = decode(params)
      @engine.unarchive_session(state.manager, payload.session).to_json()
    }
    "workspace.list" => @engine.list_workspaces().to_json()
    "workspace.add" => {
      let payload : WorkspacePayload = decode(params)
      @engine.attach_workspace(payload.path).to_json()
    }
    "workspace.remove" => {
      let payload : WorkspacePayload = decode(params)
      @engine.detach_workspace(payload.path).to_json()
    }
    "host.meta" => { "protocol": 2, "name": "openseek-host" }
    _ =>
      match @host.host_op(state.host, method_, params) {
        Some(reply) => reply
        None => raise UnknownMethod(method_)
      }
  }
}

///|
/// Every method in the catalog — the transport adapters register exactly
/// this set.
pub fn method_names() -> Array[String] {
  [
    "agent.start", "agent.cancel", "agent.steer", "agent.compact", "agent.runs",
    "session.list", "session.load", "session.list_archived", "session.archive", "session.unarchive",
    "workspace.list", "workspace.add", "workspace.remove", "host.meta",
  ] +
  @host.host_method_names()
}
