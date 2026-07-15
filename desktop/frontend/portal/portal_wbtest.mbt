// The portal's transitions, driven with a no-op emit. Commands are not
// executed — these tests pin the model movements (rabbita's update purity
// makes them total functions of (msg, model)).

///|
fn test_emit() -> @cmd.Emit[Msg] {
  Emit(_ => @cmd.none)
}

///|
fn sample_devices() -> Array[DeviceInfo] {
  [
    { id: "d_on", name: "Mac", hostname: Some("mac.local"), online: true },
    { id: "d_off", name: "PC", hostname: None, online: false },
  ]
}

///|
test "sign-in settles into probing only the online devices" {
  let emit = test_emit()
  let (_, signed) = update(
    emit,
    MeLoaded(login="octocat", avatar=""),
    Model::init(),
  )
  assert_true(signed.auth is SignedIn(login="octocat", ..))
  let (_, listed) = update(emit, DevicesLoaded(sample_devices()), signed)
  guard listed.devices is DevicesReady(rows) else {
    fail("device list did not settle")
  }
  assert_true(rows[0].workspaces is Probing)
  assert_true(rows[1].workspaces is NotProbed)
  let (_, probed) = update(
    emit,
    WorkspacesProbed(device="d_on", workspaces=Some(["/home/u/proj"])),
    listed,
  )
  guard probed.devices is DevicesReady(rows) else { fail("rows lost") }
  assert_true(rows[0].workspaces is Probed(["/home/u/proj"]))
  // An unreachable probe degrades that one device, nothing else.
  let (_, failed) = update(
    emit,
    WorkspacesProbed(device="d_on", workspaces=None),
    listed,
  )
  guard failed.devices is DevicesReady(rows) else { fail("rows lost") }
  assert_true(rows[0].workspaces is Unreachable)
}

///|
test "a 401 anywhere reads as signed out" {
  let emit = test_emit()
  let (_, signed) = update(emit, MeLoaded(login="o", avatar=""), Model::init())
  let (_, out) = update(emit, MeUnauthorized, signed)
  assert_true(out.auth is SignedOut)
  assert_false(out.busy)
}

///|
test "rename commits only a non-blank name and clears on done" {
  let emit = test_emit()
  let (_, signed) = update(emit, MeLoaded(login="o", avatar=""), Model::init())
  let (_, listed) = update(emit, DevicesLoaded(sample_devices()), signed)
  let (_, editing) = update(
    emit,
    RenameStarted(device="d_on", current="Mac"),
    listed,
  )
  assert_true(editing.rename is Some({ device: "d_on", .. }))
  let (_, blank) = update(emit, RenameEdited("   "), editing)
  let (_, still) = update(emit, RenameSubmitted, blank)
  // A blank name never leaves the page.
  assert_false(still.busy)
  let (_, edited) = update(emit, RenameEdited("Studio"), editing)
  let (_, saving) = update(emit, RenameSubmitted, edited)
  assert_true(saving.busy)
  let (_, done) = update(emit, MutationDone, saving)
  assert_false(done.busy)
  assert_true(done.rename is None)
}

///|
test "the actions menu toggles per device and disarms a pending remove" {
  let emit = test_emit()
  let (_, signed) = update(emit, MeLoaded(login="o", avatar=""), Model::init())
  let (_, listed) = update(emit, DevicesLoaded(sample_devices()), signed)
  let (_, opened) = update(emit, MenuToggled("d_on"), listed)
  assert_true(opened.menu_open is Some("d_on"))
  // Opening another device's menu closes the first.
  let (_, switched) = update(emit, MenuToggled("d_off"), opened)
  assert_true(switched.menu_open is Some("d_off"))
  // Arming Remove keeps the menu; toggling it away disarms.
  let (_, armed) = update(emit, DeleteAsked("d_off"), switched)
  assert_true(armed.confirm_delete is Some("d_off"))
  assert_true(armed.menu_open is Some("d_off"))
  let (_, closed) = update(emit, MenuToggled("d_off"), armed)
  assert_true(closed.menu_open is None)
  assert_true(closed.confirm_delete is None)
  // Rename from the menu closes it and opens the field.
  let (_, reopened) = update(emit, MenuToggled("d_on"), closed)
  let (_, renaming) = update(
    emit,
    RenameStarted(device="d_on", current="Mac"),
    reopened,
  )
  assert_true(renaming.menu_open is None)
  assert_true(renaming.rename is Some({ device: "d_on", .. }))
}

///|
test "delete needs its confirming second click" {
  let emit = test_emit()
  let (_, signed) = update(emit, MeLoaded(login="o", avatar=""), Model::init())
  let (_, listed) = update(emit, DevicesLoaded(sample_devices()), signed)
  let (_, armed) = update(emit, DeleteAsked("d_off"), listed)
  assert_true(armed.confirm_delete is Some("d_off"))
  let (_, kept) = update(emit, DeleteCancelled, armed)
  assert_true(kept.confirm_delete is None)
  let (_, deleting) = update(emit, DeleteConfirmed("d_off"), armed)
  assert_true(deleting.busy)
}

///|
test "update is idempotent on pure transitions" {
  let emit = test_emit()
  let model = Model::init()
  let (_, once) = update(emit, MeUnauthorized, model)
  let (_, twice) = update(emit, MeUnauthorized, once)
  assert_true(twice.auth is SignedOut)
  let (_, noticed) = update(emit, MutationFailed("x"), once)
  assert_true(noticed.notice is Some("x"))
}
