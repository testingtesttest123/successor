//// Socket-free native tests reach immutable request, native preparation and
//// corrupted extension boundaries that live HTTP cannot deterministically
//// interrupt. Actual HTTP admission is covered in the matching E2E suite.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/extension as personality
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/tools
import albedo/harness/extensions/personality/types as p
import albedo/harness/extensions/python/kernel
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/request_context
import albedo/harness/runtime
import albedo/harness/runtime/catalog
import albedo/harness/runtime/preparation
import albedo/harness/runtime/state
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import harness/session_fixture

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

@external(erlang, "albedo_runtime_test_support", "temporary_workspace")
fn temporary_workspace() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup_workspace")
fn cleanup_workspace(path: String) -> Nil

fn installed() -> List(extension.Extension) {
  [memory.extension(), personality.extension(), rolling.extension()]
}

fn start(path: String, plugins: List(extension.Extension)) -> runtime.Runtime {
  let assert Ok(host) =
    runtime.start_with_config(path, extensions.Config(plugins, ["lcm-memory"]))
  session_fixture.initialise(host)
  host
}

fn session(
  host: runtime.Runtime,
  id: String,
  selected: List(extension.Extension),
) -> state.Session {
  state.Session(
    id,
    "/tmp",
    unused_kernel(),
    runtime.ledger(host),
    composition.compose(selected, runtime.ledger(host), id, "/tmp"),
    "stable static",
    [],
    state.Fresh,
  )
}

