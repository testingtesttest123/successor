import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import sqlight
import successor/agent
import successor/app
import successor/config
import successor/db
import successor/ids
import successor/providers/mock
import successor/session
import successor/session_supervisor as factory
import successor/store

// Reopening must be an idle, read-only durable operation. A second turn
// consumes the existing transcript and writes exactly one new receipt.
pub fn reopen_preserves_catalog_history_and_receipts_test() {
  let dir = tmp_dir()
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(dir), events)
  let assert Ok(sid) = app.start_session(host, "resume")
  let assert Ok(live) = app.session_of(host, sid)
  let assert Ok(first_activation) = session.submit(live, "one")
  let first = completed(events)
  let assert Ok(before) = session.records(host.store, sid, first.branch)
  app.stop(host)
  let assert Ok(conn) = db.open(dir <> "/successor.db")
  let saved_receipts = receipts(conn)
  let assert [#(_, activation, "completed", 1, 3)] = saved_receipts
  assert activation == first_activation.value
  let assert Ok(catalog) = db.list_sessions(conn)
  let assert Ok(branches) = db.list_branches(conn, sid)
  db.close(conn)

  let assert Ok(restarted) = app.start(config.default(dir), events)
  let assert Ok(reopened) = app.open_session(restarted, sid)
  assert reopened == sid
  assert process.receive(events, 50) == Error(Nil)
  let assert Ok(resumed) = app.session_of(restarted, sid)
  let assert Ok(same_history) =
    session.records(restarted.store, sid, first.branch)
  assert same_history == before
  let assert Ok(conn2) = db.open(dir <> "/successor.db")
  assert db.list_sessions(conn2) == Ok(catalog)
  assert db.list_branches(conn2, sid) == Ok(branches)
  assert receipts(conn2) == saved_receipts
  db.close(conn2)
  let assert Ok(second_activation) = session.submit(resumed, "two")
  let second = completed(events)
  assert second.session == sid
  assert second.branch == first.branch
  assert second.sequence == 4
  app.stop(restarted)

  let assert Ok(conn3) = db.open(dir <> "/successor.db")
  let after_receipts = receipts(conn3)
  assert list.length(after_receipts) == 2
  assert list.contains(after_receipts, list.first(saved_receipts) |> unwrap)
  let assert Ok(#(_, _, "completed", input_usage, _)) =
    list.find(after_receipts, fn(r) { r.1 == second_activation.value })
  // "one" + "[Echo] one" + "two": the previous turn reached the provider.
  assert input_usage == 5
  assert db.list_sessions(conn3) == Ok(catalog)
  let assert Ok([branch]) = db.list_branches(conn3, sid)
  assert branch.id == first.branch
  assert branch.head_sequence == 4
  db.close(conn3)
}

pub fn repeated_and_concurrent_open_share_one_owner_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(dir), events)
  let assert Ok(sid) = app.start_session(host, "one-owner")
  app.stop(host)
  let assert Ok(restarted) = app.start(config.default(dir), events)
  let replies = process.new_subject()
  list.each(list.repeat(Nil, 12), fn(_) {
    let _ =
      process.spawn(fn() {
        process.send(replies, app.open_session(restarted, sid))
      })
  })
  list.each(list.repeat(Nil, 12), fn(_) {
    assert process.receive(replies, 5000) == Ok(Ok(sid))
  })
  let assert Ok(original) = app.session_of(restarted, sid)
  assert app.open_session(restarted, sid) == Ok(sid)
  assert app.session_of(restarted, sid) == Ok(original)
  assert factory.count_children(restarted.sessions) == 1
  app.stop(restarted)
}

pub fn unknown_id_does_not_create_a_session_test() {
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(dir), process.new_subject())
  let assert Error(app.DurableStore(db.NotFound(_))) =
    app.open_session(host, ids.new_session_id())
  assert factory.count_children(host.sessions) == 0
  let reply = process.new_subject()
  process.send(host.store, store.ListSessions(reply))
  assert process.receive(reply, 5000) == Ok(Ok([]))
  app.stop(host)
}

