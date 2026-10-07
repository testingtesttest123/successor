import conformance_host

pub fn bridge_accepts_only_bounded_protocol_test() {
  assert conformance_host.accepts_request(
    "{\"op\":\"start\",\"dataDir\":\"/tmp/x\",\"recipe\":\"{}\"}",
  )
  assert conformance_host.accepts_request(
    "{\"op\":\"inspect\",\"dataDir\":\"/tmp/x\",\"sessionId\":\"s\"}",
  )
  assert conformance_host.accepts_request(
    "{\"op\":\"text\",\"content\":\"hello\"}",
  )
  assert conformance_host.accepts_request("{\"op\":\"stop\"}")
  assert !conformance_host.accepts_request("{\"op\":\"tool\"}")
  assert !conformance_host.accepts_request(
    "{\"op\":\"start\",\"dataDir\":\"/tmp/x\"}",
  )
  assert !conformance_host.accepts_request("{\"op\":\"stop\",\"ignored\":true}")
  assert !conformance_host.accepts_request(
    "{\"op\":\"command\",\"line\":\"/delete\"}",
  )
}
