// The sidebar's workspace flow: `pick_workspace` opens the system folder
// chooser, `list_workspaces` reads the attached project directories back,
// and `add_workspace`/`remove_workspace` change the registry. The registry
// ops reply with the updated list, so one decoder serves them all — and
// since attaching or detaching a workspace changes which session groups
// exist, the action commands refresh the session list too.

///|
fn fetch_workspaces(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      // A host without the op just reads as "no workspaces attached".
      let reply = @interop.bridge_request(
        "workspace.list",
        @js.Object::new().to_value(),
      ) catch {
        _ => return
      }
      // A malformed reply is dropped like a failed op: the sidebar keeps
      // whatever list it already shows.
      guard decode_workspaces(@interop.reply_json_text(reply))
        is Some(workspaces) else {
        return
      }
      scheduler.add(dispatch(WorkspacesLoaded(workspaces)))
    })
  })
}

///|
fn add_workspace(dispatch : @cmd.Emit[Msg], path : String) -> @cmd.Cmd {
  workspace_action(dispatch, "workspace.add", path)
}

///|
fn remove_workspace(dispatch : @cmd.Emit[Msg], path : String) -> @cmd.Cmd {
  workspace_action(dispatch, "workspace.remove", path)
}

///|
/// Ask the host to list one directory — the in-app picker's data source.
/// `path` "" starts at the host's home directory. `generation` rides along
/// on the reply so the update can drop answers to superseded navigations.
fn browse_directory(
  dispatch : @cmd.Emit[Msg],
  path : String,
  generation~ : Int,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => {
      let payload = @js.Object::new()
      @interop.set_trimmed(payload, "path", path)
      let reply = @interop.bridge_request("fs.browse", payload.to_value()) catch {
        error => {
          scheduler.add(
            dispatch(
              WorkspacePickerFailed(
                message=@interop.bridge_error_text(error),
                generation~,
              ),
            ),
          )
          return
        }
      }
      match decode_browse(@interop.reply_json_text(reply)) {
        Some((path, entries)) =>
          scheduler.add(
            dispatch(WorkspacePickerLoaded(path~, entries~, generation~)),
          )
        None =>
          scheduler.add(
            dispatch(
              WorkspacePickerFailed(
                message="malformed directory listing",
                generation~,
              ),
            ),
          )
      }
    })
  })
}

///|
/// A browse reply's fields; `None` only for structurally unusable JSON.
fn decode_browse(text : String) -> (String, Array[String])? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(reply) &&
    reply.get("path") is Some(String(path)) &&
    !path.is_empty() else {
    return None
  }
  let entries : Array[String] = []
  if reply.get("entries") is Some(Array(items)) {
    for item in items {
      if item is String(name) && !name.is_empty() {
        entries.push(name)
      }
    }
  }
  Some((path, entries))
}

///|
/// Join a picker entry onto its directory with the separator the host's
/// paths already use, so navigation composes correctly against a Windows
/// host too.
fn joined_path(dir : String, name : String) -> String {
  if dir.has_suffix("/") || dir.has_suffix("\\") {
    dir + name
  } else if dir.contains("\\") {
    dir + "\\" + name
  } else {
    dir + "/" + name
  }
}

///|
fn workspace_action(
  dispatch : @cmd.Emit[Msg],
  op : String,
  path : String,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.async_run(() => workspace_action_into(scheduler, dispatch, op, path))
  })
}

///|
async fn workspace_action_into(
  scheduler : &@cmd.Scheduler,
  dispatch : @cmd.Emit[Msg],
  op : String,
  path : String,
) -> Unit noraise {
  let payload = @js.Object::new()
  payload["path"] = path
  let reply = @interop.bridge_request(op, payload.to_value()) catch {
    error => {
      scheduler.add(
        dispatch(WorkspaceFailed(@interop.bridge_error_text(error))),
      )
      return
    }
  }
  match decode_workspaces(@interop.reply_json_text(reply)) {
    Some(workspaces) => scheduler.add(dispatch(WorkspacesLoaded(workspaces)))
    None => scheduler.add(dispatch(WorkspaceFailed("malformed workspace list")))
  }
  // The registry changed, so the sidebar has a session group to gain or
  // drop; refresh the list that carries them.
  refresh_sessions_into(scheduler, dispatch)
}

