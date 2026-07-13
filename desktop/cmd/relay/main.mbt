// openseek-relay: the reference relay (docs/remote-protocol.md). Hosts
// behind NAT dial in over the `/tunnel` control WebSocket and register as
// devices; a browser reaches a device's protocol WebSocket at
// `/d/<device>/api/v1/ws`, which the relay pairs with a data WebSocket the
// host dials back and then splices frame-for-frame. The relay serves the
// frontend bundle itself and never parses the client protocol — a protocol
// change touches only the frontend and the host, never this service.
//
// Scope: this is the tunnel core. Real deployments add the account layer in
// front (login, device ownership, TLS, per-account rate limits); the device
// id here is a random token→id mapping with no accounts, which is enough to
// run and test the end-to-end path.

///|
async fn main {
  let matches = cli_command().parse(env=@env.get_env_vars())
  let host = value(matches, "host")
  let port = @string.parse_int(value(matches, "port")) catch {
    _ => fail("--port or OPENSEEK_RELAY_PORT must be an integer")
  }
  let web_dir = value(matches, "web-dir")
  let relay : Relay = {
    web_dir: if web_dir.is_empty() {
      None
    } else {
      Some(web_dir)
    },
    devices: Map([]),
    tokens: Map([]),
    pending: Map([]),
  }
  let addr = @socket.Addr::parse("\{host}:\{port}") catch {
    _ => fail("invalid --host/--port: \{host}:\{port}")
  }
  println("openseek relay: listening on http://\{host}:\{port}")
  println("openseek relay: hosts dial ws://\{host}:\{port}/tunnel")
  let app = @moonback.App(
    Module(ctx => {
      ctx.get("/healthz", (_req, res) => res.send_text("ok"))
      // Operator liveness: how many devices are connected — never which. A
      // device id is the capability that reaches its host (the only barrier
      // while unauthenticated), so ids go only to their owners: the host
      // learns its own at registration and surfaces it in the app.
      ctx.get("/_status", (_req, res) => {
        res.send_json({
          "devices": Json::number(relay.devices.length().to_double()),
        })
      })
      // The control endpoint: a host upgrades here and stays registered for
      // its session.
      ctx.get("/tunnel", (req, res) => serve_control(relay, req, res))
      // A data connection the host dials back for one announced stream.
      ctx.get("/tunnel/:stream", (req, res) => serve_data(relay, req, res))
      // The client protocol's single entry point, spliced through to the
      // device.
      ctx.get("/d/:device/api/v1/ws", (req, res) => {
        serve_browser(relay, req, res)
      })
      // `/d/<id>` and `/d/<id>/` both land here (the trie folds the empty
      // trailing segment into the param route). With the slash, serve the
      // app shell; without it, redirect so the page's document-relative
      // paths keep the `/d/<id>/` prefix.
      ctx.get("/d/:device", (req, res) => {
        if req.path.has_suffix("/") {
          serve_static(relay, "index.html", res)
        } else {
          guard req.params.get("device") is Some(device) else {
            return res.send_json({ "error": "missing device id" }, status=400)
          }
          // Preserve the query across the redirect — whatever the caller
          // put there belongs to the page, not to this hop.
          let location = match req.search {
            Some(search) => "/d/\{device}/?\{search}"
            None => "/d/\{device}/"
          }
          res.send_void(status=302, headers=[("Location", location)])
        }
      })
      // Everything else under a device prefix is a frontend asset, served
      // from the relay's own copy — the bundle never crosses the tunnel.
      ctx.get("/d/:device/*rest", (req, res) => {
        let file = match req.params.get("rest") {
          Some(rest) if !rest.is_empty() => rest.to_owned()
          _ => "index.html"
        }
        serve_static(relay, file, res)
      })
    }),
  )
  defer app.close()
  // reuse_addr so a restart rebinds immediately.
  let server = @http.Server(addr, reuse_addr=true)
  app.serve(server)
}

///|
/// How long a browser connection waits for its device to dial the data
/// WebSocket back before giving up.
const DialBackTimeoutMs = 10_000

///|
/// The relay's live state: connected devices by id, the stable token→id map
/// (in memory — a real deployment persists this per account), and the
/// streams announced but not yet paired.
priv struct Relay {
  web_dir : String?
  devices : Map[String, Device]
  tokens : Map[String, String]
  pending : Map[String, PendingStream]
}

