# OpenSeek Remote Protocol (v2)

The wire protocol between a browser client and an OpenSeek **host process**
— the desktop app's native process, which owns the engine and the host ops.
The host runs no server: at startup it dials out to a **relay** and
registers; browsers reach it through the relay, which serves the frontend
bundle and splices WebSockets without understanding a byte of the protocol.

The desktop window itself does not use this protocol. It talks to the host
over proton's in-process `__MoonBit__` bridge — same method catalog, same
payloads, no wire. The frontend picks its transport by origin: a `proton://`
page uses the bridge, anything else opens the WebSocket below.

This document is the contract. The implementation follows it, not the other
way around.

## Transport

All HTTP lives at the relay. Pages and assets are unversioned; JSON/WS
APIs live under `/v1`:

| Route | What |
|---|---|
| `GET /` | The frontend bundle: sign-in + device picker |
| `GET /d/<device>/` (and asset paths under it) | The same bundle, one device's console |
| `GET /healthz` | Relay liveness probe, `200 ok` |
| `/v1/auth/*`, `/v1/devices…` | The relay's own auth and device APIs (see Authentication) |

Everything else — commands, queries, and host-pushed events — travels over
**one WebSocket per client**: `GET /v1/devices/<device>/ws`, upgraded from
the same origin the bundle was served from and spliced through to the host.
The frontend takes `<device>` from its own page path (`/d/<device>/…`).
Frames are JSON text, shaped as **JSON-RPC 2.0**:

```jsonc
// client → host: request
{"jsonrpc": "2.0", "id": 1, "method": "agent.start", "params": {…}}

// host → client: response (exactly one per request, either form)
{"jsonrpc": "2.0", "id": 1, "result": {…}}
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "…"}}

// host → client: notification (no id, no reply expected)
{"jsonrpc": "2.0", "method": "agent.event", "params": {…}}
```

Request `id`s are client-assigned and client-scoped (a monotonic counter is
fine). Responses may arrive out of order relative to other requests — the
`id` is the correlation. Batch requests are not supported.

## Authentication

Auth terminates **at the relay**; the JSON-RPC wire above carries no
credentials and is unchanged by it. Device ids are stable database ids,
not secrets — the barrier is ownership:

- **Browsers** sign in with GitHub OAuth at the relay (`/v1/auth/login` →
  callback → `session` cookie, HttpOnly/SameSite=Lax, 7-day sliding).
  The data WebSocket upgrade on `/v1/devices/<device>/ws` requires a
  session whose user **owns** that device; anything else is 401/404.
- **Hosts** register over the control WebSocket with an `odt_` **device
  token** issued by the relay at sign-in time. The relay stores only a
  keyed hash; revoking a device invalidates the token and disconnects any
  live tunnel.
- **Desktop sign-in** is loopback OAuth with PKCE (RFC 8252 shape): the
  host starts a one-shot listener on `127.0.0.1:<random>`, opens the
  system browser at `<server>/v1/auth/desktop/start?state&code_challenge&
  port&name`, the signed-in user clicks **Allow** once, the browser
  bounces a one-time code to the listener, and the host swaps it (plus
  its PKCE verifier, `challenge = hex(sha256(verifier))`) at
  `POST /v1/auth/desktop/exchange` for `{device_token, device, user}` —
  the exchange **is** device registration. The host persists the token;
  `OPENSEEK_DEVICE_TOKEN` / `OPENSEEK_RELAY_URL` remain as development
  overrides.

The relay's own HTTP surface (OAuth routes, the devices API, schema) is
specified in the openseek-api repo's `docs/relay-auth-design.md`. The
development relay in `desktop/cmd/relay` serves the same paths without
any auth checks — it is a splicer for local work, never for deployment.

## Errors

