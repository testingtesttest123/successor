import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/string
import successor/agent
import successor/app
import successor/config
import successor/db
import successor/ids

import sqlight
import successor/providers/mock
import successor/recipe
import successor/session
import successor/store

// Review round 1 regression gates. Each test pins a finding.

/// Finding: "incompatible databases are modified before rejection."
/// The schema version must be probed read-only; a store from a different
/// schema version must be refused with its bytes untouched.
pub fn incompatible_store_is_refused_unmodified_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = db.ensure_deployment(conn)
  db.close(conn)
  let before = file_bytes(path)

  // Tamper the version to an incompatible value (the test's own mutation).
  let assert Ok(tamper) = sqlight_open(path)
  let assert Ok(_) =
    sqlight_exec(
      "UPDATE meta SET value = '999' WHERE key = 'schema_version'",
      tamper,
    )
  sqlight_close(tamper)
  let tampered = file_bytes(path)

  // The refused open must leave the tampered store BYTE-IDENTICAL: no DDL,
  // no writes of any kind before rejection.
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == tampered
  let _ = before
}

/// Finding: "forked branches start with inconsistent owned-record sequence
/// numbers." Semantics are now explicit: a fork's OWNED records continue the
/// parent's sequence space (first owned = branch_point + 1); a fresh branch
/// starts its own space at 1. The inherited history stays owned by the
/// parent branch.
pub fn fork_continues_parent_numbering_fresh_starts_at_one_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(s) = db.create_session(conn, id: session, name: "s")

  // Parent gets two records: sequences 1, 2.
  let assert Ok(_) =
    db.append_record(
      conn,
      session: session,
      branch: s.current_branch,
      kind: "user",
      payload: "a",
    )
  let assert Ok(_) =
    db.append_record(
      conn,
      session: session,
      branch: s.current_branch,
      kind: "user",
      payload: "b",
    )

  // Fork at 2: the fork's first OWNED record is sequence 3 — numbering
  // continues; the fork owns nothing below the branch point.
  let assert Ok(fork) =
    db.fork_branch(
      conn,
      session: session,
      name: "fork",
      parent: s.current_branch,
      at: 2,
    )
  assert fork.head_sequence == 2
  let assert Ok(f1) =
    db.append_record(
      conn,
      session: session,
      branch: fork.id,
      kind: "assistant",
      payload: "c",
    )
  assert f1.sequence == 3
  let assert Ok(fork_records) = db.list_records(conn, session, fork.id)
  let assert [only] = fork_records
  assert only.sequence == 3

  // A fresh branch owns nothing and starts its own space at 1.
  let assert Ok(fresh) = db.create_branch(conn, session: session, name: "fresh")
  assert fresh.head_sequence == 0
  let assert Ok(fr1) =
    db.append_record(
      conn,
      session: session,
      branch: fresh.id,
      kind: "user",
      payload: "d",
    )
  assert fr1.sequence == 1
  db.close(conn)
}

/// Finding: "'strict' configuration accepts unknown fields." Unknown keys at
/// every object level are errors now — in BOTH the canonical schema and the
/// compatibility reader (the compat path accepts legacy SHAPE, not legacy
/// permissiveness).
pub fn canonical_config_rejects_unknown_fields_at_every_level_test() {
  let assert Error(recipe.UnknownField("wat")) =
    recipe.from_json(text: "{ \"dataDir\": \"/tmp/x\", \"wat\": 1 }")
  let assert Error(recipe.UnknownField("proxies")) =
    recipe.from_json(
      text: "{ \"dataDir\": \"/x\", \"operator\": {\"host\": \"127.0.0.1\", \"port\": 0, \"proxies\": []} }",
    )
  let assert Error(recipe.UnknownField("temperature")) =
    recipe.from_json(
      text: "{ \"dataDir\": \"/x\", \"providers\": [ {\"id\": \"m\", \"kind\": \"mock\", \"temperature\": 1} ] }",
    )
}

pub fn reference_recipe_rejects_unknown_agent_fields_test() {
  let recipe_text =
    "{ \"agent\": { \"name\": \"a\", \"provider\": \"mock\", \"maxTokens\": 99 } }"
  let assert Error(recipe.UnknownField("maxTokens")) =
    recipe.read_reference_recipe(text: recipe_text)
}

/// Finding: "provider calls can proceed when saving the durable attempt
/// fails, and completion can be reported without a saved terminal receipt."
/// Both are hard gates in AgentRuntime, exercised here against a test double
/// store that fails exactly one operation:
///   - CreateAttempt fails  -> the provider call is NOT made, the turn is
///     rejected before dispatch;
///   - CompleteAttempt fails -> the turn is reported TurnFailed with an
///     outcome-uncertain receipt reason, NEVER TurnCompleted.
pub fn failed_attempt_intent_blocks_the_provider_call_test() {
  let events = process.new_subject()
  let assert Ok(agent_subject) =
    agent_under(events, fake_store(FailCreateAttempt))
  let reply = process.new_subject()
  process.send(agent_subject, agent.Activate("hello", reply))
  let assert Ok(Error(reason)) = process.receive(reply, 15_000)
  {
    assert string.contains(reason, "attempt intent not durable")
  }
}

