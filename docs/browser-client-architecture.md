# Browser client architecture (v1 — superseded)

Status: SUPERSEDED. This HTTP+SSE gateway design was implemented, then
retired in favor of the v2 protocol — the desktop keeps its proton bridge,
remote access is one JSON-RPC WebSocket dialed out through a relay. See
`docs/remote-protocol.md` (the current contract); this document is kept as
the design record of v1.

## Goal

One frontend codebase serving both the desktop app and a browser client, with
HTTP as the only transport between frontend and backend, and one backend
component that can be deployed three ways:

1. **Self-exposed port** — the user runs the backend on their own machine and
   opens the client from a browser on the same network (`http://<ip>:<port>`).
2. **Personal machine behind our hosted relay** — the desktop app registers
   its backend with a hosted relay over an outbound tunnel; the user reaches
   their home sessions from any browser through the relay.
3. **Hosted agents** — the backend runs in a container on our infrastructure;
   desktop and browser clients connect to it through the same relay.

Constraint: the OpenSeek core (`cmd/openseek`, `agent/`, `agent_session/`)
is not modified. Its two existing boundaries — the `serve` stdin/stdout JSONL
protocol and the append-only session JSONL store — stay the stable interface.

## Layering

```
┌─────────────────────────────┐
│ Frontend (shared JS bundle) │  Rabbita/MoonBit→JS; identical for desktop & browser
│ transport layer (HTTP+SSE)  │  replaces frontend/bridge.mbt + __MoonBit__ ops
└──────────────┬──────────────┘
               │ HTTP commands + SSE event stream, /api/v1
┌──────────────┴──────────────┐
│ Gateway (desktop/gateway/)  │  engine hosting, auth, event fan-out, static assets
│ wraps internal/engine as-is │
└──────────────┬──────────────┘
               │ spawn + stdin/stdout JSONL (existing serve protocol)
┌──────────────┴──────────────┐
│ openseek serve (unchanged)  │  sessions persist as append-only JSONL
└─────────────────────────────┘
```

The **gateway** is the only new backend component: a MoonBit native HTTP
server (routes, middleware, streaming responses, and WebSocket upgrades via
`hackwaly/moonback` over `moonbitlang/async/http`) that

- hosts the engine subprocesses by calling `openseek_desktop/internal/engine`
  directly (`EngineManager`, `run_engine_pump`, `start_run`, …) — that package
  is already transport-agnostic behind `EventSink`;
- exposes the `/api/v1` HTTP API and the SSE event stream;
- optionally serves the frontend bundle, so in browser deployments the UI is
  whatever the gateway hands out.

The same gateway binary runs in all three deployment modes; the modes differ
only in where it runs and what fronts it. Since step 3, the desktop app IS
this shape: a CEF window speaking `/api/v1` + SSE to an embedded gateway on
`127.0.0.1:51763` (a stable preferred port; an OS-assigned fallback is used
when it is taken). The `__MoonBit__` proton bridge is retired; there is
exactly one protocol.

The desktop window's *page*, however, loads from `proton://app/` — CEF's own
scheme handler — not from the gateway. Serving the bundle over loopback HTTP
coupled page paint to the host's async event loop, and proton's idle pump
(`Runtime::wait`) blocks that loop for up to 16 ms per lap: the page waited
on the server, the server on the loop, the loop on CEF, CEF on the page.
Replacing the blocking wait with a non-blocking probe unstuck the page but
made CEF's close-time `OnBeforeClose` hang readily reproducible, so the
blocking cadence stays (with one zero-length loop yield per timed-out lap so
host IO never starves outright) and the window is decoupled from the loop
instead. Two consequences:

- **Config injection.** A static `proton://app/` origin cannot know the
  embedded gateway's port, so the host splices
  `<script>globalThis.__OPENSEEK_GATEWAY__={"api":…}</script>` into the
  document before handing it to proton. The frontend's interop layer reads
  that global first and only then falls back to the page's own origin
  (document-relative URLs) — browser pages have no such global, so nothing
  changes for them.