///|
/// One registered host. `out` is drained by a single writer task per
/// control connection, which encodes frames at the socket — no other task
/// touches the wire.
priv struct Device {
  name : String
  out : @async.Queue[@tunnel.Frame]
}

///|
/// A stream the relay has announced to a device: the rendezvous between the
/// waiting browser handler and the data connection the host dials back.
priv struct PendingStream {
  // Capacity 1: the data handler delivers its upgraded connection here.
  conn : @async.Queue[@websocket.Conn]
  // Never receives a value; the browser handler closes it when the splice
  // ends, releasing the data handler that owns the socket.
  released : @async.Queue[Unit]
}

///|
/// A host's control session: register it as a device, forward `open`
/// announcements from its queue, and hold the registration until the
/// socket drops.
async fn serve_control(
  relay : Relay,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  let ws = res.upgrade(req)
  defer ws.close()
  let first = ws.recv().read_all().text()
  guard @tunnel.Frame::decode(first) is Some(Register(token~, name~)) else {
    ws.send_text(
      (Fail(message="expected a register frame") : @tunnel.Frame).encode(),
    )
    return
  }
  let id = relay.device_id_for(token) catch {
    EntropyUnavailable => {
      ws.send_text(
        (
          Fail(message="relay cannot mint device ids: OS entropy unavailable") :
          @tunnel.Frame).encode(),
      )
      return
    }
  }
  let device : Device = {
    name,
    // Bounded so a stalled control socket suspends the browser handlers
    // announcing streams into it instead of buffering without limit.
    out: Queue(kind=Blocking(64)),
  }
  relay.devices[id] = device
  // The map entry is removed only if it is still this session's device: a
  // replacement connection for the same token may have registered while
  // this handler unwound, and its entry must survive this defer.
  defer (if relay.devices.get(id) is Some(current) &&
    physical_equal(current, device) {
    relay.devices.remove(id)
  })
  ws.send_text((Registered(device=id) : @tunnel.Frame).encode())
  println("openseek relay: device '\{id}' (\{device.name}) connected")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        ws.send_text(device.out.get().encode())
      }
    })
    // The host sends nothing after registering; this read exists to notice
    // the socket closing (recv raises), which tears the session down.
    for ;; {
      let message = ws.recv()
      // Drain and discard — a well-behaved host never gets here.
      let _ = message.read_all()
    }
  })
}

///|
/// One browser client: announce a stream to the device, wait for the host
/// to dial back, then splice the two sockets until either side hangs up.
async fn serve_browser(
  relay : Relay,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard req.params.get("device") is Some(id) else {
    return res.send_json({ "error": "missing device id" }, status=400)
  }
  guard relay.devices.get(id.to_owned()) is Some(device) else {
    return res.send_json({ "error": "device offline" }, status=502)
  }
  let stream = mint_id("s") catch {
    EntropyUnavailable =>
      return res.send_json(
        { "error": "relay cannot mint stream ids" },
        status=503,
      )
  }
  let entry : PendingStream = {
    conn: Queue(kind=Blocking(1)),
    released: Queue(kind=Blocking(1)),
  }
  relay.pending[stream] = entry
  defer relay.pending.remove(stream)
  device.out.put(Open(stream~))
  // Upgrade only once the rendezvous is armed: from here on the browser
  // socket is ours to close.
  let browser = res.upgrade(req)
  defer browser.close()
  // When the splice ends — either peer hanging up, or the timeout below —
  // release the data handler blocked on this queue.
  defer entry.released.close()
  guard @async.with_timeout_opt(DialBackTimeoutMs, () => entry.conn.get())
    is Some(data) else {
    return
  }
  splice(browser, data) catch {
    error if @async.is_being_cancelled() => raise error
    // Either peer hanging up is the normal end of a splice.
    _ => ()
  }
}

///|
/// The host dialed back for one announced stream: hand the socket to the
/// waiting browser handler and hold it open until the splice ends.
async fn serve_data(
  relay : Relay,
  req : @moonback.Request,
  res : @moonback.Responder,
) -> Unit {
  guard req.params.get("stream") is Some(stream) else {
    return res.send_json({ "error": "missing stream id" }, status=400)
  }
  let stream = stream.to_owned()
  // Claim the rendezvous — each stream id pairs exactly one connection.
  guard relay.pending.get(stream) is Some(entry) else {
    return res.send_json({ "error": "unknown stream" }, status=404)
  }
  relay.pending.remove(stream)
  let ws = res.upgrade(req)
  defer ws.close()
  entry.conn.put(ws) catch {
    error if @async.is_being_cancelled() => raise error
    // The browser handler gave up (timeout) between our claim and this
    // put; the socket just closes.
    _ => return
  }
  // Block until the browser handler closes `released` — it owns the splice;
  // this handler only owns the socket's lifetime.
  entry.released.get() catch {
    error if @async.is_being_cancelled() => raise error
    _ => ()
  }
}