pub fn failed_terminal_receipt_is_never_reported_completed_test() {
  let events = process.new_subject()
  let assert Ok(agent_subject) =
    agent_under(events, fake_store(FailCompleteAttempt))
  let reply = process.new_subject()
  process.send(agent_subject, agent.Activate("hello", reply))
  let assert Ok(_) = process.receive(reply, 15_000)
  // The turn settles honestly: failed with a receipt reason, never completed.
  let assert agent.TurnFailed(_, _, reason) = await_any(events)
  assert string.contains(reason, "receipt")
  assert !string.contains(reason, "completed")
}

/// Finding: "failed history reads silently become empty model context."
/// With ListRecords failing, the turn fails and no provider request is made.
pub fn broken_history_never_becomes_empty_context_test() {
  let events = process.new_subject()
  let assert Ok(agent_subject) =
    agent_under(events, fake_store(FailListRecords))
  let reply = process.new_subject()
  process.send(agent_subject, agent.Activate("hello", reply))
  let assert Ok(Error(reason)) = process.receive(reply, 15_000)
  {
    assert string.contains(reason, "history read failed")
  }
  // And no turn event was ever emitted: the turn never started.
  let assert Error(_) = process.receive(events, 300)
}

// --- fake store: a store.Msg test double ----------------------------------

type FakeFault {
  FailCreateAttempt
  FailListRecords
  FailCompleteAttempt
}

fn fake_store(fault: FakeFault) -> Subject(store.Msg) {
  let assert Ok(started) =
    actor.new(fault)
    |> actor.on_message(fn(fault: FakeFault, msg: store.Msg) {
      case msg {
        store.CreateSession(_, reply) -> {
          process.send(reply, Ok(fake_session()))
          actor.continue(fault)
        }
        store.AppendRecord(_, _, kind, _, reply) -> {
          process.send(reply, Ok(fake_record(kind, 1)))
          actor.continue(fault)
        }
        store.ListRecords(_, _, reply) ->
          case fault {
            FailListRecords -> {
              process.send(reply, Error(db.NotFound("injected")))
              actor.continue(fault)
            }
            _ -> {
              process.send(
                reply,
                Ok([fake_record("user", 1), fake_record("assistant", 2)]),
              )
              actor.continue(fault)
            }
          }
        store.CreateAttempt(_, _, _, _, _, reply) ->
          case fault {
            FailCreateAttempt -> {
              process.send(reply, Error(db.NotFound("injected")))
              actor.continue(fault)
            }
            _ -> {
              process.send(reply, Ok(Nil))
              actor.continue(fault)
            }
          }
        store.CompleteAttempt(_, _, _, _, reply) ->
          case fault {
            FailCompleteAttempt -> {
              process.send(reply, Error(db.NotFound("injected")))
              actor.continue(fault)
            }
            _ -> {
              process.send(reply, Ok(Nil))
              actor.continue(fault)
            }
          }
        store.GetSession(_, reply) -> {
          process.send(reply, Ok(fake_session()))
          actor.continue(fault)
        }
        store.FindSessionByName(_, reply) -> {
          process.send(reply, Ok(fake_session()))
          actor.continue(fault)
        }
        store.ListSessions(reply) -> {
          process.send(reply, Ok([fake_session()]))
          actor.continue(fault)
        }
        store.ListBranches(_, reply) -> {
          process.send(reply, Ok([]))
          actor.continue(fault)
        }
        store.CreateBranch(_, _, _, _, reply) -> {
          process.send(reply, Error(db.Invalid("unused in fake")))
          actor.continue(fault)
        }
        store.Shutdown(reply) -> {
          process.send(reply, Nil)
          actor.stop()
        }
        store.Deployment(reply) -> {
          process.send(reply, ids.DeploymentId("dep_fake"))
          actor.continue(fault)
        }
      }
    })
    |> actor.start
  started.data
}

fn fake_session() -> db.Session {
  db.Session(
    id: ids.SessionId("ses_fake"),
    name: "fake",
    created_at_ms: 0,
    current_branch: ids.BranchId("br_fake"),
  )
}

fn fake_record(kind: String, sequence: Int) -> db.Record {
  db.Record(
    id: "rec_" <> int.to_string(sequence),
    session: ids.SessionId("ses_fake"),
    branch: ids.BranchId("br_fake"),
    sequence: sequence,
    kind: kind,
    payload: "{\"type\":\"text\",\"text\":\"fake\"}",
    created_at_ms: 0,
  )
}

