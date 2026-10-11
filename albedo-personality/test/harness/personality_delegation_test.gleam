//// Native transactions and source attribution can be interrupted precisely
//// without AF_UNIX. These tests exercise real child/fork/mail stores and request
//// preparation; blocked kernel/provider wake execution is not simulated.

import albedo/clock
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/daemon/mail
import albedo/daemon/operations
import albedo/daemon/session_configuration
import albedo/daemon/session_submission
import albedo/daemon/store
import albedo/daemon/transcript_attribution
import albedo/daemon/turn
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/lcm/narration_types as n
import albedo/harness/extensions/personality/episodes
import albedo/harness/extensions/personality/extension as personality
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/tools
import albedo/harness/extensions/personality/types as p
import albedo/harness/extensions/python/kernel
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/loop
import albedo/harness/request_context
import albedo/harness/runtime
import albedo/harness/runtime/state
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import harness/session_fixture
import sqlight

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup_database(path: String) -> Nil

fn installed() -> List(extension.Extension) {
  let assert Some(strategy) =
    extension.compaction([
      lcm.configured_extension(lcm.Config(Some(20_000), 80, 25)),
    ])
  let bundle = personality.extension()
  [
    extension.Extension(
      ..bundle,
      plugins: list.map(bundle.plugins, fn(plugin) {
        case plugin {
          extension.CompactionPlugin(_) ->
            extension.CompactionPlugin(
              compaction.Strategy(..strategy, name: "personality"),
            )
          _ -> plugin
        }
      }),
    ),
    memory.extension(),
    rolling.extension(),
  ]
}

fn strategy_names() -> List(String) {
  installed()
  |> list.filter(selection.is_compaction)
  |> list.map(fn(item) { item.name })
}

fn select_rolling(host: runtime.Runtime) -> Nil {
  let db = runtime.ledger(host)
  let assert Ok(current) =
    store.query(db, session_configuration.read_in(_, "owner"))
  store.query(db, fn(connection) {
    session_configuration.commit_in(
      connection,
      session_configuration.Edit(
        session_configuration.Version(current.revision, current.family.revision),
        current,
        types.Responses,
        [session_configuration.Choice("extensions", "rolling", "rolling", True)],
      ),
    )
  })
  |> should.be_ok
  Nil
}

fn start() -> runtime.Runtime {
  start_with_defaults(["lcm-memory"])
}

fn start_with_defaults(defaults: List(String)) -> runtime.Runtime {
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed(), defaults),
    )
  session_fixture.initialise(host)
  mail.initialise(runtime.ledger(host)) |> should.be_ok
  session_fixture.create(host, "owner", "/tmp")
  host
}

fn bind(host: runtime.Runtime, writable: Bool, through: Int) -> p.Persona {
  let db = runtime.ledger(host)
  let assert Ok(persona) =
    ledger.create(db, "Ash", "Current live document", writable, True)
  ledger.bind(db, "owner", persona.id, 0, through, runtime.installed(host))
  |> should.be_ok
  persona
}