| code | meaning | v1 equivalent |
|---|---|---|
| `-32700` | unparsable frame | — |
| `-32600` | not a valid JSON-RPC request | — |
| `-32601` | unknown method | 404 unknown op |
| `-32602` | params failed to decode | 400 `PayloadError` |
| `-32000` | engine error (`EngineError` — busy conversation, spawn failure, …) | 409 |
| `-32001` | host error (`HostError` — bad path, LSP failure, …) | 409 |
| `-32603` | internal error | 500 |

`error.message` is the user-facing text. `error.data` is unused for now.

## Connection lifecycle: reconnect = resync

There is **no resume machinery**: no sequence numbers, no cursor, no replay.
A connection delivers events from the moment it exists; whatever a client
missed while disconnected it recovers by re-reading state:

1. Connect the WebSocket. Notifications start flowing immediately.
2. Resync: `session.list` + `agent.runs` (and reload whatever conversation
   is open via `session.load`). The `agent.runs` reply is the **complete**
   in-flight set, in both directions: it introduces runs the client has
   never seen, and any run the client still shows that the reply lacks
   ended while it was away (its terminal notification will never be
   replayed) and must be closed client-side.
3. Race note: notifications may arrive before the resync replies. This is
   harmless by construction — streaming deltas are ephemeral display state,
   and every completed step is re-delivered as a full message
   (`agent.event` with `assistant_message` / `tool_result`), which replaces
   any partial delta buffer. A client that joins mid-step shows a truncated
   stream for at most one step before the full text overwrites it.

What this costs, deliberately: transient events that occurred while
disconnected (`usage` ticks, steer receipts, background notices) are gone —
none of them carry state a resync cannot rebuild or safely ignore. A run
that *finished* while the client was away is visible through `session.load`.

Slow clients are disconnected, not throttled and not silently dropped
frame-by-frame: when a connection's outbound queue overflows, the host
closes it, and the client reconnects into the resync path above.

The in-process bridge is exempt from all of this: it cannot disconnect, so
the desktop window never resyncs and never races.

## Method catalog

`params` is always a JSON object; `{}` when a method takes nothing.
Optional fields (`?`) are absent when unset — the protocol never encodes
absence as `""`, `0`, or another in-band sentinel.

### agent.* — runs

Run ids are opaque strings minted by the host, one per accepted prompt.
They are random, never reused, and never collide across host restarts — a
client may hold a pre-restart run id without any risk of it addressing a
new run. Clients compare them for equality only.

| method | params | result |
|---|---|---|
| `agent.start` | `{task, model?, max_steps?, session?, session_root?, workspace?}` — no credentials and no WSL preference: the host resolves the endpoint from its settings store (`settings.*`) | `{run_id, status, …}` — accepted once the run is public; pre-`started` failures are the error response |
| `agent.cancel` | `{run_id?}` (absent = the latest run) | cancel outcome |
| `agent.steer` | `{text, run_id?}` | steer outcome |
| `agent.compact` | `{session, model?, max_steps?, session_root?, workspace?}` — `agent.start` minus `task`: a conversation resumed after a restart has no live process, and compacting spawns one with these settings | compaction outcome |
| `agent.runs` | `{}` | `{runs: […]}` — every in-flight run's `agent.started` params, replayed through the same decoder; the resync replacement for v1's sticky `started` replay |

Notifications:

| method | params |
|---|---|
| `agent.started` | `{run_id, task, session, model, max_steps, cwd?}` — `task` is the prompt text, the only live source of the prompt bubble for a client that did not send it |
| `agent.event` | `{run_id?, session, event: {…}}` — the engine's event object verbatim (`assistant_delta`, `tool_result`, `agent_finished`, …); `run_id` is absent for events emitted before any run of the engine process's lifetime (a compaction on a freshly spawned engine), which route by `session` |
| `agent.error` | `{message, run_id?, diagnostics?}` |
| `agent.finished` | `{run_id, status, answer?}` |

### session.*

| method | params | result |
|---|---|---|
| `session.list` | `{}` | the session index |
| `session.load` | `{session, workspace?}` | `{session: <transcript>}` |
| `session.list_archived` | `{}` | the archived index |
| `session.archive` | `{session}` | outcome |
| `session.unarchive` | `{session}` | outcome |