///|
/// Pump frames both ways until either socket closes, which raises out of
/// the group and cancels the other pump.
async fn splice(a : @websocket.Conn, b : @websocket.Conn) -> Unit {
  @async.with_task_group(group => {
    group.spawn_bg(() => pump(a, b))
    group.spawn_bg(() => pump(b, a))
  })
}

///|
async fn pump(from : @websocket.Conn, to : @websocket.Conn) -> Unit {
  for ;; {
    let message = from.recv()
    let data = message.read_all()
    match message.kind {
      Text => to.send_text(data.text())
      Binary => to.send_binary(data.binary())
    }
  }
}

///|
/// The stable device id for a host's token: minted once (random, so it
/// never leaks the secret token — and unguessable, which is the only
/// barrier in front of an unauthenticated host) and reused on reconnect.
fn Relay::device_id_for(
  self : Relay,
  token : String,
) -> String raise EntropyUnavailable {
  if self.tokens.get(token) is Some(id) {
    return id
  }
  let id = mint_id("d")
  self.tokens[token] = id
  id
}

///|
/// OS entropy answered nothing, so no id can be minted. Unguessability is
/// the security model — a predictable id hands the device to anyone who can
/// count — so the requester is refused, never given a weaker id.
priv suberror EntropyUnavailable

///|
/// A fresh unguessable id with a readable prefix.
fn mint_id(prefix : String) -> String raise EntropyUnavailable {
  guard @entropy.random_hex(8) is Some(hex) else { raise EntropyUnavailable }
  "\{prefix}\{hex}"
}

///|
async fn serve_static(
  relay : Relay,
  rel : String,
  res : @moonback.Responder,
) -> Unit {
  guard relay.web_dir is Some(dir) else {
    return res.send_text("no --web-dir configured", status=404)
  }
  if rel.contains("..") || rel.contains("\\") {
    return res.send_text("bad path", status=400)
  }
  let full = "\{dir}/\{rel}"
  if !@fs.exists(full) {
    return res.send_text("missing \{rel}", status=404)
  }
  let data = @fs.read_file(full) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return res.send_text("read failed", status=500)
  }
  let out = res.respond(headers=[("Content-Type", content_type(rel))])
  @io.Writer::write(out, data)
}

///|
fn content_type(path : String) -> String {
  if path.has_suffix(".html") {
    "text/html; charset=utf-8"
  } else if path.has_suffix(".js") || path.has_suffix(".mjs") {
    "text/javascript; charset=utf-8"
  } else if path.has_suffix(".css") {
    "text/css; charset=utf-8"
  } else if path.has_suffix(".json") || path.has_suffix(".map") {
    "application/json; charset=utf-8"
  } else if path.has_suffix(".svg") {
    "image/svg+xml"
  } else if path.has_suffix(".png") {
    "image/png"
  } else if path.has_suffix(".ico") {
    "image/x-icon"
  } else if path.has_suffix(".woff2") {
    "font/woff2"
  } else if path.has_suffix(".ttf") {
    "font/ttf"
  } else {
    "application/octet-stream"
  }
}

///|
fn value(matches : @argparse.Matches, name : String) -> String {
  match matches.values.get(name) {
    Some([first, ..]) => first
    _ => ""
  }
}

///|
fn cli_command() -> @argparse.Command {
  Command(
    "openseek-relay",
    about="WebSocket-splicing relay: hosts dial in, browsers reach them at /d/<device>/.",
    options=[
      OptionArg(
        "host",
        long="host",
        env="OPENSEEK_RELAY_HOST",
        default_values=["0.0.0.0"],
        about="Interface address to bind.",
      ),
      OptionArg(
        "port",
        long="port",
        env="OPENSEEK_RELAY_PORT",
        default_values=["8080"],
        about="TCP port to listen on.",
      ),
      OptionArg(
        "web-dir",
        long="web-dir",
        env="OPENSEEK_RELAY_WEB_DIR",
        default_values=[""],
        about="Directory of frontend assets served under /d/<device>/.",
      ),
    ],
  )
}
