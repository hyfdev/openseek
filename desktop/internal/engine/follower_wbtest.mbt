// The follower's pure core: watermark diffing over `sessions show` output
// and the store-layout fast path. The actor itself (baseline, serial loop,
// stop drain) needs a live engine binary and is exercised end to end.

///|
test "commits_after filters by watermark in file order" {
  let session : Json = {
    "events": [
      { "sequence": 1, "ts": 0, "item": { "kind": "user" } },
      { "sequence": 2, "ts": 0, "item": { "kind": "assistant" } },
      { "sequence": 3, "ts": 0, "item": { "kind": "tool_result" } },
    ],
  }
  let fresh = commits_after(session, 1)
  inspect(fresh.length(), content="2")
  inspect(fresh[0].0, content="2")
  inspect(fresh[1].0, content="3")
  inspect(commits_after(session, 3).length(), content="0")
}

///|
test "commits_after skips malformed events without dropping the rest" {
  let session : Json = {
    "events": [{ "sequence": "seven" }, 42, { "sequence": 7 }],
  }
  let fresh = commits_after(session, 0)
  inspect(fresh.length(), content="1")
  inspect(fresh[0].0, content="7")
}

///|
test "commits_after tolerates a session without events" {
  inspect(commits_after({ "id": "s" }, 0).length(), content="0")
  inspect(commits_after(Json::null(), 0).length(), content="0")
}

///|
test "session_max_sequence is the snapshot's watermark" {
  let session : Json = {
    "events": [{ "sequence": 5 }, { "sequence": 9 }, { "sequence": 7 }],
  }
  inspect(session_max_sequence(session), content="9")
  inspect(session_max_sequence({ "events": [] }), content="0")
  inspect(session_max_sequence(Json::null()), content="0")
}

///|
test "session_store_file follows the store layout" {
  let path = session_store_file(Path("/tmp/store-root"), "desktop-abc")
  assert_true(
    path.has_suffix("sessions/desktop-abc/openseek_session-desktop-abc.jsonl"),
  )
}