Notification:

| method | params |
|---|---|
| `session.changed` | `{change: "archived" \| "unarchived", session}` — broadcast to every client (the requester included) when a conversation moves between the live and archived stores; recipients re-read both lists and drop live state for an archived record |

### settings.* — the host-owned engine endpoint settings

The provider, its credentials, and the WSL preference live on the **host**
(`engine-settings.json` in its runtime dir, versioned, 0600) — never in a
client. Clients edit them here and consume them as status; key material
never travels down the wire, only presence. Runs read the store at config
time, so a change replaces the conversation's engine process on its next
start.

| method | params | result |
|---|---|---|
| `settings.get` | `{}` | the status shape below |
| `settings.set` | `{provider?, custom_api_url?, deepseek_api_key?, custom_api_key?, wsl?: {enabled, distro?, engine?}}` — absent fields stay unchanged; a present string field is trimmed and, when empty, **clears** the stored value; a present `wsl` replaces the whole group; an unknown `provider` is refused | the status shape below, post-write |

The status shape, also the params of every `settings.changed` notification:

```jsonc
{
  "provider": "openseek" | "deepseek" | "custom",
  "custom_api_url": "https://…",   // absent when unset
  "has_deepseek_key": false,       // presence only — the key text never leaves the host
  "has_custom_key": false,
  "wsl": {"enabled": false, "distro": "…", "engine": "…"}  // distro/engine absent when unset
}
```

Notification:

| method | params |
|---|---|
| `settings.changed` | the status shape — broadcast to every client (the requester included) after each successful `settings.set`, so every page renders the same configuration |

### workspace.*

| method | params | result |
|---|---|---|
| `workspace.list` | `{}` | `{workspaces: […]}` |
| `workspace.add` | `{path}` | the updated list |
| `workspace.remove` | `{path}` | the updated list |

### git.*

| method | params | result |
|---|---|---|
| `git.branch` | `{session, cwd?}` | `{branch?}` — the checked-out branch of the conversation's working directory (detached HEAD reads as its short hash); absent when the directory is not a git repository or git is unavailable |

### fs.* — conversation-scoped file access

Paths in `fs.read_file` / `fs.read_directory` / `fs.stat_files` are relative
to the conversation's workspace; the host derives the root from `session`
(`workspace?` is the hint that lets a fresh conversation browse before its
durable record exists). `fs.browse` is the exception: it lists the **host**
filesystem for the workspace picker.

| method | params | result |
|---|---|---|
| `fs.read_file` | `{session, path, workspace?}` | `{kind: "content", content, absolute, sig}` \| `{kind: "binary"}` \| `{kind: "oversized"}` |
| `fs.read_directory` | `{session, path, workspace?}` (`""` = workspace root) | `{entries: [{name, is_dir}]}`, directories first |
| `fs.list_files` | `{session, workspace?}` | `{files: […], truncated}` — recursive snapshot for the fuzzy finder |
| `fs.stat_files` | `{session, paths, workspace?}` | `{stats: [{path, sig?}]}` — `sig` is the opaque mtime signature `"{seconds}:{nanos}"`, absent when the file is missing |
| `fs.watch` | `{session, workspace?}` | `{}` — points the single workspace watcher at this conversation |
| `fs.unwatch` | `{}` | `{}` — stops watching (the panel closed) |
| `fs.browse` | `{path?}` (absent = home; leading `~` expands) | `{path, parent?, entries}` — subdirectory names, sorted, dotfiles skipped |

Notification:

| method | params |
|---|---|
| `fs.changed` | `{root}` — coarse by design; the client re-stats its open tabs and re-lists expanded directories |

### lsp.*