///|
/// The reply's registered workspace paths; `None` only for structurally
/// unusable JSON.
fn decode_workspaces(text : String) -> Array[String]? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(reply) else { return None }
  guard reply.get("workspaces") is Some(Array(items)) else { return None }
  let paths : Array[String] = []
  for item in items {
    if item is String(path) && !path.is_empty() {
      paths.push(path)
    }
  }
  Some(paths)
}

///|
/// A workspace's display label: the directory's basename. The host already
/// labels session groups, but the registry itself is bare paths and a
/// workspace with no sessions yet still needs a heading.
fn workspace_label(path : String) -> String {
  // Strip trailing separators, then take everything after the last one.
  let mut end = path.length()
  while end > 0 && is_path_separator(path.code_unit_at(end - 1)) {
    end = end - 1
  }
  let mut start = end
  while start > 0 && !is_path_separator(path.code_unit_at(start - 1)) {
    start = start - 1
  }
  if end > start {
    path.view(start_offset=start, end_offset=end).to_owned()
  } else {
    path
  }
}

///|
fn is_path_separator(unit : UInt16) -> Bool {
  unit == 47 || unit == 92 // '/' or '\'
}

// Tests for the workspace flow's pure pieces: display labels and the
// update handlers that place conversations into workspaces.

///|
test "workspace labels are the folder's basename" {
  inspect(workspace_label("/home/u/proj"), content="proj")
  inspect(workspace_label("/home/u/proj/"), content="proj")
  inspect(workspace_label("C:\\code\\app"), content="app")
  inspect(workspace_label("/"), content="/")
  inspect(workspace_label("plain"), content="plain")
}

///|
test "a workspace new chat rotates into that workspace" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), workspaces: ["/home/u/proj"] }
  let (_, chosen) = update(dispatch, NewChatIn("/home/u/proj"), model)
  inspect(chosen.active_workspace, content="/home/u/proj")
  // The rotation lands like any other; the fresh conversation carries the
  // active workspace, and the next plain "New chat" stays there.
  let (_, rotated) = update(dispatch, SessionRotated("desktop-ws"), chosen)
  assert_true(rotated.active().workspace is Some(Absolute("/home/u/proj")))
  inspect(rotated.active_session, content="desktop-ws")
  inspect(rotated.active_workspace, content="/home/u/proj")
}

///|
test "a scratch rotation leaves the conversation in the default store" {
  let dispatch = test_dispatch()
  let (_, next) = update(dispatch, SessionRotated("desktop-s"), test_model())
  assert_true(next.active().workspace is None)
}

///|
test "workspaces loaded resets placements the registry no longer has" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/gone")),
    }),
    active_workspace: "/gone",
  }
  let (_, next) = update(dispatch, WorkspacesLoaded(["/kept"]), model)
  inspect(next.workspaces.length(), content="1")
  assert_true(next.active().workspace is None)
  inspect(next.active_workspace, content="")
  // A still-registered placement survives the same reply.
  let attached = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      workspace: Some(Absolute("/kept")),
    }),
    active_workspace: "/kept",
  }
  let (_, kept) = update(dispatch, WorkspacesLoaded(["/kept"]), attached)
  assert_true(kept.active().workspace is Some(Absolute("/kept")))
  inspect(kept.active_workspace, content="/kept")
}

///|
test "opening a stored session adopts its workspace" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    sessions: [
      {
        id: "desktop-w",
        title: Some("in project"),
        workspace: "/proj",
        workspace_name: "proj",
      },
    ],
  }
  let (_, opening) = update(dispatch, OpenSession("desktop-w"), model)
  inspect(opening.active_workspace, content="/proj")
  inspect(opening.loading_session, content="desktop-w")
  let (_, loaded) = update(
    dispatch,
    SessionLoaded(session="desktop-w", items=[]),
    opening,
  )
  assert_true(loaded.active().workspace is Some(Absolute("/proj")))
}

