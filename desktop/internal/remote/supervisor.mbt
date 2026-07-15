// The connector supervisor: the one task that owns "is this host
// registered with a relay". It keeps the running connector matching the
// auth store's desired config — the signed-in session or the environment
// override — restarting on every store poke (sign-in, sign-out, server
// switch) and parking on a terminal relay refusal until a new sign-in
// pokes it awake.

///|
/// Why a connector session ended: the store changed under it, or the
/// relay refused the token.
priv enum SessionEnd {
  Poked
  Refused(String)
}

///|
/// Run for the host's lifetime (spawned once from main). `announce`
/// preserves the startup log line: it fires with the device id on every
/// successful registration.
pub async fn run_supervisor(
  state : @api.ApiState,
  announce~ : (String) -> Unit,
) -> Unit {
  let store = state.auth_store()
  for ;; {
    match store.desired_connector() {
      // Idle: nothing to run until someone pokes the store.
      None => store.wakeups().get()
      Some(config) => {
        let end : SessionEnd = @async.any([
          () => {
            store.wakeups().get()
            Poked
          },
          () => {
            Refused(
              run_connector(
                state,
                relay_url=config.relay_url,
                device_token=config.device_token,
                device_name=config.device_name,
                on_registered=device => {
                  announce(device)
                  if store.mark_registered(device) {
                    state.publish("auth.changed", auth_changed_params(state))
                  }
                },
                on_dropped=() => {
                  if store.mark_dropped() {
                    state.publish("auth.changed", auth_changed_params(state))
                  }
                },
              ),
            )
          },
        ])
        match end {
          // The config changed: `any` already cancelled the old connector
          // (tearing its control socket down); re-read and start over.
          Poked => ()
          Refused(message) => {
            @xlog.warn(category="remote") <?
              { "message": "relay refused registration", "error": message }
            store.handle_refusal()
            state.publish("auth.changed", auth_changed_params(state))
          }
        }
      }
    }
  }
}

///|
/// The `auth.changed` params: the store's status shape. Notifications the
/// supervisor pushes never carry a fallback `server_url` — when nothing is
/// signed in the Settings page derives the selectable server itself.
fn auth_changed_params(state : @api.ApiState) -> Json {
  state.auth_store().status_json()
}