/// Start an agent directly against a fake store.
fn agent_under(
  events: Subject(agent.TurnEvent),
  store: Subject(store.Msg),
) -> Result(Subject(agent.Msg), String) {
  agent.start(spec: agent.Spec(
    session: ids.SessionId("ses_fake"),
    branch: ids.BranchId("br_fake"),
    store: store,
    adapter: mock.adapter(settings: mock.default_settings()),
    events: events,
    model: "test-model",
  ))
}

fn await_any(events: Subject(agent.TurnEvent)) -> agent.TurnEvent {
  let assert Ok(event) = process.receive(events, 20_000)
  case event {
    agent.TurnStarted(_, _) -> await_any(events)
    other -> other
  }
}

/// Finding: "restarted sessions leave callers holding dead handles."
/// Handles now resolve through the registry by durable identity: a fresh
/// incarnation for the same session id is reachable by the SAME lookup.
pub fn session_identity_survives_reincarnation_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  let assert Ok(host) = app.start(config.default(data_dir: dir), events)
  let assert Ok(sid) = app.start_session(host, name: "reincarnate")
  let assert Ok(first) = app.session_of(host, sid)

  // Kill the real supervised child and wait for a different registered pid.
  // Looking up twice without killing it never exercised reincarnation.
  let assert Ok(old_pid) = process.subject_owner(first)
  process.kill(old_pid)
  let sess = await_reincarnation(host, sid, old_pid, 100)
  // Submit through the resolved handle: it is alive and serving.
  let assert Ok(_) = session.submit(sess, text: "alive")
  let assert agent.TurnCompleted(_, _, _) = await_completed(host.events)
  app.stop(host)
}

/// Finding: "the keeper can exit when its startup caller exits."
/// The keeper is spawned UNLINKED now; pinned by construction here and by
/// the reviewer's source-level check of spawn_unlinked in app.gleam. This
/// test pins the observable: app.start returns a host that outlives the
/// calling context's monitor setup — the tree stays up across a normal
/// caller return (the test process continues using the host afterwards).
pub fn host_outlives_caller_scope_test() {
  let events = process.new_subject()
  let dir = tmp_dir()
  // Simulate a transient caller: start under a spawned process that exits
  // immediately after returning the host.
  let parent: process.Subject(app.Started) = process.new_subject()
  process.spawn(fn() {
    let assert Ok(h) = app.start(config.default(data_dir: dir), events)
    process.send(parent, h)
    // exiting NOW must not tear the tree down (no link to the caller)
  })
  let assert Ok(host) = process.receive(parent, 20_000)
  // The tree is still serving: the operator answers, the store lists.
  let assert Ok(sid) = app.start_session(host, name: "outlives")
  let assert Ok(sess) = app.session_of(host, sid)
  let assert Ok(_) = session.submit(sess, text: "still here")
  let assert agent.TurnCompleted(_, _, _) = await_completed(host.events)
  app.stop(host)
}

// --- helpers --------------------------------------------------------------

fn await_completed(
  events: process.Subject(agent.TurnEvent),
) -> agent.TurnEvent {
  let assert Ok(event) = process.receive(events, 20_000)
  case event {
    agent.TurnCompleted(_, _, _) as done -> done
    agent.TurnStarted(_, _) -> await_completed(events)
    agent.TurnFailed(_, _, reason) -> panic as { "turn failed: " <> reason }
  }
}

fn file_bytes(path: String) -> BitArray {
  let assert Ok(bytes) = read_file(path)
  bytes
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)

@external(erlang, "sqlight", "open")
fn sqlight_open(path: String) -> Result(sqlight.Connection, Nil)

@external(erlang, "sqlight", "exec")
fn sqlight_exec(sql: String, conn: sqlight.Connection) -> Result(Nil, Nil)

@external(erlang, "sqlight", "close")
fn sqlight_close(conn: sqlight.Connection) -> Nil

fn tmp_db() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-reviewtest") <> "/successor.db"
}

fn tmp_dir() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-reviewtest")
}

fn await_reincarnation(
  host: app.Started,
  sid: ids.SessionId,
  old: process.Pid,
  tries: Int,
) -> Subject(session.Msg) {
  case app.session_of(host, sid) {
    Ok(subject) -> {
      let assert Ok(pid) = process.subject_owner(subject)
      case pid != old {
        True -> subject
        False -> retry_reincarnation(host, sid, old, tries)
      }
    }
    _ -> retry_reincarnation(host, sid, old, tries)
  }
}

fn retry_reincarnation(
  host: app.Started,
  sid: ids.SessionId,
  old: process.Pid,
  tries: Int,
) -> Subject(session.Msg) {
  assert tries > 0
  process.sleep(10)
  await_reincarnation(host, sid, old, tries - 1)
}