fn prepare(
  host: runtime.Runtime,
  session: state.Session,
) -> Result(compaction.Prepared, String) {
  runtime.prepare_view_scoped(
    host,
    session,
    "model",
    "fixture",
    None,
    session.instructions,
    fn(_) { Error("must not summarize") },
    [types.User("current turn")],
    False,
    types.any_images,
  )
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

pub fn freeform_document_roundtrips_and_refreshes_next_request_test() -> Nil {
  let host = start(":memory:", installed())
  session_fixture.create(host, "owner", "/tmp")
  let db = runtime.ledger(host)
  let content =
    "Unconventional 🔭 identity\n\n"
    <> string.repeat("é", 10_240)
    <> "\nold paragraph\n"
  let assert Ok(persona) = ledger.create(db, "Albedo", content, True, True)
  ledger.bind(db, "owner", persona.id, 0, 0, installed()) |> should.be_ok
  let session =
    session(host, "owner", [memory.extension(), personality.extension()])
  let assert Ok(first) = prepare(host, session)
  let base =
    types.Request(
      "model",
      Some("static"),
      first.inputs,
      [],
      None,
      types.defaults,
    )
  let original = request_context.assemble(base, first.request_context)
  let assert Ok(tool) =
    list.find(tools.tools(), fn(tool) { tool.definition.name == "persona_edit" })
  let context =
    extension.Context(
      db,
      "owner",
      session.kernel,
      "edit-paragraph",
      "/tmp",
      types.any_images,
    )
  extension.invoke(
    tool,
    context,
    json.to_string(
      json.object([
        #("old_string", json.string("old paragraph")),
        #("new_string", json.string("new paragraph")),
      ]),
    ),
  )
  |> should.be_ok
  request_context.assemble(base, first.request_context)
  |> should.equal(original)
  let assert Ok(next) = prepare(host, session)
  let refreshed = request_context.assemble(base, next.request_context)
  should.not_equal(refreshed, original)
  let assert [block] =
    list.flat_map(first.request_context.contributions, fn(item) {
      item.instructions
    })
  should.be_true(string.ends_with(block.content, content))
  let assert Ok(after) = ledger.capture(db, "owner")
  after.persona.document
  |> should.equal(string.replace(content, "old paragraph", "new paragraph"))
  let assert [next_block] =
    list.flat_map(next.request_context.contributions, fn(item) {
      item.instructions
    })
  should.be_true(string.ends_with(next_block.content, after.persona.document))
  first.inputs |> should.equal(next.inputs)
  count(db, "transcript") |> should.equal(0)
  composition.close(session.composition)
  runtime.stop(host)
}

pub fn fresh_binding_pin_advances_native_selection_revision_once_test() -> Nil {
  let host = start(":memory:", installed())
  session_fixture.create(host, "owner", "/tmp")
  let db = runtime.ledger(host)
  let assert Ok([before]) =
    store.read(
      db,
      "SELECT config_revision FROM sessions WHERE id='owner'",
      [],
      decode.field(0, decode.int, decode.success),
    )
  ledger.create(db, "default", "document", True, True) |> should.be_ok
  ledger.resolve_fresh_binding(db, "owner") |> should.be_ok
  let assert Ok([after]) =
    store.read(
      db,
      "SELECT config_revision FROM sessions WHERE id='owner'",
      [],
      decode.field(0, decode.int, decode.success),
    )
  after |> should.equal(before + 1)
  ledger.resolve_fresh_binding(db, "owner") |> should.be_ok
  let assert Ok([unchanged]) =
    store.read(
      db,
      "SELECT config_revision FROM sessions WHERE id='owner'",
      [],
      decode.field(0, decode.int, decode.success),
    )
  unchanged |> should.equal(after)
  runtime.stop(host)
}

pub fn explicit_competing_strategy_binding_refuses_before_writing_test() -> Nil {
  let host = start(":memory:", installed())
  session_fixture.create(host, "owner", "/tmp")
  let db = runtime.ledger(host)
  let assert Ok(persona) = ledger.create(db, "default", "document", True, True)
  let change = selection.SetSession("rolling", True)
  let assert Ok(previous) =
    selection.enabled(db, installed(), ["lcm-memory"], "owner")
  let assert Ok(selected) =
    selection.propose(db, installed(), ["lcm-memory"], "owner", change)
  selection.record_selected(
    db,
    "owner",
    change,
    previous,
    selected,
    installed(),
  )
  |> should.be_ok
  let assert Ok(before) = selection.overrides(db, "owner")
  ledger.bind(db, "owner", persona.id, 0, 0, installed())
  |> should.equal(Error(p.Conflict("compaction_selection_conflict")))
  selection.overrides(db, "owner") |> should.equal(Ok(before))
  count(db, "personality_session") |> should.equal(0)
  count(db, "personality_binding_revision") |> should.equal(0)
  selection.enabled(db, installed(), ["lcm-memory"], "owner")
  |> should.equal(Ok(selected))
  runtime.stop(host)
}

pub fn setup_checks_original_quarantined_strategy_before_creating_test() -> Nil {
  let custom =
    extension.Extension(
      ..rolling.extension(),
      name: "custom-compactor",
      initialise: fn(_) { Error("cannot initialise") },
    )
  let host = start(":memory:", [custom, ..installed()])
  session_fixture.create(host, "owner", "/tmp")
  let db = runtime.ledger(host)
  store.write(
    db,
    "INSERT INTO session_extensions VALUES('owner','custom-compactor',1)",
    [],
  )
  |> should.be_ok
  let assert Ok(before) = selection.overrides(db, "owner")
  ledger.setup(
    db,
    "owner",
    "default",
    "document",
    True,
    "setup",
    runtime.declarations(host),
  )
  |> should.equal(Error(p.Conflict("compaction_selection_conflict")))
  count(db, "personality_persona") |> should.equal(0)
  count(db, "personality_default") |> should.equal(0)
  count(db, "personality_session") |> should.equal(0)
  count(db, "personality_setup_receipt") |> should.equal(0)
  selection.overrides(db, "owner") |> should.equal(Ok(before))
  runtime.stop(host)
}

pub fn default_reused_without_creating_identity_test() -> Nil {
  let host = start(":memory:", installed())
  let db = runtime.ledger(host)
  session_fixture.create(host, "first", "/tmp")
  session_fixture.create(host, "second", "/tmp")
  session_fixture.create(host, "historical", "/tmp")
  session_fixture.create(host, "future", "/tmp")
  let assert Ok(default) = ledger.create(db, "default", "free form", True, True)
  let inventory =
    catalog.Inventory(db, runtime.installed(host), runtime.quarantined(host), [
      "lcm-memory",
    ])
  let chosen = [memory.extension(), personality.extension()]
  // The real managed preparation resolves before any transcript write.
  let assert Ok(cached) =
    preparation.build_cached(inventory, "first", "/tmp", Some(chosen), [], [])
  composition.close(cached.composition)
  let assert Ok(first) = ledger.resolve_fresh_binding(db, "first")
  let assert Ok(second) = ledger.resolve_fresh_binding(db, "second")
  first.persona_id |> should.equal(default.id)
  second.persona_id |> should.equal(default.id)
  ledger.resolve_fresh_binding(db, "first") |> should.equal(Ok(first))
  count(db, "personality_persona") |> should.equal(1)
  let assert Ok(other) =
    ledger.create(db, "deliberate other", "different", True, False)
  ledger.select_default(db, other.id) |> should.be_ok
  ledger.resolve_fresh_binding(db, "first") |> should.equal(Ok(first))
  ledger.resolve_fresh_binding(db, "second") |> should.equal(Ok(second))
  let assert Ok(future) = ledger.resolve_fresh_binding(db, "future")
  future.persona_id |> should.equal(other.id)
  conversation.commit_from(
    db,
    "historical",
    [types.User("before attachment"), types.Assistant("another participant")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  ledger.resolve_fresh_binding(db, "historical")
  |> should.equal(
    Error(p.Conflict("existing transcript requires explicit attachment")),
  )
  let assert Ok(through) = conversation.last_seq(db, "historical")
  ledger.bind(db, "historical", default.id, 0, 0, installed())
  |> should.equal(Error(p.Conflict("history_changed")))
  let assert Ok(bound) =
    ledger.bind(db, "historical", default.id, 0, through, installed())
  bound.pre_binding_through |> should.equal(through)
  count(db, "transcript") |> should.equal(2)
  // The actual native strategy-change transaction suspends and later resumes
  // the same binding, without consulting identity tables while suspended.
  let assert Ok(previous) =
    selection.enabled(db, installed(), ["lcm-memory"], "first")
  let change = selection.SetSession("rolling", True)
  let assert Ok(suspended) =
    selection.propose(db, installed(), ["lcm-memory"], "first", change)
  selection.record_selected(
    db,
    "first",
    change,
    previous,
    suspended,
    installed(),
  )
  |> should.be_ok
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "ALTER TABLE personality_revision RENAME TO paused_revision",
    ))
  let paused = session(host, "first", suspended)
  prepare(host, paused) |> should.be_ok
  composition.close(paused.composition)
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "ALTER TABLE paused_revision RENAME TO personality_revision",
    ))
  let resume = selection.SetSession("personality", True)
  let assert Ok(resumed) =
    selection.propose(db, installed(), ["lcm-memory"], "first", resume)
  selection.record_selected(
    db,
    "first",
    resume,
    suspended,
    resumed,
    installed(),
  )
  |> should.be_ok
  let assert Ok(still_bound) = ledger.capture(db, "first")
  still_bound.binding |> should.equal(first)
  let context =
    extension.Context(
      db,
      "first",
      unused_kernel(),
      "spoof",
      "/tmp",
      types.any_images,
    )
  let assert Ok(write) =
    list.find(tools.tools(), fn(tool) {
      tool.definition.name == "persona_write"
    })
  let assert Ok(refused) =
    extension.invoke(
      write,
      context,
      "{\"content\":\"spoofed\",\"persona_id\":\"different\",\"actor\":\"user\"}",
    )
  let assert Ok(error) =
    json.parse(
      refused.text,
      decode.field("error", decode.string, decode.success),
    )
  error |> should.equal("invalid")
  tools.tools()
  |> list.map(fn(item) { item.definition.name })
  |> should.equal(["persona_read", "persona_write", "persona_edit"])
  count(db, "personality_persona") |> should.equal(2)
  runtime.stop(host)
}