fn info(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "child",
    "/deliberately-not-parent",
    "provider",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

fn child_request(id: String) -> conversation.ChildCreation {
  let task_id = operation_id()
  let task =
    mail.Letter(
      task_id,
      id,
      Some("owner"),
      "parent",
      mail.Task,
      "Inspect the supplied TASK-ONLY goal. Return your findings.",
      1,
    )
  let submission =
    turn.Submission(
      mail.display(task),
      mail.text(task),
      "",
      turn.Mail(task_id, mail.Task),
      [],
      Some(task_id),
      Some(task_id),
    )
  conversation.ChildCreation(
    info(id),
    conversation.Creation(
      operations.Request(
        operation_id(),
        operations.fingerprint("creation"),
        "create",
        id,
        None,
      ),
      "{}",
      "{}",
      Some(id),
    ),
    "owner",
    id,
    operations.Request(
      task_id,
      operations.fingerprint("task"),
      "message",
      id,
      None,
    ),
    session_submission.encode(submission),
    task,
    strategy_names(),
  )
}

fn operation_id() -> String {
  let stamp =
    int.to_base16(clock.system_ms())
    |> string.lowercase
    |> string.pad_start(12, "0")
  string.slice(stamp, 0, 8)
  <> "-"
  <> string.slice(stamp, 8, 4)
  <> "-7000-8000-"
  <> string.slice(ledger.new_id(), 0, 12)
}

fn count(db: store.Store, table: String) -> Int {
  let assert Ok([count]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM " <> table,
      [],
      decode.field(0, decode.int, decode.success),
    )
  count
}

fn selected(host: runtime.Runtime, id: String) -> state.Session {
  let assert Ok(overrides) = selection.overrides(runtime.ledger(host), id)
  let chosen =
    selection.select(
      runtime.installed(host),
      selection.resolved_defaults(
        runtime.installed(host),
        runtime.base_defaults(host),
      ),
      overrides,
    )
  state.Session(
    id,
    "/tmp",
    unused_kernel(),
    runtime.ledger(host),
    composition.compose(chosen, runtime.ledger(host), id, "/tmp"),
    "native static instructions",
    [],
    state.Fresh,
  )
}

fn prepare(
  host: runtime.Runtime,
  session: state.Session,
  force: Bool,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
) -> compaction.Prepared {
  let assert Ok(rows) =
    conversation.load_sources(runtime.ledger(host), session.id)
  let assert Ok(prepared) =
    runtime.prepare_view_scoped(
      host,
      session,
      "model",
      "fixture",
      None,
      session.instructions,
      summarize,
      list.map(rows, fn(row) { row.entry.input }),
      force,
      types.any_images,
    )
  prepared
}

fn save(db: store.Store, id: String, text: String, answer: String) -> Nil {
  let submission = turn.Submission(text, text, "", turn.Chat, [], None, None)
  conversation.commit_operations(
    db,
    id,
    [session_submission.input(submission), types.Assistant(answer)],
    conversation.Idle,
    None,
    [],
    session_submission.commits([submission], 0),
    ledger.new_id(),
    "/tmp",
  )
  |> should.be_ok
  Nil
}

pub fn spawn_and_fork_reuse_identity_without_parent_task_context_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let persona = bind(host, True, 0)
  save(db, "owner", "PRIVATE-PARENT-ASK promise", "I acted for parent")
  let request = child_request("identified")
  conversation.create_child_identified(db, request) |> should.be_ok
  conversation.create_child(
    db,
    info("trusted"),
    "owner",
    "trusted",
    strategy_names(),
  )
  |> should.be_ok
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  list.each(["identified", "trusted", "branch"], fn(id) {
    let assert Ok(captured) = ledger.capture(db, id)
    captured.persona.id |> should.equal(persona.id)
    captured.binding.mode |> should.equal("delegate")
    captured.binding.pre_binding_through |> should.equal(0)
  })
  count(db, "personality_persona") |> should.equal(1)
  count(db, "personality_revision") |> should.equal(1)
  conversation.load(db, "identified") |> should.equal(Ok([]))
  conversation.load(db, "trusted") |> should.equal(Ok([]))
  let assert Ok([pending]) = operations.pending(db, "identified")
  let submission = session_submission.decode(pending.payload)
  submission.text |> should.equal(mail.text(request.task))
  should.be_false(string.contains(submission.text, "PRIVATE-PARENT-ASK"))
  let child = selected(host, "identified")
  let first = prepare(host, child, False, fn(_) { panic as "no child history" })
  first.inputs |> should.equal([])
  let assert Some(policy) =
    request_context.summary_policy(first.request_context)
  episodes.latest(db, "identified", policy) |> should.equal(Ok(None))
  let assert Ok(branch_rows) = conversation.load(db, "branch")
  let assert Ok(parent_rows) = conversation.load(db, "owner")
  branch_rows |> should.equal(parent_rows)
  composition.close(child.composition)
  runtime.stop(host)
}