- **CORS.** The window calls the gateway cross-origin, so the gateway runs
  moonback's CORS middleware outermost, answering preflights before any
  other middleware sees the request.

The non-engine host ops — file browsing, LSP hover/symbols/diagnostics, the
workspace watcher, skills, self-update, app launching, `open_path`,
`workspace_branch`, and `browse_directory` — live in
`desktop/internal/host` and ride one uniform route, `POST /api/v1/ops/<op>`,
with the op names and payload shapes the frontend has always used. There is
no native folder dialog anywhere: "Add a workspace" opens an in-app picker
(a modal the frontend renders) fed by `browse_directory` listings, so
desktop and browser share the one flow and the directories shown are
always the host machine's — which is also the only correct semantics for a
remote gateway, where a client-native dialog would browse the wrong
filesystem (and web pages cannot read absolute paths anyway). The desktop-specific remainder is two
hooks and a shell: `on_finished` (system notifications via proton) and the
proton window itself. Known regression: clicking a notification reveals
the window but no longer jumps to the conversation — proton forwards the
click only to `proton://` pages; restoring it needs an upstream app-level
callback, and the frontend already decodes a `notification_clicked` frame
for that day.

## Protocol v1

HTTP + SSE rather than WebSocket for v1:

- Engine events are a one-directional stream; commands (`start`, `steer`,
  `cancel`) are low-frequency request/response calls that benefit from real
  HTTP status codes.
- `EventSource` gives reconnection and resume (`Last-Event-ID`/`since`) for
  free, and the session store is append-only JSONL, so catch-up is natural.
- Plain HTTP traverses proxies and relays without special handling.

Frames are transport-agnostic JSON, so a WebSocket channel can carry the same
frames later without a protocol rev (e.g. for lower-latency editor/LSP
traffic).

### Upgrade strategy

1. **URL versioning** — `/api/v1/`; only incompatible changes bump it.
2. **Tolerant decoding** — both sides ignore unknown fields and unknown frame
   `type`s; additive changes are never breaking.
3. **Capability negotiation** — `GET /api/v1/meta` lists capabilities; new or
   host-specific features (native dialogs, self-update) appear there, and the
   frontend renders only what the connected gateway offers.

### Endpoints

There is deliberately no authentication yet (a per-launch bearer token was
built and then removed as debugging friction while the client is
loopback-only); the gateway executes tool calls, so until an auth story
lands it must only ever bind loopback. The auth section below is the
design for when remote modes need it.

```
GET  /healthz                      liveness
GET  /api/v1/meta                  { protocol, name, version, capabilities }

GET  /api/v1/events?since=<seq>    SSE stream (see below)

POST /api/v1/runs                  start a run        → StartReply
POST /api/v1/runs/cancel           { run_id? }        → CancelReply
POST /api/v1/runs/steer            { text, run_id? }  → SteerReply
POST /api/v1/compact               CompactRequest     → CompactReply

GET  /api/v1/sessions              sidebar listing    → SessionsReply
POST /api/v1/sessions/load         { session, workspace? } → LoadSessionReply
GET  /api/v1/sessions/archived     archived listing   → SessionsReply
POST /api/v1/sessions/archive      { session }        → SessionsReply
POST /api/v1/sessions/unarchive    { session }        → SessionsReply

GET  /api/v1/workspaces            → WorkspacesReply
POST /api/v1/workspaces/add        { path } → WorkspacesReply
POST /api/v1/workspaces/remove     { path } → WorkspacesReply

POST /api/v1/ops/<op>              every non-engine host op (fs, lsp,
                                   skills, updates, apps, open_path,
                                   workspace_branch, pick_workspace),
                                   dispatched by bridge-op name

GET  /<asset>                      frontend bundle (when configured)
```

Request/reply bodies are exactly the payload shapes the desktop extension
already uses (`desktop/internal/extension/protocol.mbt` /
`desktop/internal/engine/api.mbt`), so the frontend's existing decoders —
`frontend/transcript/*` in particular — are reused verbatim. Commands address
sessions/runs in the body rather than the path, mirroring those structs and
avoiding id-in-URL encoding issues.

