//// A native observer can retain a warming handle across an idle mutation.
//// The stock HTTP interface cannot inject that delayed saved-request message.

import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/daemon/session
import albedo/daemon/session_configuration
import albedo/daemon/store
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import context_fixture as fixture
import gleam/erlang/process
import gleam/option.{Some}
import gleeunit/should

pub fn saved_warming_refuses_changed_configuration_before_provider_lookup_test() -> Nil {
  let #(host, _) = fixture.start([])
  let ledger = runtime.ledger(host)
  let assert Ok(info) = conversation.get(ledger, "s")
  let assert Ok(actor) = session.start(host, info, "/tmp")
  let assert Ok(captured) =
    store.query(ledger, session_configuration.read_in(_, "s"))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "UPDATE sessions SET config_revision=config_revision+1 WHERE id='s'",
      )
    })
  let request =
    types.Request(
      "model",
      Some("old captured identity"),
      [types.User("hello")],
      [],
      option.None,
      types.defaults,
    )
  let reply = process.new_subject()
  process.send(
    actor,
    session.CallInBackground(
      captured.revision,
      request,
      requests.direct_prefix("old captured identity", [], request.input),
      reply,
    ),
  )
  let outcome = fixture.receive(reply)
  session.close(actor)
  runtime.stop(host)
  outcome |> should.equal(Error("configuration_changed"))
}

pub fn main() -> Nil {
  saved_warming_refuses_changed_configuration_before_provider_lookup_test()
  saved_warming_reuses_request_after_source_revision_changes_test()
}

pub fn saved_warming_reuses_request_after_source_revision_changes_test() -> Nil {
  let captures = fixture.counter()
  let sent = process.new_subject()
  let #(host, kernel) =
    fixture.start([fixture.declaration(captures, process.new_subject(), [])])
  let ledger = runtime.ledger(host)
  let assert Ok(before) =
    store.query(ledger, session_configuration.read_in(_, "s"))
  fixture.change(ledger)
  let assert Ok(after) =
    store.query(ledger, session_configuration.read_in(_, "s"))
  after.revision |> should.equal(before.revision)
  let request =
    types.Request(
      "model",
      Some("revision-1"),
      [types.User("unchanged saved history")],
      [],
      option.None,
      types.defaults,
    )
  let provider =
    fixture.upstream(types.Responses, fn(request, _) {
      process.send(sent, request)
      Ok(fixture.complete())
    })
  let context =
    loop.CallContext(
      ledger,
      provider,
      "s",
      "fixture",
      "warm",
      option.None,
      fn() { runtime.admit(host, kernel) },
    )
  loop.background(
    context,
    request,
    requests.direct_prefix("revision-1", [], request.input),
  )
  |> should.be_ok
  fixture.receive(sent) |> should.equal(request)
  fixture.read(captures) |> should.equal(0)
  runtime.stop(host)
}
