// The proton command extension: the desktop window's transport. Every
// catalog method is registered as one bridge op that feeds the shared
// dispatcher, so the webview and a remote browser speak the same names and
// payloads (docs/remote-protocol.md) — only the envelope differs. The op
// boundary stringifies raised errors into the rejection the webview
// displays.

///|
/// The extension id; the proton app enables it under this name.
pub const ExtensionId = "openseek-desktop"

///|
/// The `__MoonBit__` property the ops and events hang off:
/// `__MoonBit__.openseek["agent.start"](payload)`, events named
/// `openseek.<method>`.
const ExtensionNamespace = "openseek"

///|
/// The one bridge-only op: the webview calls it once and the call stays
/// open for the webview's lifetime, carrying the hub's notifications out as
/// `openseek.*` events. Not part of the wire catalog — a WebSocket client's
/// subscription is its connection.
const ConnectMethod = "host.connect"

///|
pub fn openseek_extension(
  state : @api.ApiState,
) -> @app.AppCommandExtensionSpec {
  let descriptors = @api.method_names().map(name => {
    @app.AppCommandApiDescriptor::new(name)
  })
  descriptors.push(@app.AppCommandApiDescriptor::new(ConnectMethod))
  @app.AppCommandExtensionSpec::new(
    ExtensionId,
    ExtensionNamespace,
    descriptors,
    context => {
      for name in @api.method_names() {
        context.op_async(name, (params : Json) => {
          @api.dispatch(state, name, params)
        })
      }
      context.op_async(ConnectMethod, (_ : Json) => {
        run_connect(state, context)
        Json::empty_object()
      })
      Ok(())
    },
  )
}

///|
/// Subscribe the webview to the hub and forward notifications as bridge
/// events until the webview goes away (proton cancels the op, running the
/// defer). `agent.connected` is emitted directly on entry: the engine
/// pump's own connected event fired when the pump started, which a webview
/// that (re)loads later never saw — this one is its readiness/resync
/// signal.
async fn run_connect(
  state : @api.ApiState,
  context : @app.AppCommandExtensionContext,
) -> Unit {
  let notifications = state.subscribe()
  defer state.unsubscribe(notifications)
  context.emit("agent.connected", Json::empty_object())
  for ;; {
    let notification = notifications.get()
    context.emit(notification.method_, notification.params)
  }
}