pub fn reopen_uses_saved_branch_and_current_host_config_test() {
  let dir = tmp_dir()
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(dir), events)
  let assert Ok(sid) = app.start_session(host, "configured")
  app.stop(host)
  // Seed a non-main selected branch in the durable fixture. No branch
  // checkout API or migration is needed for this reopen contract test.
  let assert Ok(conn) = db.open(dir <> "/successor.db")
  let assert Ok(saved) = db.get_session(conn, sid)
  let assert Ok(other) = db.create_branch(conn, sid, "selected")
  let assert Ok(_) = db.append_record(conn, sid, other.id, "user", "prior")
  let assert Ok(_) =
    sqlight.query(
      "UPDATE sessions SET current_branch_id = ? WHERE id = ?",
      on: conn,
      with: [sqlight.text(other.id.value), sqlight.text(sid.value)],
      expecting: decode.dynamic,
    )
  db.close(conn)
  let cfg =
    config.Config(..config.default(dir), providers: [
      config.MockProvider("current", False, "configured response"),
    ])
  let assert Ok(restarted) = app.start(cfg, events)
  assert app.open_session(restarted, sid) == Ok(sid)
  let assert Ok(live) = app.session_of(restarted, sid)
  let assert Ok(_) = session.submit(live, "next")
  let record = completed(events)
  assert record.branch == other.id
  assert record.sequence == 3
  assert record.payload
    == "[{\"type\":\"text\",\"text\":\"configured response\"}]"
  assert session.records(restarted.store, sid, saved.current_branch) == Ok([])
  app.stop(restarted)
}

fn receipts(conn: sqlight.Connection) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use activation <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    use input <- decode.field(3, decode.int)
    use output <- decode.field(4, decode.int)
    decode.success(#(id, activation, status, input, output))
  }
  let assert Ok(rows) =
    sqlight.query(
      "SELECT id, activation_id, status, usage_input, usage_output FROM provider_attempts ORDER BY id",
      on: conn,
      with: [],
      expecting: decoder,
    )
  rows
}

fn completed(events: process.Subject(agent.TurnEvent)) -> db.Record {
  let assert Ok(event) = process.receive(events, 5000)
  case event {
    agent.TurnStarted(_, _) -> completed(events)
    agent.TurnCompleted(_, _, record) -> record
    agent.TurnFailed(_, _, reason) -> panic as reason
  }
}

fn unwrap(value: Result(a, b)) -> a {
  let assert Ok(value) = value
  value
}

fn tmp_dir() -> String {
  "/tmp/" <> ids.fresh("successor-resume")
}

pub fn registry_outage_cannot_duplicate_session_owner_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(tmp_dir()), events)
  let assert Ok(sid) = app.start_session(host, "registry-outage")
  let assert Ok(original) = app.session_of(host, sid)
  let assert Ok(old_registry) = process.subject_owner(host.registry)
  let monitor = process.monitor(old_registry)
  suspend(host.supervisor_pid)
  process.kill(old_registry)
  await_down(monitor)
  let opened = app.open_session(host, sid)
  let count = factory.count_children(host.sessions)
  resume(host.supervisor_pid)
  assert opened == Ok(sid)
  assert count == 1
  assert wait_session(host, sid, 100) == original
  app.stop(host)
}

pub fn reopened_runtime_is_supervised_and_shutdown_with_host_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(dir), events)
  let assert Ok(sid) = app.start_session(host, "supervised")
  app.stop(host)
  let assert Ok(restarted) = app.start(config.default(dir), events)
  assert app.open_session(restarted, sid) == Ok(sid)
  let assert Ok(original) = app.session_of(restarted, sid)
  let assert Ok(pid) = process.subject_owner(original)
  let monitor = process.monitor(pid)
  process.kill(pid)
  await_down(monitor)
  let replacement = wait_replacement(restarted, sid, original, 100)
  assert app.open_session(restarted, sid) == Ok(sid)
  assert factory.count_children(restarted.sessions) == 1
  let assert Ok(_) = session.submit(replacement, "after owner crash")
  let record = completed(events)
  assert record.session == sid
  let assert Ok(replacement_pid) = process.subject_owner(replacement)
  let shutdown = process.monitor(replacement_pid)
  app.stop(restarted)
  await_down(shutdown)
}

fn wait_session(host: app.Started, sid: ids.SessionId, attempts: Int) {
  case app.session_of(host, sid) {
    Ok(subject) -> subject
    Error(_) -> {
      assert attempts > 0
      process.sleep(10)
      wait_session(host, sid, attempts - 1)
    }
  }
}

fn wait_replacement(
  host: app.Started,
  sid: ids.SessionId,
  old: process.Subject(session.Msg),
  attempts: Int,
) {
  case app.session_of(host, sid) {
    Ok(subject) if subject != old -> subject
    _ -> {
      assert attempts > 0
      process.sleep(10)
      wait_replacement(host, sid, old, attempts - 1)
    }
  }
}

fn await_down(monitor: process.Monitor) {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

@external(erlang, "sys", "suspend")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "sys", "resume")
fn resume(pid: process.Pid) -> Nil