| method | params | result |
|---|---|---|
| `lsp.open` | `{path}` (absolute) | `{diagnostics}` — the server's current diagnostics for the file; later changes push as `lsp.diagnostics` |
| `lsp.hover` | `{path, line, character}` (0-based) | `{value, markdown, has_range, start_line, start_character, end_line, end_character}` — empty `value` = no hover |
| `lsp.workspace_symbols` | `{session, query, workspace?}` | `{symbols: [{name, kind?, container?, path, range}]}` |

Notification:

| method | params |
|---|---|
| `lsp.diagnostics` | `{path, diagnostics}` — same array shape as `lsp.open`'s reply |

### skills.*

| method | params | result |
|---|---|---|
| `skills.catalog` | `{}` | `{skills: […]}` — the registry's installable skills |
| `skills.installed` | `{}` | `{skills: […]}` — the global library's contents |
| `skills.install` | `{module_name, version, package_path?}` | `{installed}` |
| `skills.uninstall` | `{id}` | `{removed}` |

### auth.* — remote-access sign-in

Desktop-window-only by client convention (same footing as `update.*`):
these drive the host's own relay registration, which a remote client has
no business operating. A browser signs in with the relay directly
(cookie), never through these ops.

| method | params | result |
|---|---|---|
| `auth.status` | `{}` | the status shape below |
| `auth.connect` | `{}` | the status shape — resolves only when the loopback flow finishes (browser round-trip included), so it can take minutes; errors are the JSON-RPC error response |
| `auth.disconnect` | `{}` | the status shape — deletes the local token, best-effort revokes the device at the relay, and stops the connector |

The status shape, also the params of every `auth.changed` notification:

```jsonc
{
  "server_url": "https://openseek-api.moonbitlang.cn",
  "connected": false,            // control WS currently registered
  "user":   {"login": "…", "avatar_url": "…"},   // absent when signed out
  "device": {"id": "d_…", "name": "…", "url": "…/d/d_…/"}  // absent when signed out
}
```

Notification:

| method | params |
|---|---|
| `auth.changed` | the status shape — pushed whenever registration state moves (connector registered, dropped, token revoked, signed out) |

### update.*

Desktop-window-only by client convention: applying an update swaps the
bundle under the running process and relaunches through the window's close
path, which only exists on the in-process bridge. The host serves these on
both transports (it cannot tell clients apart), but the browser frontend
never calls them and shows no update UI.

| method | params | result |
|---|---|---|
| `update.check` | `{channel?}` (anything but `"staging"` reads as production) | `{kind: "up_to_date" \| "available" \| "unreachable" \| "malformed" \| "broken", …}` |
| `update.download` | `{channel?}` | staging outcome |
| `update.apply` | `{}` | `{applied}` — the bundle swap succeeded and the window may close |

### app.* / host.*

| method | params | result |
|---|---|---|
| `app.list` | `{}` | `{apps: [{id, name, icon}]}` — `icon` is a `data:image/png` URL, empty when extraction failed |
| `app.launch` | `{session, cwd?, app}` | `{launched}` |
| `host.open_path` | `{session, cwd?, path}` | `{opened}` — hand a transcript-referenced path to the system opener; relative paths resolve against the conversation's working directory (`cwd` when the client has it, else derived from `session`); deliberately no workspace containment — the user clicked a path the agent itself surfaced |
| `host.meta` | `{}` | `{protocol: 2, name, wsl}` — `wsl` is whether the **host** can run the engine inside WSL (a Windows host); clients must consume this rather than sniff their own user agent, since the page may run on any device |

Reserved notification (not yet emitted over the wire):
`host.notification_clicked` `{session}` — a system notification was clicked.
On the desktop this arrives through the proton bridge; it appears here once
remote clients need it.

## Relay tunnel

The host reaches its clients by dialing out — it can live behind NAT with
nothing exposed. The relay is a **WebSocket splicer**: it pairs sockets and
forwards frames verbatim, with zero knowledge of the protocol above.

