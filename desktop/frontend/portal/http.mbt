// The portal's transport: the relay's session-cookie HTTP API, and one
// short-lived WebSocket per online device for `workspace.list`. Hand-rolled
// fetch (rather than rabbita's `@http`) because the flows here are
// status-driven — 401 *is* the signed-out signal, and rabbita's package
// treats every completed response as success.

///|
extern "js" fn js_fetch(
  url : String,
  method_ : String,
  has_body : Bool,
  body : String,
  on_done : (Int, String) -> Unit,
  on_fail : (String) -> Unit,
) =
  #| (url, method, hasBody, body, onDone, onFail) => {
  #|   const config = { method };
  #|   if (hasBody) {
  #|     config.headers = { "Content-Type": "application/json" };
  #|     config.body = body;
  #|   }
  #|   fetch(url, config)
  #|     .then((response) => response.text().then((text) => onDone(response.status, text)))
  #|     .catch((error) => onFail(String(error)));
  #| }

///|
/// One `workspace.list` over a fresh protocol WebSocket. Host-pushed
/// notifications (`agent.connected` arrives first on every connection) are
/// skipped in place — only the frame answering request id 1 settles the
/// probe; anything else, including the timeout, fails it.
extern "js" fn js_probe_workspaces(
  url : String,
  request : String,
  timeout_ms : Int,
  on_reply : (String) -> Unit,
  on_fail : () -> Unit,
) =
  #| (url, request, timeoutMs, onReply, onFail) => {
  #|   let settled = false;
  #|   let ws = null;
  #|   const settle = (fn) => {
  #|     if (settled) return;
  #|     settled = true;
  #|     clearTimeout(timer);
  #|     fn();
  #|     if (ws) { try { ws.close(); } catch (_) {} }
  #|   };
  #|   const timer = setTimeout(() => settle(onFail), timeoutMs);
  #|   try {
  #|     ws = new WebSocket(url);
  #|   } catch (_) {
  #|     settle(onFail);
  #|     return;
  #|   }
  #|   ws.onopen = () => { try { ws.send(request); } catch (_) { settle(onFail); } };
  #|   ws.onmessage = (event) => {
  #|     try {
  #|       const frame = JSON.parse(String(event.data));
  #|       if (frame && frame.id === 1) settle(() => onReply(String(event.data)));
  #|     } catch (_) {}
  #|   };
  #|   ws.onerror = () => settle(onFail);
  #|   ws.onclose = () => settle(onFail);
  #| }

///|
const ProbeTimeoutMs = 15_000

///|
/// GET `/v1/auth/me`: 200 is a session, 401 is signed out, anything else
/// is a page-level failure worth a retry button.
fn fetch_me(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    js_fetch(
      "/v1/auth/me",
      "GET",
      false,
      "",
      (status, body) => {
        scheduler.add(
          emit(
            match status {
              200 =>
                match parse_me(body) {
                  Some(msg) => msg
                  None =>
                    PortalFailed("the sign-in check answered malformed JSON")
                }
              401 => MeUnauthorized
              _ => PortalFailed("the sign-in check answered HTTP \{status}")
            },
          ),
        )
      },
      detail => {
        scheduler.add(emit(PortalFailed("the relay is unreachable: \{detail}")))
      },
    )
  })
}

///|
fn parse_me(body : String) -> Msg? {
  guard (@json.parse(body) catch { _ => return None }) is Object(fields) else {
    return None
  }
  guard @jsonx.json_text(fields, "login") is Some(login) else { return None }
  Some(
    MeLoaded(
      login~,
      avatar=@jsonx.json_text(fields, "avatar_url").unwrap_or(""),
    ),
  )
}

///|
/// GET `/v1/devices`. A 401 here means the session expired between
/// requests — fold it into the signed-out state rather than an error.
fn fetch_devices(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    js_fetch(
      "/v1/devices",
      "GET",
      false,
      "",
      (status, body) => {
        scheduler.add(
          emit(
            match status {
              200 =>
                match parse_devices(body) {
                  Some(devices) => DevicesLoaded(devices)
                  None =>
                    DevicesLoadFailed("the device list answered malformed JSON")
                }
              401 => MeUnauthorized
              _ => DevicesLoadFailed("the device list answered HTTP \{status}")
            },
          ),
        )
      },
      detail => {
        scheduler.add(
          emit(DevicesLoadFailed("the relay is unreachable: \{detail}")),
        )
      },
    )
  })
}

