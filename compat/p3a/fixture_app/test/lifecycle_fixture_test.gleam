//// Native transactional contract tests: callback failure and exact fork cuts
//// cannot be forced through stock HTTP because stock has no lifecycle owner.
//// Real SQLite, runtime catalog, admission, family, inbox and history are used.

import albedo/daemon/bus
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/daemon/mail
import albedo/daemon/operations
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/lcm/graph
import albedo/harness/runtime
import albedo/harness/session_lifecycle as lifecycle
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit
import gleeunit/should
import sqlight

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "lifecycle_fixture_id", "operation_id")
fn operation_id() -> String

fn info(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "new session",
    "/tmp",
    "fixture",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.exec(
      db,
      "CREATE TABLE fixture_identity(session TEXT PRIMARY KEY,live TEXT NOT NULL); CREATE TABLE fixture_events(event TEXT,session TEXT); CREATE TABLE fixture_mapping(source_session TEXT,source_seq INTEGER,branch_session TEXT,branch_seq INTEGER);",
    )
  })
}

fn needed(
  db: sqlight.Connection,
  event: lifecycle.Event,
) -> Result(Bool, String) {
  let parent = case event {
    lifecycle.Created(_) -> ""
    lifecycle.Child(parent, _) | lifecycle.Fork(parent, _, _, _) -> parent
  }
  case event {
    lifecycle.Created(_) -> Ok(True)
    _ ->
      store.rows(
        db,
        "SELECT live FROM fixture_identity WHERE session=?",
        [sqlight.text(parent)],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map(fn(rows) { !list.is_empty(rows) })
  }
}

fn apply(
  db: sqlight.Connection,
  event: lifecycle.Event,
) -> Result(Nil, String) {
  let #(kind, session) = case event {
    lifecycle.Created(session) -> #("created", session)
    lifecycle.Child(_, child) -> #("child", child)
    lifecycle.Fork(_, child, _, _) -> #("fork", child)
  }
  use _ <- result.try(
    store.run(db, "INSERT INTO fixture_events VALUES(?,?)", [
      sqlight.text(kind),
      sqlight.text(session),
    ]),
  )
  case event {
    lifecycle.Created(_) -> Ok(Nil)
    lifecycle.Child(parent, child) ->
      store.run(
        db,
        "INSERT INTO fixture_identity SELECT ?,live FROM fixture_identity WHERE session=?",
        [sqlight.text(child), sqlight.text(parent)],
      )
    lifecycle.Fork(parent, child, _, mapping) -> {
      use _ <- result.try(
        store.run(
          db,
          "INSERT INTO fixture_identity SELECT ?,live FROM fixture_identity WHERE session=?",
          [sqlight.text(child), sqlight.text(parent)],
        ),
      )
      list.try_each(mapping, fn(pair) {
        store.run(db, "INSERT INTO fixture_mapping VALUES(?,?,?,?)", [
          sqlight.text(pair.0.session),
          sqlight.int(pair.0.seq),
          sqlight.text(pair.1.session),
          sqlight.int(pair.1.seq),
        ])
      })
    }
  }
}

fn declaration() -> extension.Extension {
  extension.Extension(
    "fixture-lineage",
    "Unrelated shared live ID acceptance owner",
    [],
    [extension.SessionLifecyclePlugin(lifecycle.Contribution(needed, apply))],
    initialise,
  )
}

fn host() -> runtime.Runtime {
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([declaration()], []),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) = mail.initialise(ledger)
  host
}

fn count(ledger: store.Store, table: String) -> Int {
  let assert Ok(count) =
    store.query(ledger, fn(db) {
      store.one(
        db,
        "SELECT count(*) FROM " <> table,
        [],
        decode.field(0, decode.int, decode.success),
        "count failed",
      )
    })
  count
}

fn parent(host: runtime.Runtime) -> Nil {
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.create(ledger, info("parent"), [])
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "INSERT INTO fixture_identity VALUES('parent','same-live-id');",
      )
    })
  Nil
}

fn task(body: String) -> mail.Letter {
  mail.Letter("task", "child", Some("parent"), "parent", mail.Task, body, 1)
}

fn failing(raise_crash: Bool) -> List(lifecycle.Owner) {
  [
    lifecycle.Owner("fixture-lineage", lifecycle.Ready, [
      lifecycle.Contribution(needed, fn(db, event) {
        use _ <- result.try(apply(db, event))
        case raise_crash {
          True -> panic as "fixture callback panic"
          False -> Error("fixture callback refused")
        }
      }),
    ]),
  ]
}