pub fn delegate_reads_live_document_and_obeys_existing_write_configuration_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let persona = bind(host, True, 0)
  conversation.create_child(
    db,
    info("child"),
    "owner",
    "child",
    strategy_names(),
  )
  |> should.be_ok
  let child = selected(host, "child")
  let first = prepare(host, child, False, fn(_) { panic as "no history" })
  ledger.write_document(
    db,
    "owner",
    p.User("edit"),
    "Later live document",
    None,
  )
  |> should.be_ok
  let next = prepare(host, child, False, fn(_) { panic as "no history" })
  let assert [before] = first.request_context.contributions
  let assert [after] = next.request_context.contributions
  let assert [before_block] = before.instructions
  let assert [after_block] = after.instructions
  should.be_true(string.ends_with(before_block.content, "Current live document"))
  should.be_true(string.ends_with(after_block.content, "Later live document"))
  let assert Ok(edit) =
    list.find(tools.tools(), fn(tool) { tool.definition.name == "persona_edit" })
  let context =
    extension.Context(
      db,
      "child",
      child.kernel,
      "child-write",
      "/tmp",
      types.any_images,
    )
  extension.invoke(
    edit,
    context,
    json.to_string(
      json.object([
        #("old_string", json.string("Later")),
        #("new_string", json.string("Shared")),
      ]),
    ),
  )
  |> should.be_ok
  let assert Ok(parent) = ledger.capture(db, "owner")
  parent.persona.document |> should.equal("Shared live document")
  parent.persona.id |> should.equal(persona.id)
  // Model/tool parameters cannot supply host reporter or binding authority.
  let assert Ok(write) =
    list.find(tools.tools(), fn(tool) {
      tool.definition.name == "persona_write"
    })
  let assert Ok(output) =
    extension.invoke(
      write,
      extension.Context(..context, call_id: "spoof"),
      json.to_string(
        json.object([
          #("content", json.string("spoof")),
          #("reporter", json.string("agent_report:somebody:result")),
          #("persona_id", json.string("another")),
          #("source", json.string("mail")),
          #("operation_id", json.string("unrelated")),
        ]),
      ),
    )
  json.parse(output.text, decode.field("error", decode.string, decode.success))
  |> should.equal(Ok("invalid"))
  ledger.capture(db, "owner") |> should.equal(Ok(parent))
  runtime.tools(child)
  |> list.map(fn(tool) { tool.name })
  |> list.filter(fn(name) { string.starts_with(name, "persona_") })
  |> should.equal(["persona_read", "persona_write", "persona_edit"])
  // The same configured flag applies to owner and delegate, without a new ACL.
  store.write(db, "UPDATE personality_persona SET writable=0 WHERE id=?", [
    sqlight.text(persona.id),
  ])
  |> should.be_ok
  ledger.write_document(
    db,
    "child",
    p.OwnerAgent("refused-child"),
    "forbidden",
    None,
  )
  |> should.be_error
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("refused-parent"),
    "forbidden",
    None,
  )
  |> should.be_error
  count(db, "personality_persona") |> should.equal(1)
  composition.close(child.composition)
  runtime.stop(host)
}

pub fn fork_maps_witness_boundary_by_actual_rows_not_global_seq_arithmetic_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  save(db, "owner", "Witnessed source ask", "Prior author's action")
  let assert Ok(witnessed_cut) = conversation.last_seq(db, "owner")
  let persona = bind(host, True, witnessed_cut)
  session_fixture.create(host, "gap", "/tmp")
  save(db, "gap", "unrelated global sequence gap", "gap")
  save(db, "owner", "Own subsequent ask", "I acted after binding")
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  let assert Ok([a, b, c, d]) = conversation.load_sources(db, "branch")
  let assert Ok(captured) = ledger.capture(db, "branch")
  captured.persona.id |> should.equal(persona.id)
  captured.binding.pre_binding_through |> should.equal(b.source.seq)
  should.not_equal(b.source.seq, witnessed_cut)
  // A checkpoint before the original arrival contains only witnessed rows.
  let assert Ok([parent_first, _, _, _]) =
    conversation.load_sources(db, "owner")
  history.fork(db, "owner", "early-branch", parent_first.source.seq)
  |> should.be_ok
  let assert Ok([early]) = conversation.load_sources(db, "early-branch")
  let assert Ok(early_binding) = ledger.capture(db, "early-branch")
  early_binding.binding.pre_binding_through |> should.equal(early.source.seq)
  save(db, "branch", "new retained tail", "tail")
  let branch = selected(host, "branch")
  let calls = process.new_subject()
  let _ =
    prepare(host, branch, True, fn(request) {
      let assert Some(formation) = request.formation
      process.send(calls, formation.frame.sources)
      Ok("I carry the witnessed log and my later own actions.")
    })
  let assert Ok(sources) = process.receive(calls, 100)
  list.map(sources, fn(source) {
    #(source.seq, source.perspective, source.role)
  })
  |> should.equal([
    #(a.source.seq, n.Witnessed, "user"),
    #(b.source.seq, n.Witnessed, "assistant"),
    #(c.source.seq, n.Experienced, "user"),
    #(d.source.seq, n.Experienced, "assistant"),
  ])
  let assert Ok([node]) = graph.frontier(db, "branch")
  let assert Some(frame) = node.frame
  frame.perspective |> should.equal(n.Mixed)
  frame.sources |> should.equal(sources)
  composition.close(branch.composition)
  runtime.stop(host)
}

