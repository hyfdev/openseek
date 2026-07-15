///|
test "device id from relay page paths" {
  debug_inspect(
    @interop.device_id_in_path("/d/d_abc123/"),
    content="Some(\"d_abc123\")",
  )
  debug_inspect(
    @interop.device_id_in_path("/d/d_abc123/index.html"),
    content="Some(\"d_abc123\")",
  )
  debug_inspect(
    @interop.device_id_in_path("/d/d_abc123"),
    content="Some(\"d_abc123\")",
  )
  debug_inspect(@interop.device_id_in_path("/"), content="None")
  debug_inspect(@interop.device_id_in_path(""), content="None")
  debug_inspect(@interop.device_id_in_path("/d/"), content="None")
  debug_inspect(@interop.device_id_in_path("/d//ws"), content="None")
  debug_inspect(@interop.device_id_in_path("/devices/d_abc"), content="None")
}
