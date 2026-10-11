//// Receipt CAS and graph metadata are durable cross-record invariants.
//// Exact transaction generations and metadata-only SQL reads cannot be isolated by HTTP.

import albedo/context_cost
import albedo/daemon/context_source
import albedo/daemon/conversation
import albedo/daemon/history
import albedo/daemon/store
import albedo/harness/extension/selection as extension_selection
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory as lcm_memory
import albedo/harness/extensions/lcm/narration
import albedo/harness/extensions/lcm/projection_state
import albedo/harness/extensions/lcm/selection_types as selection
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleeunit/should
import harness/session_fixture
import sqlight

@external(erlang, "albedo_runtime_test_support", "with_runtime")
fn with_runtime(run: fn() -> Nil) -> Dynamic

@external(erlang, "albedo_runtime_test_support", "start_with_config")
fn fixture_start(
  path: String,
  config: extensions.Config,
) -> Result(runtime.Runtime, actor.StartError)

pub fn graph_indexes_native_recall_costs_without_payload_inventory_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "graph",
        "test",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "graph",
      [types.User("source"), types.Assistant("answer"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok(_) =
    graph.save_leaves(ledger, "graph", [
      graph.Leaf(1, 2, "summary ```code```", None),
    ])
  let assert Ok([node]) = graph.frontier(ledger, "graph")
  let expected =
    context_cost.estimate_inputs(narration.render_scoped(node, "graph", None))
  let assert Ok([cost]) =
    store.read(
      ledger,
      "SELECT foreign_tokens FROM lcm_compaction_metadata WHERE node_id=?",
      [sqlight.int(node.id)],
      decode.field(0, decode.int, decode.success),
    )
  should.equal(cost, expected)
  runtime.stop(host)
}

pub fn initial_receipt_has_no_validated_selection_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  let ledger = runtime.ledger(host)
  let assert Ok([count]) =
    store.read(
      ledger,
      "SELECT COUNT(*) FROM lcm_projection_state",
      [],
      decode.field(0, decode.int, decode.success),
    )
  should.equal(count, 0)
  runtime.stop(host)
}

fn fixture() -> #(runtime.Runtime, store.Store) {
  fixture_at(":memory:")
}

fn fixture_at(path: String) -> #(runtime.Runtime, store.Store) {
  let assert Ok(host) = runtime.start(path)
  fixture_host(host)
}