pub fn suspended_binding_is_inherited_without_enabling_tools_and_reenabled_live_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let persona = bind(host, True, 0)
  save(db, "owner", "source prefix", "action")
  selection.record(db, "owner", selection.SetSession("personality", False))
  |> should.be_ok
  conversation.create_child(
    db,
    info("child"),
    "owner",
    "child",
    strategy_names(),
  )
  |> should.be_ok
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  list.each(["child", "branch"], fn(id) {
    let assert Ok(captured) = ledger.capture(db, id)
    captured.persona.id |> should.equal(persona.id)
    let stream = selected(host, id)
    runtime.tools(stream)
    |> list.map(fn(tool) { tool.name })
    |> list.any(fn(name) { string.starts_with(name, "persona_") })
    |> should.be_false
    let prepared = prepare(host, stream, False, fn(_) { panic as "suspended" })
    prepared.request_context.contributions |> should.equal([])
    composition.close(stream.composition)
  })
  ledger.write_document(
    db,
    "owner",
    p.User("suspended-edit"),
    "Live while suspended",
    None,
  )
  |> should.be_ok
  selection.record(db, "child", selection.SetSession("personality", True))
  |> should.be_ok
  let child = selected(host, "child")
  let prepared = prepare(host, child, False, fn(_) { panic as "no history" })
  let assert [contribution] = prepared.request_context.contributions
  let assert [block] = contribution.instructions
  should.be_true(string.ends_with(block.content, "Live while suspended"))
  count(db, "personality_persona") |> should.equal(1)
  composition.close(child.composition)
  runtime.stop(host)
}

pub fn competing_explicit_strategy_suspends_both_native_child_creation_paths_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let persona = bind(host, True, 0)
  select_rolling(host)
  let assert Ok(flags) = selection.overrides(db, "owner")
  flags |> should.equal([#("rolling", True)])
  let request = child_request("identified")
  conversation.create_child_identified(db, request) |> should.be_ok
  conversation.create_child(
    db,
    info("trusted"),
    "owner",
    "trusted",
    strategy_names(),
  )
  |> should.be_ok
  list.each(["identified", "trusted"], fn(id) {
    let assert Ok(captured) = ledger.capture(db, id)
    captured.persona.id |> should.equal(persona.id)
    let assert Ok(overrides) = selection.overrides(db, id)
    // Only the necessary bundle suspension is inherited, not rolling or any
    // other parent capability. This remains off under a personality default.
    overrides |> should.equal([#("personality", False)])
    selection.select(
      runtime.installed(host),
      ["personality", "lcm-memory"],
      overrides,
    )
    |> list.any(fn(item) { item.name == "personality" })
    |> should.be_false
  })
  runtime.stop(host)
}

pub fn selected_parent_required_memory_override_follows_the_bundle_test() -> Nil {
  let host = start_with_defaults([])
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  selection.record(db, "owner", selection.SetSession("lcm-memory", True))
  |> should.be_ok
  let owner = selected(host, "owner")
  let _ = prepare(host, owner, False, fn(_) { panic as "no owner history" })
  conversation.create_child_identified(db, child_request("identified"))
  |> should.be_ok
  conversation.create_child(
    db,
    info("child"),
    "owner",
    "child",
    strategy_names(),
  )
  |> should.be_ok
  list.each(["identified", "child"], fn(id) {
    let child = selected(host, id)
    let captured =
      prepare(host, child, False, fn(_) { panic as "no child history" })
    let assert Some(_) =
      request_context.summary_policy(captured.request_context)
    let assert Ok(flags) = selection.overrides(db, id)
    list.map(flags, fn(flag) { flag.0 })
    |> should.equal(["lcm-memory", "personality"])
    composition.close(child.composition)
  })
  composition.close(owner.composition)
  runtime.stop(host)
}

pub fn damaged_bound_storage_rolls_back_native_creation_but_unbound_is_independent_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  save(db, "owner", "prefix", "action")
  session_fixture.create(host, "unbound", "/tmp")
  let before = count(db, "sessions")
  store.write(db, "DROP TABLE personality_binding_revision", []) |> should.be_ok
  let request = child_request("refused-identified")
  conversation.create_child_identified(db, request) |> should.be_error
  conversation.create_child(
    db,
    info("refused-trusted"),
    "owner",
    "refused-trusted",
    strategy_names(),
  )
  |> should.be_error
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "refused-fork", through) |> should.be_error
  count(db, "sessions") |> should.equal(before)
  count(db, "session_family") |> should.equal(0)
  count(db, "mail") |> should.equal(0)
  count(db, "pending_inputs") |> should.equal(0)
  operations.lookup(db, request.creation.request.id) |> should.equal(Ok(None))
  // A suspended pin cannot silently become unrelated after total binding loss.
  selection.record(db, "owner", selection.SetSession("personality", False))
  |> should.be_ok
  store.write(db, "DROP TABLE personality_session", []) |> should.be_ok
  conversation.create_child(
    db,
    info("refused-suspended"),
    "owner",
    "refused-suspended",
    strategy_names(),
  )
  |> should.equal(Error("personality binding storage unavailable"))
  // Explicit false without a binding is indistinguishable after corruption;
  // conservative refusal is deliberate, while an ordinary unpinned root works.
  session_fixture.create(host, "explicit-unbound", "/tmp")
  selection.record(
    db,
    "explicit-unbound",
    selection.SetSession("personality", False),
  )
  |> should.be_ok
  conversation.create_child(
    db,
    info("refused-explicit"),
    "explicit-unbound",
    "refused-explicit",
    strategy_names(),
  )
  |> should.equal(Error("personality binding storage unavailable"))
  conversation.create_child(
    db,
    info("ordinary"),
    "unbound",
    "ordinary",
    strategy_names(),
  )
  |> should.be_ok
  save(db, "unbound", "ordinary prefix", "ordinary action")
  let assert Ok(ordinary_through) = conversation.last_seq(db, "unbound")
  history.fork(db, "unbound", "ordinary-fork", ordinary_through)
  |> should.be_ok
  runtime.stop(host)
}

pub fn failure_after_binding_and_task_insert_rolls_back_every_child_fact_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  store.write(
    db,
    "CREATE TRIGGER fail_child_pending BEFORE INSERT ON pending_inputs BEGIN SELECT RAISE(ABORT,'late child failure'); END",
    [],
  )
  |> should.be_ok
  let request = child_request("late-failure")
  conversation.create_child_identified(db, request) |> should.be_error
  count(db, "sessions") |> should.equal(1)
  count(db, "session_family") |> should.equal(0)
  count(db, "personality_session") |> should.equal(1)
  count(db, "personality_binding_revision") |> should.equal(1)
  count(db, "mail") |> should.equal(0)
  count(db, "pending_inputs") |> should.equal(0)
  count(db, "session_creation") |> should.equal(0)
  count(db, "operations") |> should.equal(0)
  count(db, "personality_persona") |> should.equal(1)
  runtime.stop(host)
}

