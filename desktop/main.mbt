///|
/// Restart delay for the engine pump after a failure — long enough not to
/// spin, short enough that the next prompt finds a live engine host.
const PumpRestartDelayMs = 1_000

///|
async fn main {
  // Hidden probe target: the login-shell environment probe re-execs this
  // binary through the user's shell; print the marker-wrapped JSON
  // environment and quit before any logging or CEF setup.
  if @env.args() is [_, "--print-env-json", mark, ..] {
    @shellenv.print_env_json(mark)
    return
  }
  // Proton runs everything in one process; the executable path locates the
  // bundled frontend assets and the engine binary that ship alongside it.
  let executable = match @env.args().get(0) {
    Some(command) => command
    None => abort("current executable command is unavailable")
  }
  let log = launch_logger()
  log.info() <? { "message": "start" }
  // A Finder/Dock launch inherits only launchd's minimal environment; graft
  // the user's login-shell environment (PATH, custom variables) onto this
  // process before anything downstream — engine, LSP, shell tool — spawns.
  @shellenv.apply_login_shell_env(executable, log)
  let frontend_entry = @host.frontend_entry_path(executable)
  let engine = @engine.engine_command(executable)
  log.info() <? { "message": "host process start" }
  log.info() <? { "message": "frontend entry", "path": frontend_entry }
  let frontend_asset_dir = @host.frontend_asset_dir(frontend_entry)
  log.info() <? { "message": "frontend asset dir", "path": frontend_asset_dir }
  log.info() <? { "message": "engine", "path": engine }
  let runtime_dir = @host.prepared_runtime_dir()
  // The relay sign-in store: a persisted session from auth.json, unless the
  // environment override pins the connector config directly (development).
  let auth = @auth.AuthStore::load(runtime_dir?, env_override?=relay_settings())
  let state = @api.ApiState::new(engine~, runtime_dir?, executable~, auth~, on_finished=payload => {
    notify_run_finished(payload)
  })
  // Proton exposes the `__MoonBit__` bridge — both the ops and the event
  // channel the frontend listens on — only to the `proton://app/` origin its
  // `html()` entry serves from. The window is bridge-only: it makes no HTTP
  // requests at all (a proton:// page's http fetches stall inside CEF's
  // network service). Remote browsers use the same method catalog over the
  // relay WebSocket instead (docs/remote-protocol.md).
  let document = @host.frontend_document(frontend_entry)
  let app = @proton.html("OpenSeek Desktop", document, width=1120, height=760)
    .asset_dir(frontend_asset_dir)
    .debug_level(1)
    .extension(
      @proton_extension.from_command_spec(@extension.openseek_extension(state)),
    )
  @async.with_task_group(group => {
    // The engine pump and the host pumps run for the app's lifetime — they
    // feed every client (the window and any remote browser), not just the
    // webview connection.
    group.spawn_bg(allow_failure=true, () => run_engine_pump_forever(state))
    @host.spawn_host_pumps(group, state.host_state(), (method_, params) => {
      state.publish(method_, params)
    })
    // The connector supervisor runs for the app's lifetime: it registers
    // this host whenever a sign-in (or the environment override) says so,
    // and idles otherwise.
    group.spawn_bg(allow_failure=true, () => {
      @remote.run_supervisor(state, announce=device => {
        log.info() <? { "message": "relay registered", "device": device }
      })
    })
    match app.run() {
      Ok(_) => log.info() <? { "message": "host process exit ok" }
      Err(error) =>
        log.error() <? { "message": "host process error", "error": error }
    }
    // The window is closed: tear the pumps (and with them every serve
    // engine) down rather than wait on their tasks forever.
    group.return_immediately(())
  })
  // A successful `update.apply` swapped the bundle on disk and left a
  // relaunch marker: reopen the new version now that the run loop is done.
  // `open -n` hands the launch to LaunchServices, so the new instance is
  // not our child and this process can exit right after.
  if runtime_dir is Some(dir) &&
    @update.take_relaunch_target(work_dir=dir.to_string()) is Some(target) {
    log.info() <? { "message": "relaunch after update", "path": target }
    let code = @process.run("open", ["-n", target]) catch {
      error => {
        log.error() <? { "message": "relaunch failed", "error": "\{error}" }
        return
      }
    }
    if code != 0 {
      log.error() <? { "message": "relaunch failed", "code": code }
    }
  }
}

///|
/// The development relay override, all-or-nothing from the environment:
/// `OPENSEEK_RELAY_URL` (the relay's `/v1/tunnel` WebSocket URL) and
/// `OPENSEEK_DEVICE_TOKEN` (the secret that keeps this machine's device id
/// stable); `OPENSEEK_DEVICE_NAME` labels the device on the relay's status
/// page and defaults to "desktop". When set it bypasses sign-in entirely.
fn relay_settings() -> @auth.ConnectorConfig? {
  guard @envx.get("OPENSEEK_RELAY_URL") is Some(relay_url) &&
    @envx.get("OPENSEEK_DEVICE_TOKEN") is Some(device_token) else {
    return None
  }
  let device_name = match @envx.get("OPENSEEK_DEVICE_NAME") {
    Some(name) => name
    None => "desktop"
  }
  Some({ relay_url, device_token, device_name })
}

///|
/// Keep the engine pump alive for the app's lifetime. The pump's task group
/// owns every serve subprocess; a failure is reported to every client as an
/// `agent.error` and retried.
async fn run_engine_pump_forever(state : @api.ApiState) -> Unit {
  for ;; {
    let _ = @engine.run_engine_pump(state.sink(), state.manager()) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        state.publish("agent.error", {
          "message": Json::string("engine host failed: \{error}"),
        })
        @async.sleep(PumpRestartDelayMs)
        continue
      }
    }
    @async.sleep(PumpRestartDelayMs)
  }
}
