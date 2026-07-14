// The session follower: the host's second reader of a conversation's durable
// record. While a desktop-managed engine can write to a session's store, one
// follower actor per session tails the record through the bundled engine's
// own reader (`sessions show` — shared lock, torn-write repair and header
// parsing all come with it) and broadcasts each newly committed event as a
// canonical `session.event` notification. Those commits, plus the
// `session.load` snapshot, are the durable transcript's only sources on the
// client; the live `agent.event` stream stays a display overlay
// (docs/remote-protocol.md).
//
// The actor is the design's ordering backbone: every read of the record —
// watcher-less kicks, the poll fallback, a routed `session.load`, the final
// scan on engine exit, the archive drain — goes through one serial loop, so
// a session's commits reach the hub in sequence order and a stop
// acknowledgment really means "no scan is in flight and none will start".
// Followers run only while the host manages a writer for the session (the
// serve engine's lifetime, spawn to EOF); an idle session's `session.load`
// reads the record directly, one-shot.

///|
/// How often the actor re-checks the store file without being kicked. Kicks
/// from the engine's own stdout events provide the low-latency wakeups (an
/// append is always accompanied by a nearby event — a behavioral invariant,
/// not a contract), so this poll is the safety net for the exceptions:
/// external CLI writers sharing the session, and any append whose event was
/// lost or reordered.
const FollowerPollMs = 1000

///|
/// A cheap change fingerprint for the store file, checked before spending a
/// `sessions show` on a kick: size catches every append (the file grows),
/// mtime catches the store's repair paths that rewrite instead of appending.
priv struct FileSignature {
  size : Int64
  mtime_s : Int64
  mtime_ns : Int
} derive(Eq)

///|
priv enum FollowerMsg {
  // Something may have been appended: scan when the file signature moved.
  Kick
  // A `session.load` routed through the actor: force a scan — broadcasting
  // any fresh commits — and reply with the full session JSON.
  Load(@async.Queue[FollowerLoadReply])
  // Stop after a final scan. The ack is a drain barrier: once it arrives, no
  // scan is in flight and none will start, so the record can be moved.
  Stop(@async.Queue[Unit])
}

///|
priv enum FollowerLoadReply {
  LoadOk(Json)
  LoadFailed(String)
  // The follower was already draining; the caller re-reads directly.
  LoadStopped
}

///|
priv struct SessionFollower {
  session : String
  root : @path.Path
  inbox : @async.Queue[FollowerMsg]
  // One queued Kick at a time: a delta storm collapses to a single pending
  // wakeup instead of an unbounded backlog of identical messages.
  mut kick_pending : Bool
  mut stopping : Bool
  // The highest sequence already broadcast. Commits at or below it are old
  // news; the frontier only advances, so a scan can never re-broadcast.
  mut watermark : Int
  // Signature of the store file as of the last completed scan (taken before
  // the scan read it, so a write racing the read re-triggers). `None` until
  // the first scan, or when the file cannot be examined.
  mut consumed : FileSignature?
}

///|
/// Where the store keeps this session's event log. Duplicating the store's
/// layout here is only a fast-path optimization — the signature check that
/// uses it skips redundant `sessions show` spawns. If the layout ever moves
/// upstream, the signature reads `None`, every kick scans, and behavior
/// stays correct (just slower).
fn session_store_file(root : @path.Path, session : String) -> String {
  root
  .join("sessions")
  .join(session)
  .join("openseek_session-\{session}.jsonl")
  .to_string()
}

///|
async fn file_signature(path : String) -> FileSignature? {
  let file = @fs.open(path, mode=ReadOnly) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  defer file.close()
  let size = file.size() catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  let (mtime_s, mtime_ns) = file.mtime() catch {
    error if @async.is_being_cancelled() => raise error
    _ => return None
  }
  Some({ size, mtime_s, mtime_ns })
}

///|
/// The store events in `session_json` committed after `watermark`, in file
/// order (the store guarantees ascending sequences). Each entry pairs the
/// event's sequence with the store event JSON, passed through verbatim so
/// the client sees exactly what a `session.load` snapshot would carry.
fn commits_after(session_json : Json, watermark : Int) -> Array[(Int, Json)] {
  guard session_json is Object(fields) &&
    fields.get("events") is Some(Array(events)) else {
    return []
  }
  let fresh : Array[(Int, Json)] = []
  for event in events {
    guard event is Object(event_fields) &&
      event_fields.get("sequence") is Some(Number(sequence, ..)) else {
      continue
    }
    let sequence = sequence.to_int()
    if sequence > watermark {
      fresh.push((sequence, event))
    }
  }
  fresh
}