///|
fn parse_devices(body : String) -> Array[DeviceInfo]? {
  guard (@json.parse(body) catch { _ => return None }) is Object(fields) else {
    return None
  }
  guard fields.get("devices") is Some(Array(items)) else { return None }
  let devices : Array[DeviceInfo] = []
  for item in items {
    guard item is Object(device) else { continue }
    guard @jsonx.json_text(device, "id") is Some(id) else { continue }
    devices.push({
      id,
      name: @jsonx.json_text(device, "name").unwrap_or(id),
      hostname: @jsonx.json_text(device, "hostname"),
      online: device.get("online") is Some(True),
    })
  }
  Some(devices)
}

///|
/// The error line of a failed mutation: the relay's `{error}` body when it
/// sent one, the HTTP status otherwise.
fn mutation_error(status : Int, body : String) -> String {
  if (@json.parse(body) catch { _ => Json::null() }) is Object(fields) &&
    @jsonx.json_text(fields, "error") is Some(message) {
    return message
  }
  "the relay answered HTTP \{status}"
}

///|
/// PATCH `/v1/devices/:id` with the new name.
fn rename_device(
  emit : @cmd.Emit[Msg],
  device : String,
  name : String,
) -> @cmd.Cmd {
  let body : Json = { "name": name.to_json() }
  @cmd.custom_cmd(scheduler => {
    js_fetch(
      "/v1/devices/\{device}",
      "PATCH",
      true,
      body.stringify(),
      (status, body) => {
        scheduler.add(
          emit(
            if status is (200 | 204) {
              MutationDone
            } else {
              MutationFailed(mutation_error(status, body))
            },
          ),
        )
      },
      detail => {
        scheduler.add(
          emit(MutationFailed("the relay is unreachable: \{detail}")),
        )
      },
    )
  })
}

///|
/// DELETE `/v1/devices/:id` — revoke the device's token and drop any live
/// tunnel.
fn delete_device(emit : @cmd.Emit[Msg], device : String) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    js_fetch(
      "/v1/devices/\{device}",
      "DELETE",
      false,
      "",
      (status, body) => {
        scheduler.add(
          emit(
            if status is (200 | 204) {
              MutationDone
            } else {
              MutationFailed(mutation_error(status, body))
            },
          ),
        )
      },
      detail => {
        scheduler.add(
          emit(MutationFailed("the relay is unreachable: \{detail}")),
        )
      },
    )
  })
}

///|
/// POST `/v1/auth/logout`.
fn sign_out(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    js_fetch(
      "/v1/auth/logout",
      "POST",
      false,
      "",
      (status, body) => {
        scheduler.add(
          emit(
            if status is (200 | 204) {
              SignedOut
            } else {
              MutationFailed(mutation_error(status, body))
            },
          ),
        )
      },
      detail => {
        scheduler.add(
          emit(MutationFailed("the relay is unreachable: \{detail}")),
        )
      },
    )
  })
}

///|
/// Ask one online device for its workspaces over a throwaway protocol
/// WebSocket. `None` means unreachable (offline race, dial-back timeout,
/// malformed reply) — never fatal to the page.
fn probe_workspaces(emit : @cmd.Emit[Msg], device : String) -> @cmd.Cmd {
  let request : Json = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "workspace.list",
    "params": Json::empty_object(),
  }
  @cmd.custom_cmd(scheduler => {
    js_probe_workspaces(
      ws_origin() + "/v1/devices/\{device}/ws",
      request.stringify(),
      ProbeTimeoutMs,
      reply => {
        scheduler.add(
          emit(WorkspacesProbed(device~, workspaces=parse_probe_reply(reply))),
        )
      },
      () => scheduler.add(emit(WorkspacesProbed(device~, workspaces=None))),
    )
  })
}

///|
fn parse_probe_reply(reply : String) -> Array[String]? {
  guard (@json.parse(reply) catch { _ => return None }) is Object(fields) else {
    return None
  }
  guard fields.get("result") is Some(Object(result)) else { return None }
  guard result.get("workspaces") is Some(Array(items)) else { return None }
  let workspaces : Array[String] = []
  for item in items {
    if item is String(path) {
      workspaces.push(path)
    }
  }
  Some(workspaces)
}

///|
/// The page's `ws(s)://host` origin for same-origin WebSocket URLs.
fn ws_origin() -> String {
  guard @interop.page_ws_origin() is Some(origin) else { return "" }
  origin
}
