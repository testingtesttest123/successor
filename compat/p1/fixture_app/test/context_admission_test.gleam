import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/runtime
import context_fixture as fixture
import gleam/erlang/process
import gleam/string
import gleeunit/should

pub fn selected_required_owner_missing_from_cached_composition_requires_reload_test() {
  let declaration =
    fixture.declaration(fixture.counter(), process.new_subject(), [])
  let host = fixture.start_host(extensions.Config([declaration], []))
  let assert Ok(cached) = runtime.open_session(host, "s", "/tmp")
  runtime.admit(host, cached) |> should.equal(Ok(Nil))
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    selection.record(ledger, "s", selection.SetSession("fixture", True))
  store.query(runtime.ledger(host), session_requirements.required_in(_, "s"))
  |> should.equal(Ok([]))
  let assert Error(reason) = runtime.admit(host, cached)
  string.contains(reason, "reload required") |> should.be_true
  let assert Ok(_) = runtime.reload_desired(host, "s", "/tmp")
  let assert Ok(reloaded) = runtime.open_session(host, "s", "/tmp")
  runtime.admit(host, reloaded) |> should.equal(Ok(Nil))
  runtime.stop(host)
}

pub fn deselected_required_owner_in_cached_composition_requires_reload_test() {
  let #(host, cached) =
    fixture.start([
      fixture.declaration(fixture.counter(), process.new_subject(), []),
    ])
  let assert Ok(_) =
    selection.record(
      runtime.ledger(host),
      "s",
      selection.SetSession("fixture", False),
    )
  store.query(runtime.ledger(host), session_requirements.required_in(_, "s"))
  |> should.equal(Ok([]))
  let assert Error(reason) = runtime.admit(host, cached)
  string.contains(reason, "reload required") |> should.be_true
  let assert Ok(_) = runtime.reload_desired(host, "s", "/tmp")
  let assert Ok(reloaded) = runtime.open_session(host, "s", "/tmp")
  runtime.admit(host, reloaded) |> should.equal(Ok(Nil))
  runtime.stop(host)
}