pub fn unselected_survives_personality_failure_test() -> Nil {
  let home = temporary_workspace()
  let path = home <> "/legacy.sqlite"
  let host = start(path, [])
  session_fixture.create(host, "ordinary", "/tmp")
  session_fixture.create(host, "selected", "/tmp")
  let db = runtime.ledger(host)
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "CREATE TABLE personality_persona(id TEXT); INSERT INTO personality_persona VALUES('preserved legacy identity'); CREATE TABLE session_requirements(session TEXT,capability TEXT); INSERT INTO session_requirements VALUES('ordinary','personality'); DROP TABLE session_requirements; INSERT INTO session_extensions VALUES('selected','personality',1);",
    ))
  runtime.stop(host)
  list.each([1, 2], fn(_) {
    let host = start(path, installed())
    let db = runtime.ledger(host)
    let ordinary = session(host, "ordinary", [])
    prepare(host, ordinary) |> should.be_ok
    let selected = session(host, "selected", [])
    let assert Error(error) = prepare(host, selected)
    should.be_true(string.contains(error, "personality"))
    let assert Ok([row]) =
      store.read(
        db,
        "SELECT id FROM personality_persona",
        [],
        decode.field(0, decode.string, decode.success),
      )
    row |> should.equal("preserved legacy identity")
    let assert Ok(tables) =
      store.read(
        db,
        "SELECT name FROM sqlite_master WHERE name LIKE 'personality_%'",
        [],
        decode.field(0, decode.string, decode.success),
      )
    tables |> should.equal(["personality_persona"])
    composition.close(ordinary.composition)
    composition.close(selected.composition)
    runtime.stop(host)
  })
  cleanup_workspace(home)
}