Errors are `{ "error": "<message>" }` with a 4xx/5xx status; `EngineError`
maps to 409 (conflict with engine state), malformed payloads to 400.

### Event stream

One SSE stream per client carries every engine event, fanned out to all
connected clients:

```
id: <seq>
data: {"seq":123,"type":"event","payload":{"run_id":7,"session":"…","event":{…}}}
```

- `type` mirrors the proton bridge events: `connected`, `started`, `event`,
  `error`, `finished` (later: `fs_changed`, `diagnostics`).
- `seq` is a gateway-lifetime monotonic counter. The gateway keeps a bounded
  replay ring; a client reconnecting with `?since=<last seq>` replays what it
  missed. A `since` older than the ring means the client reloads state through
  `sessions/load` — which is also how a fresh client joins: connect, receive
  the `hello` frame (`{"type":"hello","payload":{"last_seq":N}}`, not
  replayed, no id), load the session transcript, then apply live events.
- Comment heartbeats (`: ping`) flow every ~15s so dead connections are
  detected and reaped.

Multiple clients can attach to one gateway concurrently (desktop plus a
phone browser); events fan out to all, and per-conversation engine state
lives server-side in `EngineManager`, which already serializes turns per
session.

## Deployment modes

The relay is deliberately a **dumb forwarder**: it authenticates users and
routes to devices, but never interprets the agent protocol — protocol upgrades
touch only the frontend and the gateway, never hosted infrastructure.

- **Self-exposed port**: the gateway binds a second all-interfaces listener
  on demand — Settings → "Access from browser" flips it (`GET`/`POST
  /api/v1/lan`), the loopback listener stays private the whole time. The
  reply carries a ready-to-open URL (the machine's LAN IP + the token), so
  the user copies a link rather than handling a token. The gateway executes
  arbitrary tool calls on the host, so auth is mandatory even on a LAN, and
  the token also defeats DNS-rebinding (the attacker's origin does not know
  it). The token is per-launch: a link stops working when the app restarts,
  and the frontend's disconnect overlay says so (probing `/api/v1/meta` to
  tell an expired token from an unreachable gateway) and points back to the
  Settings panel for a fresh link. Making the token stable across launches
  was considered and dropped as not worth the complexity — re-copying the
  link is the cheaper model.
- **Relay (home machine)**: the machine is behind NAT, so the gateway dials
  *out* to the relay (`wss://relay…/tunnel`) with device credentials; the
  relay assigns a device id and forwards
  `https://relay…/d/<device>/api/v1/...` frames over the tunnel verbatim.
  The gateway keeps checking its own token as an inner defense layer.
- **Hosted agents**: the container runs the same gateway binary and registers
  with the relay exactly like a home machine — one routing mechanism for both.
  The control plane (provisioning, quotas, billing) is a separate service and
  never enters the agent protocol.

Because the frontend transport is just a base URL, the desktop client can
switch between its local gateway and any relay device without UI forks.

### The tunnel (step 4)

The reverse tunnel is one WebSocket per device, multiplexed by a per-request
stream id, defined in `desktop/tunnel` and shared by both sides:

- The **gateway connector** (`desktop/gateway/connect.mbt`, enabled with
  `--relay-url` + `--device-token`) dials the relay, sends a `register`
  frame, and gets back a stable `device` id. For each `req` frame the relay
  forwards, it proxies the request straight into its own loopback HTTP
  server — so all routing, auth, and streaming are unchanged from the direct
  path — and streams the reply back as `resp`/`chunk`/`end` frames. An
  `abort` frame cancels an in-flight stream (an SSE stream never ends on its
  own). SSE bodies are forwarded line by line (each line is a complete UTF-8
  sequence ending in `\n`), so the byte stream reconstructs faithfully.
- The **relay** (`desktop/cmd/relay`) accepts tunnels at `/tunnel`, serves
  the frontend bundle itself under `/d/<device>/` (binary assets never cross
  the tunnel), and tunnels only `/d/<device>/api/*` and `.../healthz`. It
  maps each device token to a stable random id (reused across reconnects, so
  the URL survives a restart) and never inspects the payloads it forwards.
  A dropped tunnel wakes every waiting browser handler with a 502 rather
  than hanging. This is the tunnel core; a production relay adds the account
  layer (login, device ownership, TLS, wildcard host or path routing) in
  front — the reference relay has no accounts, which is enough to run and
  test the path end to end.

