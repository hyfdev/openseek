// The relay tunnel's control protocol, shared by the host's connector and
// the relay (docs/remote-protocol.md). It only arranges connections — the
// client protocol itself crosses the relay opaquely, spliced frame-for-frame
// between a browser's WebSocket and a data WebSocket the host dials back.
//
// Control frames are JSON text messages on the long-lived `/tunnel`
// WebSocket the host keeps open to the relay.

///|
pub(all) enum Frame {
  // Host → relay, the first frame: claim a device slot. The relay maps the
  // token to a stable device id (its public route), so the same machine
  // keeps its URL across reconnects.
  Register(token~ : String, name~ : String)
  // Relay → host: the slot is held; `device` is the id in the browser URL.
  Registered(device~ : String)
  // Relay → host: a browser connected to `/d/<device>/api/v1/ws`; dial
  // `GET /tunnel/<stream>` back to serve it.
  Open(stream~ : String)
  // Relay → host: registration rejected (bad token, malformed frame). The
  // host logs it, closes, and retries with backoff.
  Fail(message~ : String)
}

///|
pub fn Frame::encode(self : Frame) -> String {
  let frame : Json = match self {
    Register(token~, name~) =>
      { "type": "register", "device_token": token, "name": name }
    Registered(device~) => { "type": "registered", "device": device }
    Open(stream~) => { "type": "open", "stream": stream }
    Fail(message~) => { "type": "fail", "message": message }
  }
  frame.stringify()
}

///|
/// Decode one control frame; None for anything malformed or unknown — the
/// receiving side treats that as a fatal tunnel error.
pub fn Frame::decode(text : String) -> Frame? {
  let json = @json.parse(text) catch { _ => return None }
  match json {
    {
      "type": "register",
      "device_token": String(token),
      "name": String(name),
      ..
    } => Some(Register(token~, name~))
    { "type": "registered", "device": String(device), .. } =>
      Some(Registered(device~))
    { "type": "open", "stream": String(stream), .. } => Some(Open(stream~))
    { "type": "fail", "message": String(message), .. } => Some(Fail(message~))
    _ => None
  }
}
