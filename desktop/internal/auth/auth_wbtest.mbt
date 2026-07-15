// The pure pieces (PKCE, callback parsing, URLs, the persisted file's
// codec) and the store's transition dedup — everything the live flow in
// signin.mbt is built from.

///|
test "pkce challenge is lowercase hex of the verifier's sha256" {
  inspect(
    pkce_challenge("test-verifier"),
    content=(
      #|2416e2a8e34658f6809b05e4ffc6d3e949e53dfae7eb90f7d9e665252fb3186d
    ),
  )
  // Stable across calls — the exchange must send what start_url promised.
  assert_true(pkce_challenge("v") == pkce_challenge("v"))
}

///|
test "start url carries every parameter, name percent-encoded" {
  inspect(
    start_url(
      server_url="https://relay.example/",
      oauth_state="st123",
      challenge="ch456",
      port=49152,
      name="My Mac (work)",
    ),
    content=(
      #|https://relay.example/v1/auth/desktop/start?state=st123&code_challenge=ch456&code_challenge_method=S256&port=49152&name=My%20Mac%20%28work%29
    ),
  )
}

///|
test "callback parsing: granted, denied, strays" {
  assert_true(
    parse_callback("/cb?code=one-time&state=st", oauth_state="st")
    is Granted("one-time"),
  )
  assert_true(
    parse_callback("/cb?error=access_denied&state=st", oauth_state="st")
    is Denied("access_denied"),
  )
  // Wrong or missing state is a stray, never a denial — a loopback guesser
  // must not be able to end the flow.
  assert_true(
    parse_callback("/cb?code=one-time&state=forged", oauth_state="st") is Stray,
  )
  assert_true(parse_callback("/cb?code=one-time", oauth_state="st") is Stray)
  assert_true(parse_callback("/cb?state=st", oauth_state="st") is Stray)
  assert_true(parse_callback("/favicon.ico", oauth_state="st") is Stray)
  assert_true(
    parse_callback("/cb?code=a%20b&state=st", oauth_state="st")
    is Granted("a b"),
  )
}

///|
test "url derivations" {
  inspect(
    tunnel_url("https://openseek-api.moonbitlang.cn"),
    content="wss://openseek-api.moonbitlang.cn/v1/tunnel",
  )
  inspect(
    tunnel_url("http://127.0.0.1:3000/"),
    content="ws://127.0.0.1:3000/v1/tunnel",
  )
  inspect(
    device_url("https://relay.example", "d_abc"),
    content="https://relay.example/d/d_abc/",
  )
  inspect(
    origin_from_relay_url("wss://relay.example/v1/tunnel"),
    content="https://relay.example",
  )
  inspect(
    origin_from_relay_url("ws://127.0.0.1:8080/v1/tunnel"),
    content="http://127.0.0.1:8080",
  )
}

///|
test "auth.json codec round-trips and reads corruption as signed out" {
  let session : AuthSession = {
    server_url: "https://relay.example",
    device_token: "odt_secret",
    device_id: "d_abc",
    device_name: "My Mac",
    user_login: "octocat",
    user_avatar_url: "https://avatars.example/1",
  }
  let json = session_to_json(session)
  guard session_from_json(json) is Some(reloaded) else {
    fail("round-trip lost the session")
  }
  assert_true(reloaded.device_token == "odt_secret")
  assert_true(reloaded.server_url == "https://relay.example")
  assert_true(session_from_json(Json::null()) is None)
  assert_true(session_from_json({ "server_url": "x" }) is None)
}

