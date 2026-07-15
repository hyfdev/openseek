// Which engine host a request is for. Every feature package names its
// channel in `bridge_request(channel, op, payload)`; the channel picks the
// transport while method names and payloads stay identical either way
// (docs/remote-protocol.md).

///|
/// One engine host the page can talk to. `Local` is the page's own host —
/// the injected proton bridge in the desktop window; `Device(id)` is a
/// relay device reached over its own WebSocket.
pub(all) enum ChannelId {
  Local
  Device(String)
} derive(Eq, Hash)

///|
/// The channel this page is born with: the desktop webview talks to its
/// local host, a `/d/<device>/` console to that device. `None` on the
/// portal page, which opens no engine connection.
pub fn page_channel() -> ChannelId? {
  if using_proton_bridge() {
    Some(Local)
  } else if page_device_id() is Some(device) {
    Some(Device(device))
  } else {
    None
  }
}
