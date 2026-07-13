// The fan-out point between the engine's EventSink and every connected
// client. Notifications are pushed to each subscriber's bounded queue; a
// subscriber that cannot keep up is dropped, per the protocol's
// reconnect-equals-resync contract (docs/remote-protocol.md) — the client
// reconnects and rebuilds state through `session.list` + `agent.runs`.

///|
/// One server-pushed notification: a catalog method name and its params.
/// Transports encode it at their own edge (JSON-RPC frame, proton event).
pub(all) struct Notification {
  method_ : String
  params : Json
}

///|
/// A subscriber queue's bound. Generous — the desktop webview and a healthy
/// browser drain far faster than the engine produces — so hitting it means
/// the connection is wedged, and the protocol's answer to a wedged
/// connection is to close it.
const SubscriberQueueCapacity = 1024

///|
/// The hub is owned by `ApiState`; transports reach it through
/// `ApiState::subscribe`/`unsubscribe`.
priv struct Hub {
  subscribers : Array[@async.Queue[Notification]]
  // The `agent.started` params of every run still in flight, keyed by run
  // id — the source for `agent.runs`, which is how a client that joins (or
  // reconnects) mid-run learns the run's identity.
  active_starts : Map[Int, Json]
}

///|
fn Hub::new() -> Hub {
  { subscribers: [], active_starts: Map([]) }
}

///|
/// Push one notification to every live subscriber. `try_put` never
/// suspends, so the order every subscriber sees is the publish order. A
/// full queue marks its subscriber dead: the queue is closed (ending the
/// connection's writer) and dropped. Only the hub ever closes a subscribed
/// queue, and it removes the queue from `subscribers` in the same breath,
/// so `try_put` on a closed queue cannot happen — `try!` turns that
/// invariant into a hard stop instead of a silent discard.
fn Hub::publish(self : Hub, method_ : String, params : Json) -> Unit {
  if params_run_id(params) is Some(run_id) {
    match method_ {
      "agent.started" => self.active_starts[run_id] = params
      "agent.finished" | "agent.error" => self.active_starts.remove(run_id)
      _ => ()
    }
  }
  let wedged : Array[Int] = []
  for index, queue in self.subscribers {
    if !(try! queue.try_put({ method_, params })) {
      wedged.push(index)
    }
  }
  // Back to front, so the collected indices stay valid while removing.
  for cursor in wedged.rev_iter() {
    let queue = self.subscribers.remove(cursor)
    queue.close()
  }
}

///|
fn params_run_id(params : Json) -> Int? {
  guard params is Object(fields) &&
    fields.get("run_id") is Some(Number(run_id, ..)) else {
    return None
  }
  Some(run_id.to_int())
}

///|
fn Hub::subscribe(self : Hub) -> @async.Queue[Notification] {
  let queue : @async.Queue[Notification] = Queue(
    kind=Blocking(SubscriberQueueCapacity),
  )
  self.subscribers.push(queue)
  queue
}

///|
/// Drop a subscriber by queue identity and close its queue, waking a writer
/// blocked on `get`. Unsubscribing twice is fine; so is unsubscribing a
/// queue the hub already kicked.
fn Hub::unsubscribe(self : Hub, queue : @async.Queue[Notification]) -> Unit {
  for index, candidate in self.subscribers {
    if physical_equal(candidate, queue) {
      ignore(self.subscribers.remove(index))
      queue.close()
      break
    }
  }
}

///|
/// The `agent.runs` reply: every in-flight run's `agent.started` params, in
/// run-id order.
fn Hub::runs(self : Hub) -> Json {
  let ids = self.active_starts.keys().collect()
  ids.sort()
  let runs : Array[Json] = []
  for id in ids {
    if self.active_starts.get(id) is Some(params) {
      runs.push(params)
    }
  }
  { "runs": Json::array(runs) }
}

///|
/// The hub as the engine package's event sink, mapping engine events onto
/// the catalog's `agent.*` notifications. `on_finished` additionally hands
/// finished runs to the embedding host — the desktop's system notification.
fn Hub::sink(
  self : Hub,
  on_finished? : (@engine.FinishedPayload) -> Unit,
) -> @engine.EventSink {
  EventSink(event => {
    match event {
      Connected(payload) => self.publish("agent.connected", payload.to_json())
      Started(payload) => self.publish("agent.started", payload.to_json())
      StreamEvent(payload) => self.publish("agent.event", payload.to_json())
      Error(payload) => self.publish("agent.error", payload.to_json())
      Finished(payload) => {
        if on_finished is Some(notify) {
          notify(payload)
        }
        self.publish("agent.finished", payload.to_json())
      }
    }
  })
}