///|
/// The highest event sequence in a session JSON — what a snapshot's
/// watermark is. 0 for a record with no events.
fn session_max_sequence(session_json : Json) -> Int {
  let mut max = 0
  for entry in commits_after(session_json, 0) {
    let (sequence, _) = entry
    if sequence > max {
      max = sequence
    }
  }
  max
}

///|
/// One scan: read the record through `sessions show`, broadcast everything
/// committed past the watermark, advance it, and return the full session
/// JSON. Without `force~`, a scan whose file signature matches the last
/// consumed one is skipped (`None`). Raises when the record cannot be read —
/// the watermark then stays put, so the next scan retries the same span.
async fn SessionFollower::scan(
  self : SessionFollower,
  sink : EventSink,
  manager : EngineManager,
  force~ : Bool,
) -> Json? {
  let signature = file_signature(session_store_file(self.root, self.session))
  if !force && signature is Some(_) && signature == self.consumed {
    return None
  }
  let output = engine_stdout(manager, [
    "sessions",
    "show",
    self.session,
    "--session-root",
    self.root.to_string(),
  ])
  let session_json = @json.parse(output) catch {
    _ => raise EngineError("engine returned a malformed session")
  }
  for entry in commits_after(session_json, self.watermark) {
    let (sequence, event) = entry
    emit(sink, SessionCommit({ session: self.session, sequence, event }))
    self.watermark = sequence
  }
  self.consumed = signature
  Some(session_json)
}

///|
/// The actor. Baseline first: adopt the record's current frontier without
/// broadcasting — anything committed before this follower existed reaches
/// clients through `session.load`, not through a replay storm — then serve
/// the inbox serially until a Stop, with a poll ticker as the kick fallback.
/// The ready ack releases the spawn path only after the baseline, so the
/// engine cannot append before the follower is watching.
async fn run_follower(
  sink : EventSink,
  manager : EngineManager,
  follower : SessionFollower,
  ready : @async.Queue[Unit],
) -> Unit {
  let baseline_signature = file_signature(
    session_store_file(follower.root, follower.session),
  )
  let baseline = engine_stdout(manager, [
    "sessions",
    "show",
    follower.session,
    "--session-root",
    follower.root.to_string(),
  ]) catch {
    error if @async.is_being_cancelled() => raise error
    // No record yet (a session's first turn), or a transiently unreadable
    // one: start from 0. Over-broadcasting history later is safe — clients
    // drop commits at or below their own watermark — it only costs bytes.
    _ => ""
  }
  if !baseline.is_empty() &&
    (@json.parse(baseline) catch { _ => Json::null() }) is (Object(_) as json) {
    follower.watermark = session_max_sequence(json)
    follower.consumed = baseline_signature
  }
  ready.put(())
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      for ;; {
        @async.sleep(FollowerPollMs)
        kick_follower_inbox(follower)
      }
    })
    for ;; {
      match follower.inbox.get() {
        Kick => {
          follower.kick_pending = false
          ignore(
            follower.scan(sink, manager, force=false) catch {
              error if @async.is_being_cancelled() => raise error
              error => {
                @xlog.debug() <?
                  {
                    "event": "desktop_follower_scan_failed",
                    "session": follower.session,
                    "error": "\{error}",
                  }
                None
              }
            },
          )
        }
        Load(reply) => {
          let loaded = follower.scan(sink, manager, force=true) catch {
            error if @async.is_being_cancelled() => raise error
            error => {
              reply.put(LoadFailed("\{error}"))
              continue
            }
          }
          match loaded {
            Some(json) => reply.put(LoadOk(json))
            // Unreachable — a forced scan never skips — but total.
            None => reply.put(LoadFailed("session read produced nothing"))
          }
        }
        Stop(ack) => {
          follower.stopping = true
          // The final scan: everything the departed writer persisted is
          // broadcast before the stop is acknowledged.
          ignore(
            follower.scan(sink, manager, force=true) catch {
              error if @async.is_being_cancelled() => raise error
              _ => None
            },
          )
          ack.put(())
          break
        }
      }
    }
    group.return_immediately(())
  })
  // Retire: leave the map (by identity — a successor may already be
  // installed), then close the inbox so late senders get a refusal instead
  // of a message no one will read, and answer the ones already queued.
  if manager.followers.get(follower.session) is Some(current) &&
    physical_equal(current, follower) {
    manager.followers.remove(follower.session)
  }
  follower.inbox.close()
  for ;; {
    let message = follower.inbox.try_get() catch { _ => None }
    match message {
      Some(Load(reply)) => reply.put(LoadStopped)
      Some(Stop(ack)) => ack.put(())
      Some(Kick) => ()
      None => break
    }
  }
}