pub fn corrupt_saved_branch_fails_without_creating_runtime_test() {
  let dir = tmp_dir()
  let assert Ok(conn) = db.open(dir <> "/successor.db")
  let assert Ok(saved) = db.create_session(conn, ids.new_session_id(), "broken")
  let assert Ok(_) =
    sqlight.query(
      "UPDATE sessions SET current_branch_id = ? WHERE id = ?",
      on: conn,
      with: [sqlight.text("missing"), sqlight.text(saved.id.value)],
      expecting: decode.dynamic,
    )
  db.close(conn)
  let assert Ok(host) = app.start(config.default(dir), process.new_subject())
  let assert Error(app.DurableStore(db.Corrupt(_))) =
    app.open_session(host, saved.id)
  assert factory.count_children(host.sessions) == 0
  app.stop(host)
  let assert Ok(conn) = db.open(dir <> "/successor.db")
  let assert Ok([unchanged]) = db.list_sessions(conn)
  assert unchanged.current_branch == ids.BranchId("missing")
  let assert Ok([original_branch]) = db.list_branches(conn, saved.id)
  assert original_branch.id == saved.current_branch
  db.close(conn)
}

pub fn reopen_stopped_host_reports_store_unavailable_test() {
  let assert Ok(host) =
    app.start(config.default(tmp_dir()), process.new_subject())
  let assert Ok(sid) = app.start_session(host, "stopped")
  app.stop(host)
  assert app.open_session(host, sid) == Error(app.StoreUnavailable)
}

pub fn stopped_child_spec_can_be_reopened_without_duplication_test() {
  let assert Ok(host) =
    app.start(config.default(tmp_dir()), process.new_subject())
  let reply = process.new_subject()
  process.send(host.store, store.CreateSession("retained", reply))
  let assert Ok(Ok(saved)) = process.receive(reply, 5000)
  let name = process.new_name("retained_sessions")
  let assert Ok(supervisor) = factory.start(name)
  process.unlink(supervisor.pid)
  let spec =
    session.Spec(
      session: saved.id,
      branch: saved.current_branch,
      store: host.store,
      adapter: mock.adapter(mock.default_settings()),
      model: "test",
      events: host.events,
      registry: host.registry,
    )
  assert factory.start_child(supervisor.data, spec) == Ok(Nil)
  let original = wait_session(host, saved.id, 100)
  let assert Ok(original_pid) = process.subject_owner(original)
  let assert Ok(original_agent_pid) =
    process.subject_owner(session.agent_subject(original))
  let agent_monitor = process.monitor(original_agent_pid)
  let monitor = process.monitor(original_pid)
  terminate_child(name, saved.id.value)
  await_down(monitor)
  await_down(agent_monitor)
  assert factory.count_children(supervisor.data) == 0
  let replies = process.new_subject()
  list.each(list.repeat(Nil, 12), fn(_) {
    let _ =
      process.spawn(fn() {
        process.send(replies, factory.start_child(supervisor.data, spec))
      })
  })
  let results =
    list.map(list.repeat(Nil, 12), fn(_) { process.receive(replies, 5000) })
  let count = factory.count_children(supervisor.data)
  stop_supervisor(supervisor.pid)
  let unavailable = factory.start_child(supervisor.data, spec)
  app.stop(host)
  assert results == list.repeat(Ok(Ok(Nil)), 12)
  assert count == 1
  assert unavailable == Error(factory.Unavailable)
}

@external(erlang, "supervisor", "terminate_child")
fn terminate_child(name: process.Name(factory.Msg), id: String) -> Nil

@external(erlang, "successor_ffi", "stop_gen_server")
fn stop_supervisor(pid: process.Pid) -> Nil

pub fn supervisor_loss_between_start_and_restart_returns_unavailable_test() {
  let assert Ok(host) =
    app.start(config.default(tmp_dir()), process.new_subject())
  let reply = process.new_subject()
  process.send(host.store, store.CreateSession("vanishing", reply))
  let assert Ok(Ok(saved)) = process.receive(reply, 5000)
  let name = process.new_name("vanishing_sessions")
  let pid = vanishing_supervisor(name)
  let monitor = process.monitor(pid)
  let spec =
    session.Spec(
      session: saved.id,
      branch: saved.current_branch,
      store: host.store,
      adapter: mock.adapter(mock.default_settings()),
      model: "test",
      events: host.events,
      registry: host.registry,
    )
  let result = factory.start_child(factory.get_by_name(name), spec)
  await_down(monitor)
  app.stop(host)
  assert result == Error(factory.Unavailable)
}

@external(erlang, "resume_test_ffi", "vanishing_supervisor")
fn vanishing_supervisor(name: process.Name(factory.Msg)) -> process.Pid
