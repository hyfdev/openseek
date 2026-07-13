// The package's public face: the transport-agnostic host ops — everything
// the desktop host offers a client beyond the engine itself (file browsing,
// language services, skills, self-update, app launching) — dispatched by
// method name. The method names and payload shapes are the wire catalog of
// docs/remote-protocol.md, shared verbatim by the proton bridge and the
// remote WebSocket.

///|
/// A host-side failure with a user-facing message. Ops raise it; the
/// transport boundary stringifies it into the error the client displays.
pub(all) suberror HostError {
  HostError(String)
}

///|
impl Show for HostError with fn output(self, logger) {
  match self {
    HostError(message) => logger.write_string(message)
  }
}

///|
/// A request payload that failed to decode — the client sent a shape the
/// method does not accept. Kept apart from `HostError` so transports can
/// report it as a malformed request (JSON-RPC -32602) rather than a failed
/// operation.
pub(all) suberror PayloadError {
  PayloadError(String)
}

///|
impl Show for PayloadError with fn output(self, logger) {
  match self {
    PayloadError(message) => logger.write_string(message)
  }
}

///|
/// The host ops' shared state: the language-server pool, the self-update
/// staging state, and the workspace watcher's mailbox. One per host process,
/// created beside the engine manager.
struct HostState {
  lsp : LspManager
  updates : UpdateState
  watches : WatchState
}

///|
/// `engine` is the engine executable (the LSP pool spawns the bundled
/// `moon-lsp` resolved next to it); `executable` is the host's own binary,
/// which self-update uses to locate the running .app bundle (absent or
/// non-bundle layouts only lose the in-app install, never the announcement).
pub fn new_host_state(
  engine : String,
  runtime_dir? : @path.Path,
  executable? : String,
) -> HostState {
  let lsp = new_lsp_manager(engine, runtime_dir?)
  // Mirror LSP wire traffic to its own log next to the host's runtime
  // state, so a broken hover/symbol round-trip can be read back without the
  // per-message noise landing in the main app log.
  if runtime_dir is Some(dir) {
    @lsp.enable_traffic_log(dir.join("lsp.log").to_string())
  }
  {
    lsp,
    updates: new_update_state(runtime_dir, executable),
    watches: new_watch_state(),
  }
}

///|
/// The background tasks behind the host ops, spawned into the caller's
/// app-lifetime task group: the LSP pump, the diagnostics forwarder, the
/// workspace watcher, and the one-shot update-leftover sweep. `emit` pushes
/// a notification (method, params) to the client channel — `lsp.diagnostics`
/// and `fs.changed`, the catalog's names. Every pump is best-effort: a
/// language-service or watcher hiccup degrades that feature, never the
/// connection.
pub fn[G] spawn_host_pumps(
  group : @async.TaskGroup[G],
  state : HostState,
  emit : async (String, Json) -> Unit,
) -> Unit {
  group.spawn_bg(allow_failure=true, () => run_lsp_pump(group, state.lsp))
  group.spawn_bg(allow_failure=true, () => {
    run_diagnostics_pump(state.lsp, async fn(push) {
      emit("lsp.diagnostics", push.to_json())
    })
  })
  group.spawn_bg(allow_failure=true, () => {
    run_watch_pump(state.watches, async fn(push) {
      emit("fs.changed", push.to_json())
    })
  })
  group.spawn_bg(allow_failure=true, () => cleanup_updates(state.updates))
}

///|
fn[T : @json.FromJson] decode_payload(payload : Json) -> T raise {
  @json.from_json(payload) catch {
    _ => raise PayloadError("malformed request payload")
  }
}

///|
/// Dispatch one host method by its catalog name, returning its JSON reply —
/// or None for a name this host does not know, which the transport reports
/// as an unknown method rather than a failed op.
pub async fn host_op(state : HostState, op : String, payload : Json) -> Json? {
  match op {
    "skills.catalog" => Some(skills_catalog_op().to_json())
    "skills.install" =>
      Some(install_skill_op(decode_payload(payload)).to_json())
    "skills.installed" => Some(installed_skills_op().to_json())
    "skills.uninstall" =>
      Some(uninstall_skill_op(decode_payload(payload)).to_json())
    "host.open_path" => Some(open_path_op(decode_payload(payload)).to_json())
    "update.check" =>
      Some(check_update_op(state.updates, decode_payload(payload)).to_json())
    "update.download" =>
      Some(download_update_op(state.updates, decode_payload(payload)).to_json())
    "update.apply" => Some(apply_update_op(state.updates).to_json())
    "git.branch" => Some(git_branch_op(decode_payload(payload)).to_json())
    "app.list" => Some(list_apps_op().to_json())
    "app.launch" => Some(launch_app_op(decode_payload(payload)).to_json())
    "fs.read_directory" =>
      Some(read_directory_op(decode_payload(payload)).to_json())
    "fs.list_files" => Some(list_files_op(decode_payload(payload)).to_json())
    "fs.read_file" => Some(read_file_op(decode_payload(payload)).to_json())
    "fs.stat_files" => Some(stat_files_op(decode_payload(payload)).to_json())
    "fs.watch" => {
      watch_workspace_op(state.watches, decode_payload(payload))
      Some(Json::empty_object())
    }
    "fs.unwatch" => {
      unwatch_workspace_op(state.watches)
      Some(Json::empty_object())
    }
    "lsp.hover" =>
      Some(lsp_hover_op(state.lsp, decode_payload(payload)).to_json())
    "lsp.open" =>
      Some(lsp_open_op(state.lsp, decode_payload(payload)).to_json())
    "lsp.workspace_symbols" =>
      Some(workspace_symbols_op(state.lsp, decode_payload(payload)).to_json())
    "fs.browse" => Some(browse_directory_op(decode_payload(payload)).to_json())
    _ => None
  }
}

///|
/// Every host method name, in catalog order — the transport adapters
/// register or advertise exactly this set.
pub fn host_method_names() -> Array[String] {
  [
    "fs.read_file", "fs.read_directory", "fs.list_files", "fs.stat_files", "fs.watch",
    "fs.unwatch", "fs.browse", "lsp.open", "lsp.hover", "lsp.workspace_symbols",
    "skills.catalog", "skills.installed", "skills.install", "skills.uninstall", "update.check",
    "update.download", "update.apply", "app.list", "app.launch", "git.branch", "host.open_path",
  ]
}
