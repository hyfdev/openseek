// The loopback OAuth sign-in (docs/remote-protocol.md, "Desktop sign-in"):
// a one-shot listener on 127.0.0.1:<ephemeral>, the system browser driven
// to the relay's consent page, and the code-for-token exchange that *is*
// device registration.

///|
/// How long the human round-trip through the browser may take.
const SignInTimeoutMs = 300_000

///|
const ExchangeTimeoutMs = 30_000

///|
/// The full sign-in flow against `server_url`. On success the session is
/// committed (memory + auth.json); the caller owns poking the supervisor
/// and publishing `auth.changed`. Raises `AuthError` for every failure a
/// user can act on.
pub async fn AuthStore::sign_in(self : AuthStore, server_url~ : String) -> Unit {
  guard !self.sign_in_active else {
    raise AuthError("a sign-in is already in progress")
  }
  self.sign_in_active = true
  defer {
    self.sign_in_active = false
  }
  // A cancel poked after the previous flow ended must not kill this one.
  for ;; {
    guard (self.sign_in_abort.try_get() catch { _ => None }) is Some(_) else {
      break
    }
  }

  // Secrets first: no OS entropy is a hard failure, never weak randomness.
  guard @entropy.random_hex(32) is Some(verifier) else {
    raise AuthError("no OS entropy available for sign-in")
  }
  guard @entropy.random_hex(16) is Some(oauth_state) else {
    raise AuthError("no OS entropy available for sign-in")
  }
  let challenge = pkce_challenge(verifier)

  // The one-shot loopback listener, on an OS-assigned port.
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0")) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise AuthError("could not open the sign-in listener: \{error}")
  }
  defer server.close()
  let port = server.addr.port()

  // Hand the browser the consent URL.
  let name = match @platform.machine_hostname() {
    Some(hostname) => hostname
    None => "desktop"
  }
  let url = start_url(server_url~, oauth_state~, challenge~, port~, name~)
  let code = @platform.open_url(url) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise AuthError("could not open the system browser: \{error}")
  }
  guard code == 0 else {
    raise AuthError("could not open the system browser (exit \{code})")
  }

  // Wait for the redirect, bounded by the human-round-trip timeout and
  // racing the cancel channel (`auth.cancel` — the Settings page's Cancel
  // button); `any` cancels the losing arms, tearing the wait down.
  let outcome : SignInWait = @async.any([
    () => {
      match
        @async.with_timeout_opt(SignInTimeoutMs, () => {
          wait_for_code(server, oauth_state~)
        }) {
        Some(code) => GotCode(code)
        None => TimedOut
      }
    },
    () => {
      self.sign_in_abort.get()
      CancelledByUser
    },
  ])
  let one_time_code = match outcome {
    GotCode(code) => code
    TimedOut => raise AuthError("sign-in timed out waiting for the browser")
    CancelledByUser => raise AuthError("the sign-in was cancelled")
  }

  // Exchange = device registration.
  let session = exchange_code(server_url~, code=one_time_code, verifier~, name~)

  // Commit: memory + disk, shielded — a persisted token is never half
  // committed by a disconnecting requester.
  @async.protect_from_cancel(() => {
    self.session = Some(session)
    self.connected = false
    if self.runtime_dir is Some(dir) {
      save_session_file(dir, session)
    }
  })
}

///|
/// How the wait for the consent redirect ended.
priv enum SignInWait {
  GotCode(String)
  TimedOut
  CancelledByUser
}

///|
/// Accept loopback connections until one carries the consent redirect.
/// Stray requests (favicon probes, forged or stale redirects) get a 404
/// and the wait continues — a loopback guesser can neither cancel nor
/// complete the flow. A denial from the consent page raises.
async fn wait_for_code(server : @http.Server, oauth_state~ : String) -> String {
  for ;; {
    let (conn, _) = server.accept()
    let outcome = serve_callback(conn, oauth_state~) catch {
      error if @async.is_being_cancelled() => raise error
      // A broken socket must not kill the flow; keep listening.
      _ => continue
    }
    match outcome {
      Granted(code) => return code
      Denied(reason) =>
        raise AuthError("the browser declined the sign-in: \{reason}")
      Stray => continue
    }
  }
}

///|
/// Serve one loopback request and classify it.
async fn serve_callback(
  conn : @http.ServerConnection,
  oauth_state~ : String,
) -> Callback {
  defer conn.close()
  let request = conn.read_request()
  let outcome = parse_callback(request.path, oauth_state~)
  match outcome {
    Granted(_) => respond_html(conn, 200, "OK", SignInDonePage)
    Denied(_) => respond_html(conn, 200, "OK", SignInDeniedPage)
    Stray => respond_html(conn, 404, "Not Found", "not found")
  }
  outcome
}

///|
async fn respond_html(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  body : String,
) -> Unit {
  conn.send_response(code, reason, extra_headers={
    "Content-Type": "text/html; charset=utf-8",
    "Connection": "close",
  })
  conn.write_string(body)
  conn.end_response()
}

///|
const SignInDonePage : String = "<!doctype html><meta charset=\"utf-8\"><title>Signed in</title><body style=\"font-family: system-ui; margin: 4rem auto; max-width: 30rem\"><h1>You're signed in</h1><p>Return to OpenSeek Desktop — you can close this tab.</p>"

///|
const SignInDeniedPage : String = "<!doctype html><meta charset=\"utf-8\"><title>Sign-in cancelled</title><body style=\"font-family: system-ui; margin: 4rem auto; max-width: 30rem\"><h1>Sign-in cancelled</h1><p>Nothing was connected. You can close this tab.</p>"

///|
/// Swap the one-time code (plus the PKCE verifier) for a device token —
/// the exchange creates the device row server-side.
async fn exchange_code(
  server_url~ : String,
  code~ : String,
  verifier~ : String,
  name~ : String,
) -> AuthSession {
  let origin = match server_url.strip_suffix("/") {
    Some(origin) => origin.to_owned()
    None => server_url
  }
  let body : Json = {
    "code": code.to_json(),
    "code_verifier": verifier.to_json(),
    "hostname": name.to_json(),
    "name": name.to_json(),
  }
  guard @async.with_timeout_opt(ExchangeTimeoutMs, () => {
      @http.post("\{origin}/v1/auth/desktop/exchange", body, headers={
        "Content-Type": "application/json",
      }) catch {
        error if @async.is_being_cancelled() => raise error
        error => raise AuthError("the sign-in exchange failed: \{error}")
      }
    })
    is Some((response, data)) else {
    raise AuthError("the sign-in exchange timed out")
  }
  guard response.code == 200 else {
    raise AuthError("the sign-in exchange answered HTTP \{response.code}")
  }
  let json = data.json() catch {
    error if @async.is_being_cancelled() => raise error
    _ => raise AuthError("the sign-in exchange answered malformed JSON")
  }
  guard json
    is {
      "device_token": String(device_token),
      "device": { "id": String(device_id), "name": String(device_name), .. },
      "user": {
        "login": String(user_login),
        "avatar_url": String(user_avatar_url),
        ..
      },
      ..
    } else {
    raise AuthError("the sign-in exchange answered an unexpected shape")
  }
  {
    server_url: origin,
    device_token,
    device_id,
    device_name,
    user_login,
    user_avatar_url,
  }
}