The frontend builds API URLs relative to the document base
(`@interop.api_base`), so the `/d/<device>/` prefix a relay serves the page
under flows onto every fetch and the EventSource automatically; the direct
and embedded cases at `/` are unaffected.

## Auth (future — currently removed)

- **Gateway token**: a per-launch bearer token was implemented (gate every
  /api request, `?token=` for EventSource, injected into the desktop
  window) and then removed while the client is loopback-only — it made
  every debugging session harder and protected nothing a loopback bind
  does not. It returns as the inner layer when any non-loopback mode
  ships; the removal commit is the recipe.
- **Relay accounts**: relay modes add user login and relay-issued short-lived
  tokens binding devices to accounts (outer layer, separate service).
- **Model API keys**: locally, the current model (key in browser storage,
  sent with `start`) still works. For remote modes, keys should be configured
  gateway-side (env/config) so user keys never transit the relay.

## Operational notes (step 1 findings)

- **Starting runs requires the packaged engine layout.** The engine package's
  spawn path (`internal/engine/engine.mbt` →
  `internal/moonbit/prepare_bundled_home`) hard-requires a bundled MoonBit
  toolchain seed beside the engine binary
  (`<engine dir>/toolchains/moonbit/<platform>/`) plus a `--runtime-dir` to
  materialize it into. Listing/loading sessions works with any engine binary;
  `POST /runs` does not. Deployments (containers included) ship the same
  engine+toolchain layout the desktop bundle uses. Relaxing this to fall back
  to an ambient `moon` would change desktop behavior — deliberately not done.
- The gateway process's environment is inherited by the engine's one-shot
  commands (`sessions list/show`), mirroring the desktop host.
- **HTTP serving is moonback; URIs are `desktop/uri`.** Both servers
  (gateway and relay) are moonback apps — trie routing (`:param`/`*rest`),
  one middleware for auth + error mapping, `Responder::respond` for SSE
  streaming, `Responder::upgrade` for the tunnel WebSocket, and the
  unstable_static middleware for the gateway's assets. URI text is handled
  through the `openseek_desktop/uri` package: an immutable RFC 3986-shaped
  `Uri` value type with method APIs (`Uri::parse`, `query`, `with_query`,
  `with_origin`, `to_string`) instead of ad-hoc string splitting.
- **OS entropy needs a C stub.** `moonbitlang/async`'s fs cannot open
  `/dev/urandom` (its event loop rejects the character-device fd), so the
  relay device ids read entropy through a tiny synchronous C FFI
  (`internal/entropy`, `/dev/urandom` on POSIX / `rand_s` on Windows)
  rather than async fs, and fail loudly rather than fall back to guessable
  randomness.

## Implementation plan

1. **Gateway** (`desktop/gateway/` + `desktop/cmd/gateway/`): HTTP+SSE server
   wrapping `internal/engine` unchanged, token auth, event hub with replay,
   optional static assets. ✅
2. **Frontend transport**: `bridge_request` and the event wiring speak
   HTTP+SSE (`frontend/interop/gateway_transport.mbt`,
   `frontend/gateway_events.mbt`); browser direct mode works. ✅
3. **Desktop embeds the gateway** (`GatewayServer::bind/port/serve`; proton
   extension layer deleted; host ops moved to `internal/host` behind
   `/api/v1/ops/<op>`; window on `proton://app/` with the gateway address
   and token spliced into the document, gateway CORS-enabled). ✅
4. **Relay service** — the reverse-tunnel core (`desktop/tunnel`,
   `desktop/gateway/connect.mbt`, `desktop/cmd/relay`): a gateway dials the
   relay with `--relay-url`/`--device-token` and browsers reach it at
   `/d/<device>/`. Covers modes 2 and 3 at the tunnel layer; the account
   layer in front is future work. ✅
5. **Container image**: gateway + engine, wired to the control plane.