pub fn damaged_selected_storage_fails_after_reconstruction_without_repair_test() -> Nil {
  let home = temporary_workspace()
  let path = home <> "/damaged.sqlite"
  let host = start(path, installed())
  let db = runtime.ledger(host)
  session_fixture.create(host, "owner", "/tmp")
  session_fixture.create(host, "ordinary", "/tmp")
  let assert Ok(persona) =
    ledger.create(db, "identity", "preserved", True, True)
  ledger.bind(db, "owner", persona.id, 0, 0, installed()) |> should.be_ok
  let selected =
    session(host, "owner", [memory.extension(), personality.extension()])
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "ALTER TABLE personality_revision RENAME TO preserved_revision",
    ))
  prepare(host, selected) |> should.be_error
  let ordinary = session(host, "ordinary", [])
  prepare(host, ordinary) |> should.be_ok
  composition.close(selected.composition)
  composition.close(ordinary.composition)
  runtime.stop(host)
  let host = start(path, installed())
  let db = runtime.ledger(host)
  let ordinary = session(host, "ordinary", [])
  prepare(host, ordinary) |> should.be_ok
  let selected = session(host, "owner", [])
  prepare(host, selected) |> should.be_error
  count(db, "preserved_revision") |> should.equal(1)
  let assert Ok([]) =
    store.read(
      db,
      "SELECT name FROM sqlite_master WHERE name='personality_revision'",
      [],
      decode.dynamic,
    )
  composition.close(selected.composition)
  composition.close(ordinary.composition)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn projection_truncates_whole_utf8_and_pinned_paging_retains_omitted_text_test() -> Nil {
  let host = start(":memory:", installed())
  session_fixture.create(host, "owner", "/tmp")
  let db = runtime.ledger(host)
  let content = string.repeat("a", 32_767) <> "𐍈" <> string.repeat("é", 1000)
  ledger.setup(db, "owner", "identity", content, True, "setup", installed())
  |> should.be_ok
  let selected =
    session(host, "owner", [memory.extension(), personality.extension()])
  let assert Ok(prepared) = prepare(host, selected)
  let assert [contribution] = prepared.request_context.contributions
  let assert [block] = contribution.instructions
  should.be_false(string.contains(block.content, "𐍈"))
  should.be_true(string.contains(block.content, "truncated"))
  let assert Ok(page) =
    ledger.read_document(db, "owner", None, 0, domain.read_limit)
  string.byte_size(page.text) |> should.equal(32_767)
  page.next_offset |> should.equal(Some(32_767))
  ledger.write_document(db, "owner", p.OwnerAgent("later"), "new", None)
  |> should.be_ok
  let assert Ok(rest) =
    ledger.read_document(db, "owner", Some(page.revision), 32_767, 32_768)
  { page.text <> rest.text } |> should.equal(content)
  ledger.read_document(db, "owner", Some(page.revision), 32_768, 32_768)
  |> should.be_error
  count(db, "transcript") |> should.equal(0)
  composition.close(selected.composition)
  runtime.stop(host)
}