fn fixture_host(host: runtime.Runtime) -> #(runtime.Runtime, store.Store) {
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "receipt",
        "test",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "receipt",
      [types.User("one"), types.Assistant("answer"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok(_) =
    graph.save_leaves(ledger, "receipt", [graph.Leaf(1, 2, "memory", None)])
  #(host, ledger)
}

fn raw_fork_fixture() -> runtime.Runtime {
  let assert Ok(host) = fixture_start(":memory:", extensions.Config([], []))
  session_fixture.initialise(host)
  session_fixture.create(host, "raw-source", "/tmp")
  conversation.commit(
    runtime.ledger(host),
    "raw-source",
    [types.User("one"), types.Assistant("answer"), types.User("tail")],
    conversation.Idle,
  )
  |> should.be_ok
  host
}

pub fn fork_without_optional_lcm_storage_copies_raw_prefix_test_() -> Dynamic {
  with_runtime(fn() {
    let host = raw_fork_fixture()
    let ledger = runtime.ledger(host)
    let tables = fn() {
      store.read(
        ledger,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE 'lcm_%'",
        [],
        decode.field(0, decode.int, decode.success),
      )
    }
    tables() |> should.equal(Ok([0]))
    history.fork(ledger, "raw-source", "raw-branch", 2) |> should.be_ok
    conversation.load(ledger, "raw-branch")
    |> should.equal(Ok([types.User("one"), types.Assistant("answer")]))
    conversation.load(ledger, "raw-source")
    |> should.equal(
      Ok([types.User("one"), types.Assistant("answer"), types.User("tail")]),
    )
    // Ordinary forks must not install an optional extension as a side effect.
    tables() |> should.equal(Ok([0]))
  })
}

pub fn fork_with_disabled_lcm_remaps_populated_projection_test_() -> Dynamic {
  with_runtime(fn() {
    let installed = [lcm.extension(), lcm_memory.extension()]
    let assert Ok(started) =
      fixture_start(":memory:", extensions.Config(installed, []))
    session_fixture.initialise(started)
    let #(_host, ledger) = fixture_host(started)
    extension_selection.enabled(ledger, installed, [], "receipt")
    |> should.equal(Ok([]))
    let before = capture(ledger)
    let selected = folded(before)
    projection_state.commit(
      ledger,
      "receipt",
      before.expected,
      selected,
      graph.unguarded,
    )
    |> should.equal(Ok(True))
    history.fork(ledger, "receipt", "disabled-branch", 3) |> should.be_ok
    let assert Ok(branch) =
      graph.capture_inventory(ledger, "disabled-branch", profile())
    let assert [node] = branch.inventory.nodes
    let assert [_, tail] = branch.inventory.units
    branch.previous.source |> should.equal(Some(branch.inventory.source))
    branch.inventory.source.session |> should.equal("disabled-branch")
    branch.previous.generation |> should.equal(1)
    branch.previous.refs
    |> should.equal([
      selection.Recall(node.id, node.cost_key),
      selection.Raw(tail.first_seq, tail.cost_key),
    ])
    branch.previous.refs |> should.not_equal(selection.references(selected))
    should.be_true(tail.first_seq > 3)
    capture(ledger).previous.refs
    |> should.equal(selection.references(selected))
    extension_selection.enabled(ledger, installed, [], "disabled-branch")
    |> should.equal(Ok([]))
    Nil
  })
}

pub fn fork_rejects_damaged_installed_projection_storage_atomically_test_() -> Dynamic {
  with_runtime(fn() {
    let host = raw_fork_fixture()
    let ledger = runtime.ledger(host)
    store.write(ledger, "CREATE TABLE lcm_projection_state(session TEXT)", [])
    |> should.be_ok
    history.fork(ledger, "raw-source", "broken-branch", 2) |> should.be_error
    conversation.get(ledger, "broken-branch") |> should.be_error
    store.read(
      ledger,
      "SELECT COUNT(*) FROM transcript WHERE session='broken-branch'",
      [],
      decode.field(0, decode.int, decode.success),
    )
    |> should.equal(Ok([0]))
  })
}

fn profile() -> context_cost.CostProfile {
  context_cost.CostProfile(
    "provider",
    types.Responses,
    "model",
    types.any_images,
    None,
    "identity",
  )
}

fn capture(ledger: store.Store) -> selection.ProjectionCapture {
  let assert Ok(captured) =
    graph.capture_inventory(ledger, "receipt", profile())
  captured
}

fn folded(
  capture: selection.ProjectionCapture,
) -> selection.ValidatedSelection {
  let assert [node] = capture.inventory.nodes
  let assert [_, tail] = capture.inventory.units
  let assert Ok(validated) =
    selection.validate(capture, [
      selection.Recall(node.id, node.cost_key),
      selection.Raw(tail.first_seq, tail.cost_key),
    ])
  validated
}

pub fn receipt_cas_rejects_stale_generations_and_owner_guard_test() -> Nil {
  let #(host, ledger) = fixture()
  let first = capture(ledger)
  let validated = folded(first)
  projection_state.commit(ledger, "receipt", first.expected, validated, fn(_) {
    Ok(False)
  })
  |> should.equal(Ok(False))
  projection_state.commit(ledger, "receipt", first.expected, validated, fn(_) {
    Error("owner changed")
  })
  |> should.equal(Error("owner changed"))
  should.equal(capture(ledger).previous.generation, 0)
  projection_state.commit(
    ledger,
    "receipt",
    first.expected,
    validated,
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  projection_state.commit(
    ledger,
    "receipt",
    first.expected,
    validated,
    graph.unguarded,
  )
  |> should.equal(Ok(False))
  let saved = capture(ledger)
  should.equal(saved.previous.generation, 1)
  should.equal(saved.previous.refs, selection.references(validated))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "receipt",
      [types.User("new tail")],
      conversation.Idle,
    )
  projection_state.commit(
    ledger,
    "receipt",
    saved.expected,
    folded(saved),
    graph.unguarded,
  )
  |> should.equal(Ok(False))
  let after = capture(ledger)
  should.equal(after.previous.refs, saved.previous.refs)
  should.be_true(
    after.expected.source.revision > saved.expected.source.revision,
  )
  runtime.stop(host)
}

pub fn receipt_rejects_forged_foreign_and_partial_inventory_test() -> Nil {
  let #(host, ledger) = fixture()
  let captured = capture(ledger)
  let validated = folded(captured)
  projection_state.commit(
    ledger,
    "other",
    captured.expected,
    validated,
    graph.unguarded,
  )
  |> should.be_error
  let assert [first, _] = captured.inventory.units
  let forged =
    selection.ProjectionCapture(
      ..captured,
      inventory: selection.ArchiveInventory(
        ..captured.inventory,
        units: [first],
        nodes: [],
      ),
    )
  let assert Ok(partial) =
    selection.validate(forged, [selection.Raw(first.first_seq, first.cost_key)])
  projection_state.commit(
    ledger,
    "receipt",
    captured.expected,
    partial,
    graph.unguarded,
  )
  |> should.equal(Ok(False))
  let assert [node] = captured.inventory.nodes
  selection.validate(captured, [
    selection.Recall(
      node.id,
      context_cost.CostEntryKey("foreign", node.content_identity, 0),
    ),
  ])
  |> should.be_error
  should.equal(capture(ledger).previous.generation, 0)
  runtime.stop(host)
}

pub fn same_max_rewrite_and_graph_changes_invalidate_receipts_test() -> Nil {
  let #(host, ledger) = fixture()
  let before = capture(ledger)
  projection_state.commit(
    ledger,
    "receipt",
    before.expected,
    folded(before),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let before = capture(ledger)
  let assert Ok(_) =
    store.write(
      ledger,
      "UPDATE transcript SET payload=? WHERE session='receipt' AND seq=1",
      [sqlight.blob(pack(types.User("changed")))],
    )
  projection_state.commit(
    ledger,
    "receipt",
    before.expected,
    folded(before),
    graph.unguarded,
  )
  |> should.equal(Ok(False))
  let assert Ok(_) =
    store.query(ledger, context_source.reindex_in(_, "receipt"))
  let changed = capture(ledger)
  should.equal(
    changed.expected.source.transcript_upper,
    before.expected.source.transcript_upper,
  )
  should.equal(changed.previous.generation, 1)
  should.equal(changed.previous.refs, [])
  let assert Ok(_) =
    store.write(
      ledger,
      "UPDATE lcm_compaction_node SET summary='replacement' WHERE session='receipt'",
      [],
    )
  projection_state.commit(
    ledger,
    "receipt",
    changed.expected,
    folded(changed),
    graph.unguarded,
  )
  |> should.equal(Ok(False))
  let assert Ok(_) = graph.initialise(ledger)
  let indexed = capture(ledger)
  should.be_true(
    indexed.expected.graph_revision > changed.expected.graph_revision,
  )
  runtime.stop(host)
}

pub fn receipt_survives_reinitialisation_but_rejects_unknown_version_test() -> Nil {
  let path = temporary_database()
  let #(host, ledger) = fixture_at(path)
  let before = capture(ledger)
  projection_state.commit(
    ledger,
    "receipt",
    before.expected,
    folded(before),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  runtime.stop(host)
  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = graph.initialise(ledger)
  should.equal(
    capture(ledger).previous.refs,
    selection.references(folded(before)),
  )
  let assert Ok(_) =
    store.write(
      ledger,
      "UPDATE lcm_projection_state SET version=99 WHERE session='receipt'",
      [],
    )
  let rejected = capture(ledger)
  should.equal(rejected.previous.generation, 1)
  should.equal(rejected.previous.refs, [])
  should.equal(
    rejected.previous.diagnostic,
    Some("unsupported receipt version"),
  )
  runtime.stop(restarted)
  cleanup_database(path)
}

pub fn fork_remaps_surviving_recall_and_resets_crossing_selection_test() -> Nil {
  let #(host, ledger) = fixture()
  let before = capture(ledger)
  projection_state.commit(
    ledger,
    "receipt",
    before.expected,
    folded(before),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert Ok(_) = history.fork(ledger, "receipt", "branch", 3)
  let assert Ok(branch) = graph.capture_inventory(ledger, "branch", profile())
  let assert [node] = branch.inventory.nodes
  let assert [_, tail] = branch.inventory.units
  should.equal(branch.previous.refs, [
    selection.Recall(node.id, node.cost_key),
    selection.Raw(tail.first_seq, tail.cost_key),
  ])
  should.not_equal(branch.previous.refs, before.previous.refs)
  let assert Ok(_) = history.fork(ledger, "receipt", "crossing", 1)
  let assert Ok(crossing) =
    graph.capture_inventory(ledger, "crossing", profile())
  should.equal(crossing.previous.refs, [])
  runtime.stop(host)
}

pub fn inventory_capture_is_coherent_test() -> Nil {
  let #(host, ledger) = fixture()
  let before = capture(ledger)
  let entered = process.new_subject()
  let completed = process.new_subject()
  let _ =
    process.spawn(fn() {
      let result =
        store.query(ledger, fn(db) {
          let release = process.new_subject()
          process.send(entered, release)
          let _ = process.receive_forever(release)
          graph.capture_inventory_in(db, "receipt", profile())
        })
      process.send(completed, result)
    })
  let release = process.receive_forever(entered)
  let writer_started = process.new_subject()
  let writer_done = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(writer_started, Nil)
      let result =
        store.query(ledger, fn(db) {
          store.transaction(db, fn() {
            let input = types.User("later")
            use _ <- result.try(
              store.run(
                db,
                "INSERT INTO transcript(session,payload,row_class) VALUES('receipt',?,'user')",
                [sqlight.blob(pack(input))],
              ),
            )
            use seq <- result.try(store.one(
              db,
              "SELECT last_insert_rowid()",
              [],
              decode.field(0, decode.int, decode.success),
              "new source missing",
            ))
            use _ <- result.try(conversation.index_entry_in(
              db,
              "receipt",
              seq,
              input,
            ))
            use _ <- result.try(
              store.run(
                db,
                "UPDATE sessions SET config_revision=config_revision+1 WHERE id='receipt'",
                [],
              ),
            )
            use _ <- result.try(
              store.run(
                db,
                "UPDATE lcm_compaction_node SET formation_id=formation_id+1 WHERE session='receipt'",
                [],
              ),
            )
            store.run(
              db,
              "INSERT INTO lcm_projection_state(session,generation,version,scope,profile,refs,salience) VALUES('receipt',1,99,'{}','{}','[]',1)",
              [],
            )
          })
        })
      process.send(writer_done, result)
    })
  let _ = process.receive_forever(writer_started)
  process.send(release, Nil)
  let assert Ok(captured) = process.receive_forever(completed)
  should.equal(captured.expected, before.expected)
  let assert Ok(_) = process.receive_forever(writer_done)
  let assert Ok(_) = graph.initialise(ledger)
  let after = capture(ledger)
  should.be_true(
    after.expected.source.revision > captured.expected.source.revision,
  )
  should.be_true(
    after.expected.graph_revision > captured.expected.graph_revision,
  )
  should.be_true(
    after.expected.source.configuration_revision
    > captured.expected.source.configuration_revision,
  )
  should.equal(after.expected.receipt_generation, 1)
  runtime.stop(host)
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup_database(path: String) -> Nil

pub fn restart_rejects_receipt_when_selected_parent_loses_actual_child_coverage_test() -> Nil {
  let #(host, ledger) = fixture()
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "receipt",
      [types.User("new tail")],
      conversation.Idle,
    )
  let assert Ok(_) =
    graph.save_leaves(ledger, "receipt", [graph.Leaf(3, 3, "second", None)])
  let assert Ok(children) = graph.frontier(ledger, "receipt")
  let assert Ok(_) = graph.save_parent(ledger, "receipt", children, "parent")
  let before = capture(ledger)
  let assert Ok(parent) =
    list.find(before.inventory.nodes, fn(n) { n.depth == 1 })
  let assert Ok(tail) = list.last(before.inventory.units)
  let assert Ok(validated) =
    selection.validate(before, [
      selection.Recall(parent.id, parent.cost_key),
      selection.Raw(tail.first_seq, tail.cost_key),
    ])
  projection_state.commit(
    ledger,
    "receipt",
    before.expected,
    validated,
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert [child, ..] = children
  let assert Ok(_) =
    store.write(ledger, "DELETE FROM lcm_compaction_edge WHERE child=?", [
      sqlight.int(child.id),
    ])
  let after = capture(ledger)
  should.equal(after.previous.refs, [])
  should.equal(after.previous.generation, 1)
  runtime.stop(host)
}