///|
/// Queue a Kick, collapsing repeats while one is already pending. Safe to
/// call from anywhere; a closed inbox (the actor is retiring) refuses it
/// quietly.
fn kick_follower_inbox(follower : SessionFollower) -> Unit {
  if follower.stopping || follower.kick_pending {
    return
  }
  if (follower.inbox.try_put(Kick) catch { _ => false }) {
    follower.kick_pending = true
  }
}

///|
/// Wake `session`'s follower, if any — the engine consumer calls this on
/// every stdout event, which is what gives commits their low latency.
fn EngineManager::kick_follower(self : EngineManager, session : String) -> Unit {
  if self.followers.get(session) is Some(follower) {
    kick_follower_inbox(follower)
  }
}

///|
/// Make sure a follower is watching `config.session` before its engine can
/// write, and only return once its baseline scan is done. Runs inside the
/// pump's spawn path, so the follower task lives in the same task group as
/// the engines. A session-less config gets no follower — there is no durable
/// record to follow.
async fn[G] ensure_follower(
  sink~ : EventSink,
  group~ : @async.TaskGroup[G],
  manager~ : EngineManager,
  config~ : RunConfig,
) -> Unit {
  guard config.session is Some(session) && config.session_root is Some(root) else {
    return
  }
  // A predecessor draining its final scan removes itself from the map when
  // done; wait for that rather than racing it with a second broadcaster for
  // the same session (per-session commit order is the design's backbone).
  for attempt = 0; ; attempt = attempt + 1 {
    match manager.followers.get(session) {
      Some(follower) => {
        if !follower.stopping {
          return
        }
        guard attempt < 500 else {
          raise EngineError(
            "session follower is stuck draining; try again shortly",
          )
        }
        @async.sleep(20)
      }
      None => break
    }
  }
  let follower : SessionFollower = {
    session,
    root,
    inbox: Queue(kind=Unbounded),
    kick_pending: false,
    stopping: false,
    watermark: 0,
    consumed: None,
  }
  manager.followers[session] = follower
  let ready : @async.Queue[Unit] = Queue(kind=Unbounded)
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    run_follower(sink, manager, follower, ready)
  })
  ready.get()
}

///|
/// Stop `session`'s follower and wait for its final scan to drain. This is
/// the barrier archive relies on: after it returns, no scan is in flight and
/// none will start, so the record directory can be moved without a late
/// `sessions show` broadcasting from beyond the grave.
async fn stop_follower(manager : EngineManager, session : String) -> Unit {
  guard manager.followers.get(session) is Some(follower) else { return }
  let ack : @async.Queue[Unit] = Queue(kind=Unbounded)
  follower.inbox.put(Stop(ack)) catch {
    error if @async.is_being_cancelled() => raise error
    // Inbox already closed: the actor is past its drain.
    _ => return
  }
  ack.get()
}

///|
/// Fire-and-forget variant for synchronous cleanup paths (an op's `defer`):
/// ask the follower to retire without waiting for the drain. Used when a
/// start or compact failed before leaving a live engine behind — nothing
/// writes anymore, so the only cost of not waiting is that the final scan
/// finishes a moment later.
fn request_stop_follower(manager : EngineManager, session : String) -> Unit {
  guard manager.followers.get(session) is Some(follower) else { return }
  if follower.stopping {
    return
  }
  follower.stopping = true
  let ack : @async.Queue[Unit] = Queue(kind=Unbounded)
  ignore(follower.inbox.try_put(Stop(ack)) catch { _ => false })
}
