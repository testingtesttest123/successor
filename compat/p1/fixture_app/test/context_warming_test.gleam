//// A native observer can retain a warming handle across an idle mutation.
//// The stock HTTP interface cannot inject that delayed saved-request message.

import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/daemon/session
import albedo/daemon/session_configuration
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import context_fixture as fixture
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
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
      0,
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
  observer_handle_captures_current_composition_after_reload_test()
  queued_stock_warming_refuses_after_global_enable_and_reload_test()
  queued_stock_warming_refuses_after_failed_reload_test()
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

@external(erlang, "context_fixture_counter", "with_provider_home")
fn with_provider_home(run: fn(String) -> a) -> a

pub fn queued_stock_warming_refuses_after_global_enable_and_reload_test() -> Nil {
  queued_stock_warming(False)
}

pub fn queued_stock_warming_refuses_after_failed_reload_test() -> Nil {
  queued_stock_warming(True)
}

fn queued_stock_warming(fail_reload: Bool) -> Nil {
  use home <- with_provider_home
  let entered = process.new_subject()
  let sent = process.new_subject()
  let captures = fixture.counter()
  let provider =
    extension.Extension(
      "fixture-provider",
      "local fake",
      [],
      [
        extension.ModelProviderPlugin(
          extension.ModelProvider("fixture-provider", fn(_) {
            Some(
              Ok(
                fixture.upstream(types.Responses, fn(request, _) {
                  process.send(sent, request)
                  Ok(fixture.complete())
                }),
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let required =
    extension.Extension(
      "required-identity",
      "setup-required identity",
      [],
      [
        extension.ManagedPlugin(fn(_, _, _) {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(_) = process.receive(release, 5000)
          case fail_reload {
            True -> Error("fixture reload failure")
            False -> Ok(extension.empty())
          }
        }),
        extension.RequestContextPlugin(
          fn(_) {
            let _ = fixture.next(captures)
            Error("setup_required")
          },
          True,
        ),
      ],
      extension.no_initialise,
    )
  let host =
    fixture.start_host(extensions.Config([provider, required], [provider.name]))
  let ledger = runtime.ledger(host)
  let assert Ok(_) = runtime.open_session(host, "s", home)
  let assert Ok(info) = conversation.get(ledger, "s")
  let assert Ok(actor) = session.start(host, info, home)
  let assert Ok(captured) =
    store.query(ledger, session_configuration.read_in(_, "s"))
  let assert Ok(_) =
    selection.record(ledger, "s", selection.SetGlobal(required.name, True))
  let request =
    types.Request(
      "model",
      Some("stock request without identity"),
      [types.User("old")],
      [],
      None,
      types.defaults,
    )
  let reloaded = process.new_subject()
  let reply = process.new_subject()
  process.send(actor, session.ReloadData(reloaded))
  let release = fixture.receive(entered)
  // Reload is now blocked in composition preparation. The old observer's
  // message reaches the actor mailbox before its sender is killed on close.
  let queued = process.new_subject()
  let old_sender =
    process.spawn_unlinked(fn() {
      process.send(
        actor,
        session.CallInBackground(
          captured.revision,
          0,
          request,
          requests.direct_prefix(
            "stock request without identity",
            [],
            request.input,
          ),
          reply,
        ),
      )
      process.send(queued, Nil)
      let _ = process.receive(process.new_subject(), 5000)
      Nil
    })
  fixture.receive(queued)
  process.kill(old_sender)
  process.send(release, Nil)
  let assert Ok(reload_outcome) = process.receive(reloaded, 30_000)
  let assert Ok(outcome) = process.receive(reply, 30_000)
  let escaped = process.receive(sent, 0)
  session.close(actor)
  runtime.stop(host)
  result.is_ok(reload_outcome) |> should.equal(!fail_reload)
  outcome |> should.equal(Error("configuration_changed"))
  escaped |> should.be_error
  fixture.read(captures) |> should.equal(0)
}

pub fn observer_handle_captures_current_composition_after_reload_test() -> Nil {
  use home <- with_provider_home
  let sent = process.new_subject()
  let handles = process.new_subject()
  let provider =
    extension.Extension(
      "fixture-provider",
      "local fake",
      [],
      [
        extension.ModelProviderPlugin(
          extension.ModelProvider("fixture-provider", fn(_) {
            Some(
              Ok(
                fixture.upstream(types.Responses, fn(request, _) {
                  process.send(sent, request)
                  Ok(fixture.complete())
                }),
              ),
            )
          }),
        ),
        extension.ManagedPlugin(fn(_, _, _) {
          Ok(
            extension.Managed(..extension.empty(), observe: fn(handle, _) {
              process.send(handles, handle)
            }),
          )
        }),
      ],
      extension.no_initialise,
    )
  let host = fixture.start_host(extensions.Config([provider], [provider.name]))
  let assert Ok(_) = runtime.open_session(host, "s", home)
  let assert Ok(info) = conversation.get(runtime.ledger(host), "s")
  let assert Ok(actor) = session.start(host, info, home)
  let request =
    types.Request(
      "model",
      Some("captured identity"),
      [types.User("saved")],
      [],
      None,
      types.defaults,
    )
  let prefix = requests.direct_prefix("captured identity", [], request.input)
  let reloaded = process.new_subject()
  process.send(actor, session.ReloadData(reloaded))
  let assert Ok(Ok(_)) = process.receive(reloaded, 30_000)
  let first = observe_handle(actor, handles)
  first.call(request, prefix) |> should.be_ok
  fixture.receive(sent) |> should.equal(request)
  process.send(actor, session.ReloadData(reloaded))
  let assert Ok(Ok(_)) = process.receive(reloaded, 30_000)
  first.call(request, prefix) |> should.equal(Error("configuration_changed"))
  process.receive(sent, 0) |> should.be_error
  let second = observe_handle(actor, handles)
  second.call(request, prefix) |> should.be_ok
  fixture.receive(sent) |> should.equal(request)
  session.close(actor)
  runtime.stop(host)
}

fn observe_handle(
  actor: session.Session,
  handles: process.Subject(extension.Session),
) -> extension.Session {
  // A rejected context-window edit emits Stirred without changing configuration.
  // The real observer receives the actor's current background handle.
  let reply = process.new_subject()
  process.send(actor, session.ChangeCompactAt(Some(-1), reply))
  fixture.receive(reply) |> should.be_error
  fixture.receive(handles)
}