```
browser                    relay (public)                  host (desktop app)
  │                           │                                │
  │                           │◄─── ① control WS: /v1/tunnel ──┤ outbound, long-lived
  │                           │   register{device_token,name}  │
  │                           ├── registered{device:"d_…"} ───►│
  │                           │                                │
  ├─② wss://relay/v1/devices─►│                                │
  │        /d_…/ws            ├──── ③ open{stream:"s1"} ──────►│
  │   (session cookie)        │                                │
  │                           │◄── ④ data WS: /v1/tunnel/s1 ───┤ one per browser client
  │                           │                                │
  │◄════ ⑤ relay splices ② and ④ frame-for-frame ════════════►│
```

Control-channel frames (JSON text over the `/v1/tunnel` WebSocket):

| frame | direction | fields |
|---|---|---|
| `register` | host → relay | `{device_token, name}` — sent once after connecting |
| `registered` | relay → host | `{device}` — the stable public id; reconnects with the same token reuse it |
| `fail` | relay → host | `{message}` — registration rejected. A bad or revoked token is terminal: the host stops retrying, surfaces it (`auth.changed`), and waits for a new sign-in |
| `open` | relay → host | `{stream}` — a client connected to `/v1/devices/<device>/ws`; the host dials `GET /v1/tunnel/<stream>` (upgrade) back |

The data WebSocket (④) carries client protocol frames untouched. On the
host side each data connection is served by the same JSON-RPC dispatch the
bridge feeds — the host has no tunnel-specific protocol handling beyond the
four control frames. Either side closing a spliced socket closes its twin;
a dropped control connection closes every stream of that device.

The relay serves the frontend bundle itself, at `/` (sign-in + device
picker) and under `/d/<device>/` (the bundle never crosses the tunnel).
Nothing else is tunneled: the client protocol has exactly one entry
point, the WebSocket.

## Changes from v1

v1 (an HTTP + SSE gateway embedded in the desktop) is described by
`docs/browser-client-architecture.md` and retired. What changed and why:

- **The host process runs no server.** v1 embedded an HTTP gateway in the
  desktop and pointed the window at `http://127.0.0.1:<port>/`. v2 keeps
  the original desktop architecture — window on `proton://app/`, in-process
  bridge — and adds remote access as a pure outbound feature: dial the
  relay, register, serve each spliced WebSocket. No port, no static file
  server, no CORS, and the window regains bridge-only capabilities
  (notification-click focus).
- **One transport for the wire instead of three.** v1 ran fetch for
  commands, SSE for events, and a bespoke HTTP-over-WebSocket frame
  protocol (`req`/`resp`/`chunk`/`end`/`abort`) inside the tunnel. v2 is
  one JSON-RPC WebSocket, and the tunnel forwards it blind.
- **No seq / replay ring / sticky starts.** v1 resumed event streams by
  cursor (`?since=`) against a 4096-frame ring, with in-flight runs'
  `started` frames pinned. v2 reconnects by resyncing state: the serve
  engine appends every completed item to the session store as it runs, so
  `session.load` + `agent.runs` rebuild everything durable, and
  full-message events overwrite partial deltas within one step.
- **Route/op names unified** under dotted namespaces (`agent.*`,
  `session.*`, `workspace.*`, `git.*`, `fs.*`, `lsp.*`, `skills.*`,
  `update.*`, `app.*`, `host.*`), shared verbatim by the bridge and the
  WebSocket.
- **In-band sentinels removed from the wire**: `cwd`, `branch`, `sig` are
  optional fields instead of `""`; stopping the watcher is `fs.unwatch`
  instead of `fs.watch` with an empty session; `host.meta` carries no
  `capabilities` list (the method catalog is the capability surface).
- **Device ids stopped being capabilities** (v2.1): originally the
  unguessable device id was the only barrier, minted per token by the
  relay. With the user system (see Authentication) the id is a stable
  public identifier, ownership is enforced at the relay, APIs moved under
  `/v1`, and the browser WS left the page namespace
  (`/d/<device>/api/v1/ws` → `/v1/devices/<device>/ws`).
