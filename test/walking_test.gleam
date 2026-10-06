import gleam/erlang/process
import gleam/list
import gleam/string
import successor/agent
import successor/app
import successor/config
import successor/db
import successor/ids
import successor/provider
import successor/session

// Chapter 23.1F walking scenario gate:
//   operator message -> durable user record -> activation -> passthrough
//   ContextPlan -> provider request -> response -> durable assistant record
//   + attempt receipts -> process restart -> same canonical history.
// Plus the stale-activation gate: a completion carrying a non-current
// activation/generation never settles into history.

pub fn walking_turn_persists_and_survives_restart_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(data_dir: dir), events)

  // Create + open a session through the operator surface; hold the durable
  // identity, resolve the live handle through the registry.
  let assert Ok(sid) = app.start_session(host, name: "walking")
  let assert Ok(sess) = app.session_of(host, sid)

  // Submit one user turn.
  let assert Ok(_activation) = session.submit(sess, text: "hello successor")

  // The turn completes asynchronously: await its completion event.
  let assert agent.TurnCompleted(_, _, assistant) =
    await_completed(host.events, 15_000)

  // Canonical history: exactly [user, assistant], echo content, sequences 1,2.
  let assert Ok(records) =
    session.records(
      host.store,
      session: assistant.session,
      branch: assistant.branch,
    )
  let assert [user, assistant_record] = records
  assert user.kind == "user"
  assert assistant_record.kind == "assistant"
  assert user.sequence == 1
  assert assistant_record.sequence == 2
  assert string.contains(assistant_record.payload, "hello successor")
  assert string.contains(assistant_record.payload, "[Echo]")

  let canonical_before = canonical(records)
  app.stop(host)

  // Restart on the same data dir: the original session's canonical history
  // is byte-for-byte the same (ids/sequences/kinds/payloads — timestamps
  // are not contractual, chapter 23.1F).
  let assert Ok(host2) = app.start(config.default(data_dir: dir), events)
  let assert Ok(reopened) = app.open_session(host2, session: sid)
  assert reopened == sid
  let assert Ok(records2) =
    session.records(
      host2.store,
      session: assistant.session,
      branch: assistant.branch,
    )
  assert canonical_before == canonical(records2)
  assert records2 == records
  let assert Ok(resumed) = app.session_of(host2, sid)
  let assert Ok(_) = session.submit(resumed, text: "after restart")
  let assert agent.TurnCompleted(completed_id, _, next) =
    await_completed(host2.events, 15_000)
  assert completed_id == sid
  assert next.branch == assistant.branch
  let assert Ok([saved_user, saved_assistant, next_user, next_assistant]) =
    session.records(host2.store, session: sid, branch: assistant.branch)
  assert saved_user == user
  assert saved_assistant == assistant_record
  assert [next_user.sequence, next_assistant.sequence] == [3, 4]
  app.stop(host2)
}

pub fn stale_completion_never_settles_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(data_dir: dir), events)
  let assert Ok(sid) = app.start_session(host, name: "stale")
  let assert Ok(sess) = app.session_of(host, sid)
  let agent_subject = session.agent_subject(sess)

  // Turn one: completes normally.
  let assert Ok(_a1) = session.submit(sess, text: "first")
  let assert agent.TurnCompleted(_, _, r1) =
    await_completed(host.events, 15_000)

  let assert Ok(records_before) =
    session.records(host.store, session: r1.session, branch: r1.branch)

  // Forge a STALE completion: bogus activation, generation 0 (current >= 1).
  process.send(
    agent_subject,
    agent.ProviderDone(
      attempt: ids.new_provider_attempt_id(),
      activation: ids.new_activation_id(),
      generation: 0,
      result: Error(provider.Provider("forged stale completion")),
    ),
  )
  process.sleep(100)

  // History is unchanged: the stale completion settled nothing.
  let assert Ok(records_after) =
    session.records(host.store, session: r1.session, branch: r1.branch)
  assert canonical(records_before) == canonical(records_after)
  app.stop(host)
}

pub fn second_turn_appends_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(data_dir: dir), events)
  let assert Ok(sid) = app.start_session(host, name: "two-turns")
  let assert Ok(sess) = app.session_of(host, sid)

  let assert Ok(_) = session.submit(sess, text: "one")
  let assert agent.TurnCompleted(_, _, r1) =
    await_completed(host.events, 15_000)
  let assert Ok(_) = session.submit(sess, text: "two")
  let assert agent.TurnCompleted(_, _, _r2) =
    await_completed(host.events, 15_000)

  let assert Ok(records) =
    session.records(host.store, session: r1.session, branch: r1.branch)
  let assert [u1, a1, u2, a2] = records
  assert [u1.sequence, a1.sequence, u2.sequence, a2.sequence] == [1, 2, 3, 4]
  assert string.contains(a2.payload, "[Echo] two")
  app.stop(host)
}

// --- helpers --------------------------------------------------------------

/// Await a TurnCompleted, failing loudly on TurnFailed.
fn await_completed(
  events: process.Subject(agent.TurnEvent),
  timeout: Int,
) -> agent.TurnEvent {
  case process.receive(events, timeout) {
    Ok(agent.TurnCompleted(_, _, _) as done) -> done
    Ok(agent.TurnStarted(_, _)) -> await_completed(events, timeout)
    Ok(agent.TurnFailed(_, _, reason)) -> panic as { "turn failed: " <> reason }
    Error(_) -> panic as "timed out awaiting turn completion"
  }
}

/// Canonical projection: sequence + kind + payload, in order. Timestamps and
/// generated record ids are not contractual.
fn canonical(records: List(db.Record)) -> List(#(Int, String, String)) {
  list.map(records, fn(r: db.Record) { #(r.sequence, r.kind, r.payload) })
}

fn tmp_dir() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-walktest")
}