///|
async test "auth.json persists 0600 and deletes cleanly" {
  let dir : @path.Path = Path(@fs.tmpdir(prefix="openseek-auth-"))
  let body = async fn() {
    let session : AuthSession = {
      server_url: "https://relay.example",
      device_token: "odt_secret",
      device_id: "d_abc",
      device_name: "My Mac",
      user_login: "octocat",
      user_avatar_url: "",
    }
    save_session_file(dir, session)
    guard load_session_file(dir) is Some(reloaded) else {
      fail("persisted session did not load")
    }
    assert_true(reloaded.device_id == "d_abc")
    delete_session_file(dir)
    assert_true(load_session_file(dir) is None)
  }
  body() catch {
    error => {
      @fs.rmdir(dir.to_string(), recursive=true) catch {
        _ => ()
      }
      raise error
    }
  }
  @fs.rmdir(dir.to_string(), recursive=true) catch {
    _ => ()
  }
}

///|
test "store transitions dedup their auth.changed edges" {
  let store = AuthStore::empty()
  assert_true(store.desired_connector() is None)
  // Signed-in session drives the connector config.
  store.session = Some({
    server_url: "https://relay.example",
    device_token: "odt_secret",
    device_id: "d_abc",
    device_name: "My Mac",
    user_login: "octocat",
    user_avatar_url: "",
  })
  guard store.desired_connector() is Some(config) else {
    fail("signed-in store offered no connector config")
  }
  assert_true(config.relay_url == "wss://relay.example/v1/tunnel")
  // Registration flips once; a repeat is not a visible change.
  assert_true(store.mark_registered("d_abc"))
  assert_false(store.mark_registered("d_abc"))
  assert_true(store.mark_dropped())
  assert_false(store.mark_dropped())
}

///|
async test "a terminal refusal clears a session but only parks an override" {
  let store = AuthStore::empty()
  store.session = Some({
    server_url: "https://relay.example",
    device_token: "odt_secret",
    device_id: "d_abc",
    device_name: "My Mac",
    user_login: "octocat",
    user_avatar_url: "",
  })
  store.connected = true
  store.handle_refusal()
  assert_true(store.session is None)
  assert_false(store.connected)
  assert_true(store.desired_connector() is None)
  let override_store : AuthStore = {
    runtime_dir: None,
    env_override: Some({
      relay_url: "ws://127.0.0.1:8080/v1/tunnel",
      device_token: "dev",
      device_name: "desktop",
    }),
    wakeups: Queue(kind=DiscardOldest(1)),
    session: None,
    connected: false,
    override_device: None,
    rejected: false,
    sign_in_active: false,
  }
  assert_true(override_store.desired_connector() is Some(_))
  override_store.handle_refusal()
  assert_true(override_store.desired_connector() is None)
  assert_true(override_store.managed_by_env())
}

///|
test "status shapes" {
  let store = AuthStore::empty()
  json_inspect(store.status_json(), content={ "connected": false })
  json_inspect(store.status_json(server_url="https://relay.example"), content={
    "connected": false,
    "server_url": "https://relay.example",
  })
  store.session = Some({
    server_url: "https://relay.example",
    device_token: "odt_secret",
    device_id: "d_abc",
    device_name: "My Mac",
    user_login: "octocat",
    user_avatar_url: "https://avatars.example/1",
  })
  store.connected = true
  let status = store.status_json()
  json_inspect(status, content={
    "connected": true,
    "server_url": "https://relay.example",
    "user": { "login": "octocat", "avatar_url": "https://avatars.example/1" },
    "device": {
      "id": "d_abc",
      "name": "My Mac",
      "url": "https://relay.example/d/d_abc/",
    },
  })
  // The token itself never appears in any status.
  assert_false(status.stringify().contains("odt_secret"))
}

///|
async test "the loopback listener takes the matching redirect and ignores strays" {
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let port = server.addr.port()
    let waiter = group.spawn(() => wait_for_code(server, oauth_state="st"))
    // A stray (forged state) answers 404 and keeps the wait alive.
    let (stray, _) = @http.get(
      "http://127.0.0.1:\{port}/cb?code=x&state=forged",
    )
    assert_true(stray.code == 404)
    let (granted, _) = @http.get(
      "http://127.0.0.1:\{port}/cb?code=one-time&state=st",
    )
    assert_true(granted.code == 200)
    assert_true(waiter.wait() == "one-time")
    group.return_immediately(())
  })
}