pub fn disabled_declaration_still_inherits_live_identity_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    conversation.create_child(
      ledger,
      info("child"),
      "parent",
      "worker",
      Some(task("do work")),
      runtime.lifecycle_owners(host),
    )
  let assert Ok(live) =
    store.query(ledger, fn(db) {
      store.one(
        db,
        "SELECT live FROM fixture_identity WHERE session='child'",
        [],
        decode.field(0, decode.string, decode.success),
        "missing identity",
      )
    })
  live |> should.equal("same-live-id")
  count(ledger, "mail") |> should.equal(1)
  count(ledger, "session_family") |> should.equal(1)
  runtime.stop(host)
}

pub fn invalid_initial_task_leaves_no_child_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    Some(task("  ")),
    runtime.lifecycle_owners(host),
  )
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "session_family") |> should.equal(0)
  count(ledger, "mail") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  runtime.stop(host)
}

fn refused_child(raise_crash: Bool) -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    Some(task("work")),
    failing(raise_crash),
  )
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "session_family") |> should.equal(0)
  count(ledger, "mail") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  count(ledger, "fixture_identity") |> should.equal(1)
  // The same store remains usable after returned errors and caught panics.
  let assert Ok(_) =
    conversation.create_child(
      ledger,
      info("child"),
      "parent",
      "worker",
      None,
      runtime.lifecycle_owners(host),
    )
  runtime.stop(host)
}

pub fn callback_error_rolls_back_family_task_and_identity_test() -> Nil {
  refused_child(False)
}

pub fn callback_panic_rolls_back_and_store_remains_usable_test() -> Nil {
  refused_child(True)
}

pub fn initial_mail_insert_failure_rolls_back_child_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE TRIGGER reject_task BEFORE INSERT ON mail BEGIN SELECT RAISE(ABORT,'fixture mail rejected'); END;",
      )
    })
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    Some(task("work")),
    runtime.lifecycle_owners(host),
  )
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "session_family") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  runtime.stop(host)
}

pub fn quarantined_owner_refuses_only_needed_lineage_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let owners = [
    lifecycle.Owner(
      "fixture-lineage",
      lifecycle.Quarantined("fixture unavailable"),
      [lifecycle.Contribution(needed, apply)],
    ),
  ]
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    None,
    owners,
  )
  |> should.be_error
  let assert Ok(_) = conversation.create(ledger, info("unrelated"), [])
  let assert Ok(_) =
    conversation.create_child(
      ledger,
      info("unrelated-child"),
      "unrelated",
      "worker",
      None,
      owners,
    )
  count(ledger, "fixture_events") |> should.equal(0)
  runtime.stop(host)
}

pub fn guard_error_rolls_back_without_applying_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let owners = [
    lifecycle.Owner("fixture-lineage", lifecycle.Ready, [
      lifecycle.Contribution(fn(_, _) { Error("corrupt lineage") }, apply),
    ]),
  ]
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    None,
    owners,
  )
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "fixture_events") |> should.equal(0)
  runtime.stop(host)
}

pub fn fresh_creation_callback_is_atomic_test() -> Nil {
  let host = host()
  let ledger = runtime.ledger(host)
  conversation.create(ledger, info("fresh"), failing(False)) |> should.be_error
  count(ledger, "sessions") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  let assert Ok(_) =
    conversation.create(ledger, info("fresh"), runtime.lifecycle_owners(host))
  count(ledger, "fixture_events") |> should.equal(1)
  runtime.stop(host)
}

fn creation(id: String, fingerprint: String) -> conversation.Creation {
  conversation.Creation(
    operations.Request(operation_id(), fingerprint, "create", id, None),
    "{}",
    "{}",
    None,
  )
}

pub fn identified_create_existing_and_deleted_never_repeat_callbacks_test() -> Nil {
  let host = host()
  let ledger = runtime.ledger(host)
  let owners = runtime.lifecycle_owners(host)
  let request = creation("fresh", "same")
  let assert Ok(_) =
    conversation.create_identified(ledger, info("fresh"), request, owners)
  conversation.create_identified(ledger, info("fresh"), request, owners)
  |> should.equal(Error("session_exists"))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "DELETE FROM sessions WHERE id='fresh'; UPDATE session_creation SET deleted_at=1 WHERE session_id='fresh';",
      )
    })
  conversation.create_identified(ledger, info("fresh"), request, owners)
  |> should.equal(Error("session_deleted"))
  count(ledger, "fixture_events") |> should.equal(1)
  runtime.stop(host)
}

pub fn rejected_receipt_replay_skips_callback_test() -> Nil {
  let host = host()
  let ledger = runtime.ledger(host)
  let request = creation("fresh", "same")
  let assert Ok(_) =
    operations.reject(
      ledger,
      request.request,
      operations.Rejection(400, "fixture_rejected", "fixture rejection"),
    )
  let assert Ok(receipt) =
    conversation.create_identified(
      ledger,
      info("fresh"),
      request,
      failing(True),
    )
  receipt.status |> should.equal("rejected")
  count(ledger, "sessions") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  conversation.create_identified(
    ledger,
    info("fresh"),
    conversation.Creation(
      ..request,
      request: operations.Request(..request.request, fingerprint: "changed"),
    ),
    runtime.lifecycle_owners(host),
  )
  |> should.be_error
  count(ledger, "fixture_events") |> should.equal(0)
  runtime.stop(host)
}

