// The relay connector: the host's only outward face. It keeps one control
// WebSocket registered with the relay and dials one data WebSocket back per
// browser client the relay announces; each data connection is served by the
// same dispatcher the desktop bridge feeds (docs/remote-protocol.md).

///|
priv suberror ConnectorError {
  ConnectorError(String)
}

///|
impl Show for ConnectorError with fn output(self, logger) {
  match self {
    ConnectorError(message) => logger.write_string(message)
  }
}

///|
const ReconnectDelayMs = 3_000

///|
/// Run the connector for the host's lifetime: keep one control connection
/// registered, reconnecting after any drop. `announce` is called with the
/// device id each time the relay registers this machine, so the caller can
/// surface the reachable URL.
pub async fn run_connector(
  state : @api.ApiState,
  relay_url~ : String,
  device_token~ : String,
  device_name~ : String,
  announce~ : (String) -> Unit,
) -> Unit {
  for ;; {
    connect_once(state, relay_url, device_token, device_name, announce) catch {
      error if @async.is_being_cancelled() => raise error
      error =>
        @xlog.warn(category="remote") <?
          { "message": "relay connection lost", "error": "\{error}" }
    }
    @async.sleep(ReconnectDelayMs)
  }
}

///|
/// One control session: register, then serve `open` announcements until the
/// connection drops, which raises out of here for `run_connector` to retry.
async fn connect_once(
  state : @api.ApiState,
  relay_url : String,
  device_token : String,
  device_name : String,
  announce : (String) -> Unit,
) -> Unit {
  let control = @websocket.Conn::connect(relay_url)
  defer control.close()
  control.send_text(
    (Register(token=device_token, name=device_name) : @tunnel.Frame).encode(),
  )
  guard @tunnel.Frame::decode(control.recv().read_all().text()) is Some(frame) else {
    raise ConnectorError("relay sent an undecodable control frame")
  }
  let device = match frame {
    Registered(device~) => device
    Fail(message~) =>
      raise ConnectorError("relay refused registration: \{message}")
    Register(..) | Open(..) =>
      raise ConnectorError("relay broke the control protocol")
  }
  announce(device)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        @async.sleep(PingIntervalMs)
        control.ping()
      }
    })
    for ;; {
      guard @tunnel.Frame::decode(control.recv().read_all().text())
        is Some(frame) else {
        raise ConnectorError("relay sent an undecodable control frame")
      }
      match frame {
        // One task per client: a data connection that fails (or a client
        // that misbehaves) never touches the control channel or the other
        // clients.
        Open(stream~) =>
          group.spawn_bg(allow_failure=true, () => {
            serve_stream(state, data_url(relay_url, stream))
          })
        Fail(message~) =>
          raise ConnectorError("relay reported failure: \{message}")
        Registered(..) | Register(..) =>
          raise ConnectorError("relay broke the control protocol")
      }
    }
  })
}

///|
async fn serve_stream(state : @api.ApiState, url : String) -> Unit {
  let conn = @websocket.Conn::connect(url)
  defer conn.close()
  serve_client(state, conn) catch {
    error if @async.is_being_cancelled() => raise error
    // A remote client hanging up mid-run is routine, not a connector
    // failure.
    _ => ()
  }
}

///|
/// The data WebSocket for one announced stream: the control URL with the
/// stream id appended (`…/tunnel` → `…/tunnel/<stream>`).
fn data_url(relay_url : String, stream : String) -> String {
  match relay_url.strip_suffix("/") {
    Some(base) => "\{base}/\{stream}"
    None => "\{relay_url}/\{stream}"
  }
}
