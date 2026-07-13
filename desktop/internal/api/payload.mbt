// The engine-side methods' request payloads (docs/remote-protocol.md),
// decoded from `params` and translated to the engine package's requests.
// Host-side method payloads live in internal/host/protocol.mbt.

///|
priv struct StartPayload {
  task : String
  api_key : String?
  api_url : String?
  model : String?
  max_steps : Int?
  session : String?
  session_root : String?
  // A registered workspace directory to run in; absent = scratch workspace.
  workspace : String?
  // Present = run the engine inside WSL (Windows only); absent = native.
  wsl : WslPayload?
} derive(FromJson)

///|
priv struct WslPayload {
  distro : String?
  engine : String?
} derive(FromJson)

///|
fn WslPayload::to_request(self : WslPayload) -> @engine.WslRequest {
  { distro: self.distro, engine: self.engine }
}

///|
fn StartPayload::to_request(self : StartPayload) -> @engine.StartRequest {
  {
    task: self.task,
    api_key: self.api_key,
    api_url: self.api_url,
    model: self.model,
    max_steps: self.max_steps,
    session: self.session,
    session_root: self.session_root,
    workspace: self.workspace,
    wsl: self.wsl.map(wsl => wsl.to_request()),
  }
}

///|
priv struct CancelPayload {
  run_id : Int?
} derive(FromJson)

///|
fn CancelPayload::to_request(self : CancelPayload) -> @engine.CancelRequest {
  { run_id: self.run_id }
}

///|
priv struct SteerPayload {
  text : String
  run_id : Int?
} derive(FromJson)

///|
fn SteerPayload::to_request(self : SteerPayload) -> @engine.SteerRequest {
  { text: self.text, run_id: self.run_id }
}

///|
/// A compact carries the same engine settings as a start (minus the task):
/// a conversation resumed after a restart has no live serve process, and
/// compacting it spawns one with these settings.
priv struct CompactPayload {
  session : String
  api_key : String?
  api_url : String?
  model : String?
  max_steps : Int?
  session_root : String?
  workspace : String?
  wsl : WslPayload?
} derive(FromJson)

///|
fn CompactPayload::to_request(self : CompactPayload) -> @engine.CompactRequest {
  {
    session: self.session,
    api_key: self.api_key,
    api_url: self.api_url,
    model: self.model,
    max_steps: self.max_steps,
    session_root: self.session_root,
    workspace: self.workspace,
    wsl: self.wsl.map(wsl => wsl.to_request()),
  }
}

///|
priv struct LoadSessionPayload {
  session : String
  // The workspace whose store holds the session, when the client knows it.
  workspace : String?
} derive(FromJson)

///|
fn LoadSessionPayload::to_request(
  self : LoadSessionPayload,
) -> @engine.LoadSessionRequest {
  { session: self.session, workspace: self.workspace }
}

///|
/// `workspace.add` / `workspace.remove` name the project directory to
/// attach or detach.
priv struct WorkspacePayload {
  path : String
} derive(FromJson)

///|
/// `session.archive` / `session.unarchive` address a conversation by its
/// durable session id.
priv struct SessionPayload {
  session : String
} derive(FromJson)