///|
test "the picker opens loading and adopts the first listing" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, PickWorkspace, test_model())
  guard opened.workspace_picker is Some(opening) else {
    fail("picker did not open")
  }
  assert_true(opening.loading)
  let (_, loaded) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u", entries=["proj"], generation=1),
    opened,
  )
  guard loaded.workspace_picker is Some(picker) else {
    fail("picker closed by its own listing")
  }
  inspect(picker.path, content="/home/u")
  inspect(picker.input, content="")
  inspect(picker.entries.length(), content="1")
  assert_true(!picker.loading)
}

///|
test "a listing for a closed picker is dropped" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u", entries=[], generation=1),
    test_model(),
  )
  assert_true(next.workspace_picker is None)
}

///|
test "a failed navigation keeps the listing and shows the error" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, PickWorkspace, test_model())
  let (_, loaded) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u", entries=["proj"], generation=1),
    opened,
  )
  let (_, failed) = update(
    dispatch,
    WorkspacePickerFailed(message="no such directory", generation=1),
    loaded,
  )
  guard failed.workspace_picker is Some(picker) else {
    fail("picker closed by a failed navigation")
  }
  inspect(picker.path, content="/home/u")
  inspect(picker.entries.length(), content="1")
  assert_true(picker.error is Some("no such directory"))
}

///|
test "confirming registers the browsed directory and closes the picker" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, PickWorkspace, test_model())
  let (_, loaded) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u/proj", entries=[], generation=1),
    opened,
  )
  let (_, confirmed) = update(dispatch, WorkspacePickerConfirm, loaded)
  assert_true(confirmed.workspace_picker is None)
  // Confirming before anything was browsed has nothing to register and
  // keeps the picker open.
  let (_, early) = update(dispatch, WorkspacePickerConfirm, opened)
  assert_true(early.workspace_picker is Some(_))
}

///|
test "picker paths join with the host's own separator" {
  inspect(joined_path("/home/u", "proj"), content="/home/u/proj")
  inspect(joined_path("/", "etc"), content="/etc")
  inspect(joined_path("C:\\code", "app"), content="C:\\code\\app")
}

///|
test "a workspace failure pops a toast" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    WorkspaceFailed("not a directory"),
    test_model(),
  )
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="Workspace error: not a directory",
  )
}

///|
test "typing in the picker's path field only changes the field" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, PickWorkspace, test_model())
  let (_, loaded) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u", entries=[], generation=1),
    opened,
  )
  let (_, typed) = update(dispatch, WorkspacePickerInput("~/proj"), loaded)
  guard typed.workspace_picker is Some(picker) else {
    fail("picker closed by typing")
  }
  inspect(picker.input, content="~/proj")
  inspect(picker.path, content="/home/u")
}

///|
test "a listing for a superseded navigation is dropped" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, PickWorkspace, test_model())
  let (_, navigated) = update(
    dispatch,
    WorkspacePickerNavigate("/home/u/proj"),
    opened,
  )
  // The reply to the original open (generation 1) lands after a navigation
  // bumped the picker to generation 2: it must not move the picker back.
  let (_, stale) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u", entries=["proj"], generation=1),
    navigated,
  )
  guard stale.workspace_picker is Some(picker) else {
    fail("picker closed by a stale listing")
  }
  assert_true(picker.loading)
  inspect(picker.path, content="")
  let (_, current) = update(
    dispatch,
    WorkspacePickerLoaded(path="/home/u/proj", entries=[], generation=2),
    stale,
  )
  guard current.workspace_picker is Some(picker) else {
    fail("picker closed by the current listing")
  }
  inspect(picker.path, content="/home/u/proj")
  assert_true(!picker.loading)
}
