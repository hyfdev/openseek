// The auth.* op bodies (docs/remote-protocol.md): they run the sign-in
// flows in `internal/auth` and translate its errors into the transports'
// `HostError` vocabulary. They live here — not in `internal/auth` — so
// `auth.changed` can go through the hub, and the connector supervisor
// (internal/remote, which imports this package) stays cycle-free.

///|
/// The current status. The fallback `server_url` is the settings' server
/// selection — present only when that server has a relay to sign in to.
async fn auth_status(state : ApiState) -> Json {
  state.auth.status_json(server_url?=@engine.remote_server_base(state.manager))
}

///|
/// Run the loopback sign-in against the selected server, then wake the
/// connector. Signed in already means "make sure the connector runs", not
/// a second browser round-trip — every exchange mints a new device row
/// server-side, so re-running the flow would duplicate the device.
async fn auth_connect(state : ApiState) -> Json {
  let store = state.auth
  if store.managed_by_env() {
    raise @host.HostError(
      "remote access is configured through OPENSEEK_RELAY_URL/OPENSEEK_DEVICE_TOKEN",
    )
  }
  if store.signed_in() {
    store.poke()
    return auth_status(state)
  }
  guard @engine.remote_server_base(state.manager) is Some(server_url) else {
    raise @host.HostError(
      "remote access needs the OpenSeek server; select it in Settings",
    )
  }
  store.sign_in(server_url~) catch {
    error if @async.is_being_cancelled() => raise error
    @auth.AuthError(message) => raise @host.HostError(message)
    error => raise @host.HostError("sign-in failed: \{error}")
  }
  // The token is persisted: the wake-up and the announcement must not be
  // lost to a disconnecting requester.
  @async.protect_from_cancel(() => {
    store.poke()
    state.hub.publish("auth.changed", store.status_json())
  })
  auth_status(state)
}

///|
/// Sign out: local delete always wins, the relay-side revoke is
/// best-effort, and the supervisor parks once poked.
async fn auth_disconnect(state : ApiState) -> Json {
  let store = state.auth
  if store.managed_by_env() {
    raise @host.HostError("remote access is configured through the environment")
  }
  store.sign_out() catch {
    error if @async.is_being_cancelled() => raise error
    @auth.AuthError(message) => raise @host.HostError(message)
    error => raise @host.HostError("sign-out failed: \{error}")
  }
  @async.protect_from_cancel(() => {
    store.poke()
    state.hub.publish("auth.changed", store.status_json())
  })
  auth_status(state)
}

///|
/// A server switch orphans a sign-in — the device token belongs to the
/// server that issued it. Called after every settings commit; a no-op
/// unless the signed-in issuer no longer matches the selection.
async fn sign_out_after_server_switch(state : ApiState) -> Unit {
  let store = state.auth
  guard !store.managed_by_env() && store.signed_in() else { return }
  if store.session_server() == @engine.remote_server_base(state.manager) {
    return
  }
  store.sign_out() catch {
    error if @async.is_being_cancelled() => raise error
    @auth.AuthError(message) =>
      @xlog.warn(category="auth") <?
        { "message": "sign-out after server switch failed", "error": message }
    error =>
      @xlog.warn(category="auth") <?
        {
          "message": "sign-out after server switch failed",
          "error": "\{error}",
        }
  }
  @async.protect_from_cancel(() => {
    store.poke()
    state.hub.publish("auth.changed", store.status_json())
  })
}
