// The portal's messages and transitions. The root update wraps these —
// `@portal.update` owns everything on the page, the root only threads the
// model through.

///|
/// One device as the relay's list reports it, before this page attaches
/// its probe state.
priv struct DeviceInfo {
  id : String
  name : String
  hostname : String?
  online : Bool
}

///|
enum Msg {
  // `/v1/auth/me` settled.
  MeLoaded(login~ : String, avatar~ : String)
  MeUnauthorized
  // The page-level failure card (auth check unreachable/broken).
  PortalFailed(String)
  // `/v1/devices` settled.
  DevicesLoaded(Array[DeviceInfo])
  DevicesLoadFailed(String)
  // One device's `workspace.list` probe settled; None = unreachable.
  WorkspacesProbed(device~ : String, workspaces~ : Array[String]?)
  // The rename flow: open the field, edit it, commit or drop it.
  RenameStarted(device~ : String, current~ : String)
  RenameEdited(String)
  RenameCancelled
  RenameSubmitted
  // The revoke flow: Delete arms the confirmation, the second click acts.
  DeleteAsked(String)
  DeleteCancelled
  DeleteConfirmed(String)
  // A rename/revoke settled; done refetches the list.
  MutationDone
  MutationFailed(String)
  SignOutClicked
  SignedOut
  // The header's refresh — re-runs the whole load.
  Refresh
}

///|
/// The commands the page boots with.
pub fn init_cmd(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  fetch_me(emit)
}

///|
pub fn update(
  emit : @cmd.Emit[Msg],
  msg : Msg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  match msg {
    MeLoaded(login~, avatar~) =>
      (
        fetch_devices(emit),
        {
          ..model,
          auth: SignedIn(login~, avatar~),
          devices: DevicesLoading,
          notice: None,
        },
      )
    MeUnauthorized =>
      (
        @cmd.none,
        {
          ..model,
          auth: SignedOut,
          devices: DevicesLoading,
          rename: None,
          confirm_delete: None,
          busy: false,
        },
      )
    PortalFailed(message) => (@cmd.none, { ..model, notice: Some(message) })
    DevicesLoaded(devices) => {
      let probes : Array[@cmd.Cmd] = []
      let rows = devices.map(info => {
        if info.online {
          probes.push(probe_workspaces(emit, info.id))
        }
        (
          {
            id: info.id,
            name: info.name,
            hostname: info.hostname,
            online: info.online,
            workspaces: if info.online {
              Probing
            } else {
              NotProbed
            },
          } : DeviceRow)
      })
      (@cmd.batch(probes), { ..model, devices: DevicesReady(rows) })
    }
    DevicesLoadFailed(message) =>
      (@cmd.none, { ..model, devices: DevicesFailed(message) })
    WorkspacesProbed(device~, workspaces~) => {
      guard model.devices is DevicesReady(rows) else {
        return (@cmd.none, model)
      }
      let rows = rows.map(row => {
        if row.id == device {
          {
            ..row,
            workspaces: match workspaces {
              Some(list) => Probed(list)
              None => Unreachable
            },
          }
        } else {
          row
        }
      })
      (@cmd.none, { ..model, devices: DevicesReady(rows) })
    }
    RenameStarted(device~, current~) =>
      (
        @cmd.none,
        {
          ..model,
          rename: Some({ device, input: current }),
          confirm_delete: None,
          notice: None,
        },
      )
    RenameEdited(value) => {
      guard model.rename is Some(rename) else { return (@cmd.none, model) }
      (@cmd.none, { ..model, rename: Some({ ..rename, input: value }) })
    }
    RenameCancelled => (@cmd.none, { ..model, rename: None })
    RenameSubmitted => {
      guard model.rename is Some(rename) && !model.busy else {
        return (@cmd.none, model)
      }
      let name = rename.input.trim().to_owned()
      guard !name.is_empty() else { return (@cmd.none, model) }
      (
        rename_device(emit, rename.device, name),
        { ..model, busy: true, notice: None },
      )
    }
    DeleteAsked(device) =>
      (
        @cmd.none,
        { ..model, confirm_delete: Some(device), rename: None, notice: None },
      )
    DeleteCancelled => (@cmd.none, { ..model, confirm_delete: None })
    DeleteConfirmed(device) => {
      guard !model.busy else { return (@cmd.none, model) }
      (delete_device(emit, device), { ..model, busy: true, notice: None })
    }
    MutationDone =>
      (
        fetch_devices(emit),
        { ..model, busy: false, rename: None, confirm_delete: None },
      )
    MutationFailed(message) =>
      (@cmd.none, { ..model, busy: false, notice: Some(message) })
    SignOutClicked => {
      guard !model.busy else { return (@cmd.none, model) }
      (sign_out(emit), { ..model, busy: true, notice: None })
    }
    SignedOut =>
      (
        @cmd.none,
        {
          ..model,
          auth: SignedOut,
          devices: DevicesLoading,
          rename: None,
          confirm_delete: None,
          busy: false,
        },
      )
    Refresh =>
      (
        init_cmd(emit),
        {
          ..model,
          devices: DevicesLoading,
          rename: None,
          confirm_delete: None,
          notice: None,
        },
      )
  }
}