pub fn sub_codepoint_page_limit_refuses_instead_of_repeating_offset_test() -> Nil {
  domain.page("𐍈", 1, 0, 1) |> should.be_error
  Nil
}

pub fn setup_retry_keeps_original_receipt_after_document_edit_test() -> Nil {
  let host = start(":memory:", installed())
  let db = runtime.ledger(host)
  session_fixture.create(host, "owner", "/tmp")
  let assert Ok(created) =
    ledger.setup(
      db,
      "owner",
      "identity",
      "initial",
      True,
      "same-key",
      installed(),
    )
  ledger.write_document(db, "owner", p.OwnerAgent("later"), "changed", None)
  |> should.be_ok
  ledger.setup(
    db,
    "owner",
    "identity",
    "initial",
    True,
    "same-key",
    installed(),
  )
  |> should.equal(Ok(created))
  let assert Ok(current) = ledger.capture(db, "owner")
  current.persona.document |> should.equal("changed")
  runtime.stop(host)
}

pub fn live_compatible_view_cannot_replace_authenticated_identity_storage_test() -> Nil {
  let host = start(":memory:", installed())
  let db = runtime.ledger(host)
  session_fixture.create(host, "owner", "/tmp")
  ledger.setup(
    db,
    "owner",
    "identity",
    "retained document",
    True,
    "setup",
    installed(),
  )
  |> should.be_ok
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "ALTER TABLE personality_revision RENAME TO retained_revision; CREATE VIEW personality_revision AS SELECT * FROM retained_revision",
    ))
  ledger.capture(db, "owner") |> should.be_error
  let assert Ok([1]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM retained_revision",
      [],
      decode.field(0, decode.int, decode.success),
    )
  runtime.stop(host)
}

pub fn personality_bundle_cleanup_removes_native_graph_but_retains_identity_receipts_test() -> Nil {
  let host = start(":memory:", [memory.extension(), personality.extension()])
  let db = runtime.ledger(host)
  session_fixture.create(host, "owner", "/tmp")
  ledger.setup(db, "owner", "identity", "living", True, "setup", installed())
  |> should.be_ok
  ledger.write_document(db, "owner", p.OwnerAgent("edit"), "updated", None)
  |> should.be_ok
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "INSERT INTO lcm_compaction_node(session,depth,first_seq,last_seq,summary) VALUES('owner',0,1,2,'derived native summary'); INSERT INTO lcm_compaction_state VALUES('owner',2);",
    ))
  let assert Ok(_) =
    store.query(db, fn(db) {
      store.transaction(db, fn() {
        use _ <- result.try(
          list.try_each(runtime.cleaners(host), fn(clean) { clean(db, "owner") }),
        )
        store.run(db, "DELETE FROM sessions WHERE id='owner'", [])
      })
    })
  count(db, "lcm_compaction_node") |> should.equal(0)
  count(db, "personality_persona") |> should.equal(1)
  count(db, "personality_revision") |> should.equal(2)
  count(db, "personality_tool_receipt") |> should.equal(1)
  runtime.stop(host)
}