pub fn fork_mapping_excludes_synthetic_tool_results_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(call) =
    json.parse(
      "{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"pending\",\"name\":\"tool\",\"arguments\":\"{}\"}",
      types.replay_decoder(types.Responses),
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "parent",
      [types.User("start"), types.Replay(call)],
      conversation.Idle,
    )
  let assert Ok([first, second]) = conversation.load_sources(ledger, "parent")
  // Introduce a global sequence gap with another session.
  let assert Ok(_) = conversation.create(ledger, info("other"), [])
  let assert Ok(_) =
    conversation.commit(ledger, "other", [types.User("gap")], conversation.Idle)
  let assert Ok(_) =
    history.fork(
      ledger,
      "parent",
      "branch",
      second.source.seq,
      runtime.lifecycle_owners(host),
    )
  let assert Ok([branch_first, branch_second, synthetic]) =
    conversation.load_sources(ledger, "branch")
  let assert Ok(mapping) =
    store.query(ledger, fn(db) {
      store.rows(
        db,
        "SELECT source_seq,branch_seq FROM fixture_mapping ORDER BY source_seq",
        [],
        {
          use source <- decode.field(0, decode.int)
          use branch <- decode.field(1, decode.int)
          decode.success(#(source, branch))
        },
      )
    })
  mapping
  |> should.equal([
    #(first.source.seq, branch_first.source.seq),
    #(second.source.seq, branch_second.source.seq),
  ])
  synthetic.entry.input
  |> should.equal(
    types.ToolOutput("pending", "not executed after branch checkpoint", []),
  )
  runtime.stop(host)
}

pub fn fork_callback_failure_rolls_back_copied_prefix_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "parent",
      [types.User("start")],
      conversation.Idle,
    )
  let assert Ok([row]) = conversation.load_sources(ledger, "parent")
  history.fork(ledger, "parent", "branch", row.source.seq, failing(False))
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "transcript") |> should.equal(1)
  count(ledger, "fixture_mapping") |> should.equal(0)
  runtime.stop(host)
}

pub fn omitted_lcm_memory_declaration_preserves_native_fork_inheritance_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = graph.initialise(ledger)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "parent",
      [types.User("first"), types.Assistant("answer"), types.User("next")],
      conversation.Idle,
    )
  let assert Ok([first, second, third]) =
    conversation.load_sources(ledger, "parent")
  let assert Ok(_) =
    graph.save_leaves(ledger, "parent", [
      graph.Leaf(first.source.seq, second.source.seq, "complete fold"),
      graph.Leaf(third.source.seq, third.source.seq, "later fold"),
    ])
  let assert Ok(_) =
    history.fork(ledger, "parent", "branch", second.source.seq, [])
  let assert Ok([node]) = graph.frontier(ledger, "branch")
  node.summary |> should.equal("complete fold")
  let assert Ok([_, branch_second]) =
    conversation.load_sources(ledger, "branch")
  graph.last_seq(ledger, "branch") |> should.equal(Ok(branch_second.source.seq))
  runtime.stop(host)
}

pub fn canonical_healthy_owner_is_not_quarantined_by_duplicate_test() -> Nil {
  let first = declaration()
  let duplicate =
    extension.Extension(..first, initialise: fn(_) {
      Error("must not start duplicate")
    })
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([first, duplicate], []),
    )
  let assert [owner] = runtime.lifecycle_owners(host)
  owner.availability |> should.equal(lifecycle.Ready)
  list.length(runtime.quarantined(host)) |> should.equal(1)
  runtime.stop(host)
}

pub fn failed_canonical_owner_reports_its_initialiser_failure_test() -> Nil {
  let failed =
    extension.Extension(..declaration(), initialise: fn(_) {
      Error("fixture unavailable")
    })
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([failed, failed], []),
    )
  let assert [owner] = runtime.lifecycle_owners(host)
  owner.availability
  |> should.equal(lifecycle.Quarantined(
    "it did not install: fixture unavailable",
  ))
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.create(ledger, info("fresh"), runtime.lifecycle_owners(host))
  |> should.equal(Error(
    "fixture-lineage: required lifecycle owner is quarantined: it did not install: fixture unavailable",
  ))
  count(ledger, "sessions") |> should.equal(0)
  runtime.stop(host)
}