pub fn surviving_binding_history_refuses_unpinned_corruption_but_ordinary_strategy_works_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  save(db, "owner", "source prefix", "action")
  select_rolling(host)
  store.write(db, "DELETE FROM personality_session WHERE session='owner'", [])
  |> should.be_ok
  conversation.create_child(
    db,
    info("missing-current-row"),
    "owner",
    "missing-current-row",
    strategy_names(),
  )
  |> should.equal(Error("personality binding storage unavailable"))
  store.write(db, "DROP TABLE personality_session", []) |> should.be_ok
  conversation.create_child_identified(db, child_request("refused-identified"))
  |> should.equal(Error("personality binding storage unavailable"))
  conversation.create_child(
    db,
    info("refused-trusted"),
    "owner",
    "refused-trusted",
    strategy_names(),
  )
  |> should.equal(Error("personality binding storage unavailable"))
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "refused-fork", through)
  |> should.equal(Error("personality binding storage unavailable"))
  count(db, "sessions") |> should.equal(1)
  session_fixture.create(host, "ordinary", "/tmp")
  selection.record(db, "ordinary", selection.SetSession("rolling", True))
  |> should.be_ok
  conversation.create_child(
    db,
    info("ordinary-child"),
    "ordinary",
    "ordinary-child",
    strategy_names(),
  )
  |> should.be_ok
  count(db, "sessions") |> should.equal(3)
  count(db, "personality_persona") |> should.equal(1)
  runtime.stop(host)
}

