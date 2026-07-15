// The portal: what the relay serves at `/` (docs/remote-protocol.md,
// "sign-in + device picker"). Signed out it is a GitHub sign-in card;
// signed in it flattens every online device's workspaces into one list —
// each row a link into that device's console — with the device management
// (rename, revoke) underneath. It talks to the relay's own HTTP API with
// the page's session cookie and never opens the protocol WebSocket, except
// one short-lived connection per online device to ask `workspace.list`.

///|
/// Who the relay says we are.
priv enum AuthState {
  // `/v1/auth/me` still in flight.
  Checking
  SignedOut
  SignedIn(login~ : String, avatar~ : String)
}

///|
/// The device list's fetch lifecycle.
priv enum DevicesState {
  DevicesLoading
  DevicesReady(Array[DeviceRow])
  DevicesFailed(String)
}

///|
/// One device the account owns, with its workspace probe.
priv struct DeviceRow {
  id : String
  name : String
  hostname : String?
  online : Bool
  workspaces : ProbeState
}

///|
/// The short-lived `workspace.list` query against one online device.
/// Offline devices are never probed and stay `NotProbed`.
priv enum ProbeState {
  NotProbed
  Probing
  Probed(Array[String])
  Unreachable
}

///|
/// An in-progress rename: which device and the field's current text.
priv struct Rename {
  device : String
  input : String
}

///|
/// The portal page's whole state. Opaque outside this package — the root
/// model carries one when the page boots in portal mode.
struct Model {
  auth : AuthState
  devices : DevicesState
  rename : Rename?
  // The device id whose Delete is waiting for its confirming second click.
  confirm_delete : String?
  // A mutation (rename/revoke/sign-out) on the wire; gates the buttons.
  busy : Bool
  // The last failure, shown inline until the next action clears it.
  notice : String?
}

///|
/// The state the page boots with: nothing known, `/v1/auth/me` on its way.
pub fn Model::init() -> Model {
  {
    auth: Checking,
    devices: DevicesLoading,
    rename: None,
    confirm_delete: None,
    busy: false,
    notice: None,
  }
}