pub fn failed_initialiser_retains_guard_but_never_applies_test() -> Nil {
  let failed =
    extension.Extension(..declaration(), initialise: fn(_) {
      Error("fixture unavailable")
    })
  let assert Ok(host) =
    runtime.start_with_config(":memory:", extensions.Config([failed], []))
  let assert [owner] = runtime.lifecycle_owners(host)
  case owner.availability {
    lifecycle.Quarantined(_) -> Nil
    _ -> panic as "failed declaration lost quarantine"
  }
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  // Created guard is true without touching the unavailable fixture table.
  conversation.create(ledger, info("fresh"), runtime.lifecycle_owners(host))
  |> should.be_error
  count(ledger, "sessions") |> should.equal(0)
  runtime.stop(host)
}

pub fn commit_failure_rolls_back_child_task_and_callback_writes_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE TABLE fixture_deferred(id TEXT REFERENCES sessions(id) DEFERRABLE INITIALLY DEFERRED);",
      )
    })
  let owners = [
    lifecycle.Owner("fixture-lineage", lifecycle.Ready, [
      lifecycle.Contribution(needed, fn(db, event) {
        use _ <- result.try(apply(db, event))
        store.exec(db, "INSERT INTO fixture_deferred VALUES('missing');")
      }),
    ]),
  ]
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    Some(task("work")),
    owners,
  )
  |> should.be_error
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "mail") |> should.equal(0)
  count(ledger, "fixture_events") |> should.equal(0)
  count(ledger, "fixture_deferred") |> should.equal(0)
  let assert Ok(_) =
    conversation.create_child(
      ledger,
      info("child"),
      "parent",
      "worker",
      Some(task("work")),
      runtime.lifecycle_owners(host),
    )
  runtime.stop(host)
}

pub fn identified_child_task_and_callback_share_admission_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let input_id = operation_id()
  let request =
    conversation.ChildCreation(
      info("child"),
      creation("child", "same"),
      "parent",
      "worker",
      operations.Request(input_id, "task-fingerprint", "message", "child", None),
      <<1, 2, 3>>,
      mail.Letter(..task("work"), id: input_id),
    )
  conversation.create_child_identified(ledger, request, failing(False))
  |> should.equal(Error("fixture-lineage: fixture callback refused"))
  count(ledger, "sessions") |> should.equal(1)
  count(ledger, "pending_inputs") |> should.equal(0)
  count(ledger, "operations") |> should.equal(0)
  count(ledger, "mail") |> should.equal(0)
  let assert Ok(_) =
    conversation.create_child_identified(
      ledger,
      request,
      runtime.lifecycle_owners(host),
    )
  count(ledger, "pending_inputs") |> should.equal(1)
  count(ledger, "operations") |> should.equal(2)
  count(ledger, "fixture_events") |> should.equal(1)
  conversation.create_child_identified(ledger, request, failing(True))
  |> should.equal(Error("session_exists"))
  count(ledger, "fixture_events") |> should.equal(1)
  runtime.stop(host)
}

pub fn identified_fork_callback_is_inside_admission_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "parent",
      [types.User("start")],
      conversation.Idle,
    )
  let assert Ok([row]) = conversation.load_sources(ledger, "parent")
  let request =
    history.ForkCreation(
      "parent",
      "branch",
      row.source.seq,
      creation("branch", "same"),
    )
  history.fork_identified(ledger, request, failing(False))
  |> should.equal(Error("fixture-lineage: fixture callback refused"))
  count(ledger, "operations") |> should.equal(0)
  count(ledger, "sessions") |> should.equal(1)
  let assert Ok(_) =
    history.fork_identified(ledger, request, runtime.lifecycle_owners(host))
  count(ledger, "operations") |> should.equal(1)
  count(ledger, "fixture_events") |> should.equal(1)
  history.fork_identified(ledger, request, failing(True))
  |> should.equal(Error("session_exists"))
  runtime.stop(host)
}

pub fn creation_is_silent_until_caller_announces_committed_task_test() -> Nil {
  let host = host()
  parent(host)
  let ledger = runtime.ledger(host)
  let subscription =
    bus.subscribe_filtered(process.self(), fn() { Nil }, ["parent", "child"])
  conversation.create_child(
    ledger,
    info("child"),
    "parent",
    "worker",
    Some(task("work")),
    failing(False),
  )
  |> should.be_error
  bus.drain(subscription) |> should.equal(bus.Batch([], False))
  let assert Ok(_) =
    conversation.create_child(
      ledger,
      info("child"),
      "parent",
      "worker",
      Some(task("work")),
      runtime.lifecycle_owners(host),
    )
  bus.drain(subscription) |> should.equal(bus.Batch([], False))
  count(ledger, "mail") |> should.equal(1)
  mail.announce(task("work"))
  let assert bus.Batch([event], False) = bus.drain(subscription)
  let assert Ok(kind) =
    json.parse(event, decode.field("type", decode.string, decode.success))
  kind |> should.equal("mail")
  runtime.stop(host)
}