pub fn temporary_fork_memory_is_readable_but_not_automatic_owner_continuity_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  save(db, "owner", "owner source", "owner action")
  save(db, "owner", "retained tail", "tail")
  let owner = selected(host, "owner")
  let _ = prepare(host, owner, True, fn(_) { Ok("Original owner memory") })
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  save(db, "branch", "branch retained tail", "tail")
  let branch = selected(host, "branch")
  let _ =
    prepare(host, branch, True, fn(_) { Ok("Later temporary branch memory") })
  let assert Ok(nodes) = graph.frontier(db, "branch")
  should.be_true(
    list.any(nodes, fn(node) { node.summary == "Later temporary branch memory" }),
  )
  session_fixture.create(host, "new-owner", "/tmp")
  ledger.resolve_fresh_binding(db, "new-owner") |> should.be_ok
  let fresh = selected(host, "new-owner")
  let captured =
    prepare(host, fresh, False, fn(_) { panic as "no fresh history" })
  let assert Some(policy) =
    request_context.summary_policy(captured.request_context)
  let assert Ok(Some(#(source, node))) =
    episodes.latest(db, "new-owner", policy)
  source |> should.equal("owner")
  node.summary |> should.equal("Original owner memory")
  let assert Some(branch_policy) =
    request_context.summary_policy(
      prepare(host, branch, False, fn(_) { panic as "stored branch history" }).request_context,
    )
  episodes.latest(db, "branch", branch_policy) |> should.equal(Ok(None))
  composition.close(fresh.composition)
  composition.close(branch.composition)
  composition.close(owner.composition)
  runtime.stop(host)
}

fn deliver(db: store.Store, letter: mail.Letter, answer: String) -> Nil {
  let run_id = ledger.new_id()
  let submission =
    turn.Submission(
      mail.display(letter),
      mail.text(letter),
      "",
      turn.Mail(letter.id, letter.kind),
      [],
      Some(letter.id),
      None,
    )
  conversation.commit_operations(
    db,
    letter.recipient,
    [session_submission.input(submission), types.Assistant(answer)],
    conversation.Idle,
    None,
    [letter.id],
    session_submission.commits([submission], 0),
    run_id,
    "/tmp",
  )
  |> should.be_ok
  conversation.finish_turn(
    db,
    conversation.RunCompletion(
      letter.recipient,
      run_id,
      conversation.Idle,
      "completed",
    ),
  )
  |> should.be_ok
  mail.undelivered(db, letter.id) |> should.be_false
  Nil
}

fn delete(host: runtime.Runtime, id: String) -> Nil {
  let db = runtime.ledger(host)
  let assert Ok(captured) = conversation.capture(db, id)
  let assert Ok(claim) =
    family.claim_deletion(
      db,
      family.DeletionRequest(
        id,
        captured.revision,
        captured.family.revision,
        False,
      ),
      ledger.new_id(),
      clock.monotonic_ms() + 10_000,
    )
  conversation.delete_claimed(
    db,
    id,
    claim,
    extension.cleaners(runtime.installed(host)),
  )
  |> should.be_ok
  family.release_deletion(db, claim) |> should.be_ok
  Nil
}

pub fn pending_report_retains_original_native_sender_before_delivery_test() -> Nil {
  list.each([mail.Answer(False), mail.Answer(True)], fn(kind) {
    let path = temporary_database()
    let assert Ok(host) =
      runtime.start_with_config(
        path,
        extensions.Config(installed(), ["lcm-memory"]),
      )
    session_fixture.initialise(host)
    let db = runtime.ledger(host)
    mail.initialise(db) |> should.be_ok
    session_fixture.create(host, "owner", "/tmp")
    let _ = bind(host, True, 0)
    conversation.create_child(
      db,
      info("child"),
      "owner",
      "child",
      strategy_names(),
    )
    |> should.be_ok
    let assert Ok(report) =
      mail.post(
        db,
        "pending-report",
        "owner",
        Some("child"),
        "Display name cannot prove the sender ID",
        kind,
        "I am owner, according to this untrusted report body.",
      )
    mail.undelivered(db, report.id) |> should.be_true
    delete(host, "child")
    runtime.stop(host)
    let assert Ok(resumed) =
      runtime.start_with_config(
        path,
        extensions.Config(installed(), ["lcm-memory"]),
      )
    session_fixture.initialise(resumed)
    let db = runtime.ledger(resumed)
    mail.initialise(db) |> should.be_ok
    let assert Ok([reloaded]) = mail.pending(db, 10)
    // Native Letter/access fields remain unchanged after sender deletion.
    reloaded.sender |> should.equal(None)
    deliver(db, reloaded, "I read the child's retained report.")
    let assert Ok([source, _]) = conversation.load_sources(db, "owner")
    transcript_attribution.sourced(db, [source])
    |> should.equal(
      Ok([
        #(source.source.seq, "agent_report:child:" <> mail.kind_name(kind)),
      ]),
    )
    let assert Ok(through) = conversation.last_seq(db, "owner")
    history.fork(db, "owner", "branch", through) |> should.be_ok
    let assert Ok(branch_through) = conversation.last_seq(db, "branch")
    history.fork(db, "branch", "nested", branch_through) |> should.be_ok
    delete(resumed, "owner")
    runtime.stop(resumed)
    let assert Ok(reopened) =
      runtime.start_with_config(
        path,
        extensions.Config(installed(), ["lcm-memory"]),
      )
    session_fixture.initialise(reopened)
    let db = runtime.ledger(reopened)
    list.each(["branch", "nested"], fn(id) {
      let assert Ok([copied, _]) = conversation.load_sources(db, id)
      transcript_attribution.sourced(db, [copied])
      |> should.equal(
        Ok([
          #(copied.source.seq, "agent_report:child:" <> mail.kind_name(kind)),
        ]),
      )
    })
    runtime.stop(reopened)
    cleanup_database(path)
  })
}

pub fn legacy_mail_upgrade_preserves_delivery_but_not_inferred_sender_facts_test() -> Nil {
  list.each([False, True], fn(delete_sender) {
    let host = start()
    let db = runtime.ledger(host)
    let _ = bind(host, True, 0)
    conversation.create_child(
      db,
      info("child"),
      "owner",
      "child",
      strategy_names(),
    )
    |> should.be_ok
    let assert Ok(report) =
      mail.post(
        db,
        "legacy-pending",
        "owner",
        Some("child"),
        "Display name is not provenance",
        mail.Answer(False),
        "Legacy pending report",
      )
    // Genuine old mail schema: no enqueue provenance column. Migration must
    // not backfill authority from sender_name or rewrite native Letter fields.
    store.write(db, "ALTER TABLE mail DROP COLUMN reporter", []) |> should.be_ok
    mail.initialise(db) |> should.be_ok
    mail.pending(db, 10) |> should.equal(Ok([report]))
    store.read(
      db,
      "SELECT reporter FROM mail WHERE id='legacy-pending'",
      [],
      decode.field(0, decode.optional(decode.string), decode.success),
    )
    |> should.equal(Ok([None]))
    mail.initialise(db) |> should.be_ok
    mail.pending(db, 10) |> should.equal(Ok([report]))
    case delete_sender {
      True -> delete(host, "child")
      False -> Nil
    }
    let assert Ok([reloaded]) = mail.pending(db, 10)
    deliver(db, reloaded, "I read the legacy report.")
    let assert Ok([source, _]) = conversation.load_sources(db, "owner")
    let actual = transcript_attribution.sourced(db, [source])
    case delete_sender {
      False ->
        actual
        |> should.equal(Ok([#(source.source.seq, "agent_report:child:result")]))
      True ->
        actual
        |> should.equal(
          Error(transcript_attribution.Unavailable(
            "source reporter metadata unavailable",
          )),
        )
    }
    mail.undelivered(db, report.id) |> should.be_false
    runtime.stop(host)
  })
}

pub fn enqueue_reporter_failure_rolls_back_identified_child_and_retry_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  store.write(
    db,
    "CREATE TRIGGER fail_enqueue_reporter BEFORE INSERT ON mail WHEN NEW.reporter IS NOT NULL BEGIN SELECT RAISE(ABORT,'enqueue reporter failure'); END",
    [],
  )
  |> should.be_ok
  let request = child_request("enqueue-failure")
  conversation.create_child_identified(db, request) |> should.be_error
  count(db, "sessions") |> should.equal(1)
  count(db, "session_family") |> should.equal(0)
  count(db, "personality_session") |> should.equal(1)
  count(db, "personality_binding_revision") |> should.equal(1)
  count(db, "mail") |> should.equal(0)
  count(db, "pending_inputs") |> should.equal(0)
  count(db, "session_creation") |> should.equal(0)
  count(db, "operations") |> should.equal(0)
  store.write(db, "DROP TRIGGER fail_enqueue_reporter", []) |> should.be_ok
  conversation.create_child_identified(db, request) |> should.be_ok
  count(db, "mail") |> should.equal(1)
  store.read(
    db,
    "SELECT reporter FROM mail",
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> should.equal(Ok(["agent_report:owner:task"]))
  runtime.stop(host)
}

pub fn native_fork_reporter_survives_sender_and_original_recipient_deletion_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  conversation.create_child(
    db,
    info("child"),
    "owner",
    "child",
    strategy_names(),
  )
  |> should.be_ok
  let assert Ok(report) =
    mail.post(
      db,
      ledger.new_id(),
      "owner",
      Some("child"),
      "child",
      mail.Answer(False),
      "Attributed original report",
    )
  deliver(db, report, "I read the original report")
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  let assert Ok(branch_through) = conversation.last_seq(db, "branch")
  history.fork(db, "branch", "nested", branch_through) |> should.be_ok
  delete(host, "child")
  let assert Ok([row, _]) = conversation.load_sources(db, "owner")
  transcript_attribution.sourced(db, [row])
  |> should.equal(Ok([#(row.source.seq, "agent_report:child:result")]))
  delete(host, "owner")
  count(db, "mail") |> should.equal(0)
  list.each(["branch", "nested"], fn(id) {
    let assert Ok([row, own]) = conversation.load_sources(db, id)
    transcript_attribution.sourced(db, [row, own])
    |> should.equal(
      Ok([
        #(row.source.seq, "agent_report:child:result"),
        #(own.source.seq, "owner_agent"),
      ]),
    )
  })
  runtime.stop(host)
}

pub fn reported_promise_returns_as_native_mail_and_survives_nested_fork_attribution_test() -> Nil {
  let host = start()
  let db = runtime.ledger(host)
  let _ = bind(host, True, 0)
  conversation.create_child(
    db,
    info("child"),
    "owner",
    "child",
    strategy_names(),
  )
  |> should.be_ok
  let assert Ok(task) =
    mail.post(
      db,
      ledger.new_id(),
      "child",
      Some("owner"),
      "parent",
      mail.Task,
      "Inspect RETURN-TASK",
    )
  deliver(db, task, "I inspected RETURN-TASK")
  mail.owes_reply(db, "child", "owner") |> should.equal(Ok(True))
  let assert Ok(report) =
    mail.post(
      db,
      ledger.new_id(),
      "owner",
      Some("child"),
      "child",
      mail.Answer(False),
      "I promised to send CHILD-PROMISE tomorrow.",
    )
  // Provenance lookup does not change actual inbox/delivery permission.
  store.query(db, fn(connection) {
    mail.receive(connection, "child", [report.id])
  })
  |> should.be_error
  mail.undelivered(db, report.id) |> should.be_true
  deliver(db, report, "I read the child's report.")
  mail.owes_reply(db, "child", "owner") |> should.equal(Ok(False))
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "branch", through) |> should.be_ok
  let assert Ok(branch_through) = conversation.last_seq(db, "branch")
  history.fork(db, "branch", "nested", branch_through) |> should.be_ok
  list.each(["owner", "branch", "nested"], fn(id) {
    let assert Ok([row, own]) = conversation.load_sources(db, id)
    transcript_attribution.sourced(db, [row, own])
    |> should.equal(
      Ok([
        #(row.source.seq, "agent_report:child:result"),
        #(own.source.seq, "owner_agent"),
      ]),
    )
  })
  // Chat resembling a letter never supplies sender authority or a mail ID.
  save(db, "nested", mail.text(report), "I know this is quoted chat.")
  let assert Ok(rows) = conversation.load_sources(db, "nested")
  let assert Ok(actors) = transcript_attribution.sourced(db, rows)
  list.drop(actors, 2)
  |> list.map(fn(pair) { pair.1 })
  |> should.equal(["user_assertion", "owner_agent"])
  save(db, "owner", "retained next turn", "tail")
  let owner = selected(host, "owner")
  let _ =
    prepare(host, owner, True, fn(request) {
      let assert Some(formation) = request.formation
      let assert [source, own] = formation.frame.sources
      source.actor |> should.equal("agent_report:child:result")
      source.role |> should.equal("user")
      own.actor |> should.equal("owner_agent")
      let assert Ok(actual) = loop.summarizer_request(request)
      should.be_true(list.contains(actual.input, types.User(mail.text(report))))
      should.be_true(list.contains(
        actual.input,
        types.Assistant("I read the child's report."),
      ))
      actual.tools |> should.equal([])
      Ok("I read child's CHILD-PROMISE; the promise is the child's report.")
    })
  let assert Ok([node]) = graph.frontier(db, "owner")
  let assert Some(frame) = node.frame
  let assert [source, _] = frame.sources
  source.actor |> should.equal("agent_report:child:result")
  count(db, "personality_persona") |> should.equal(1)
  composition.close(owner.composition)
  runtime.stop(host)
}
