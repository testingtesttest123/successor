//// Native role/source/graph regressions use the real store and request path.
//// AF_UNIX is denied in the correction executor; only the external summary
//// model is deterministic. No kernel or provider success is implied.

import albedo/daemon/conversation
import albedo/daemon/history
import albedo/daemon/session_submission
import albedo/daemon/store
import albedo/daemon/turn
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/extensions/agents/extension as agents
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/formation
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/lcm/narration
import albedo/harness/extensions/lcm/narration_types as n
import albedo/harness/extensions/lcm/tools as lcm_tools
import albedo/harness/extensions/mail/extension as mail
import albedo/harness/extensions/personality/episodes
import albedo/harness/extensions/personality/extension as personality
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/types as p
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/python/kernel
import albedo/harness/extensions/python/link
import albedo/harness/loop
import albedo/harness/request_context
import albedo/harness/runtime
import albedo/harness/runtime/kernels
import albedo/harness/runtime/state
import albedo/openai_api/request as provider_request
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/string_tree
import gleeunit/should
import harness/session_fixture
import sqlight

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

fn setup() -> #(runtime.Runtime, state.Session, p.Persona) {
  setup_bound(True)
}

fn setup_bound(bind: Bool) -> #(runtime.Runtime, state.Session, p.Persona) {
  setup_at(":memory:", bind)
}

fn setup_at(
  path: String,
  bind: Bool,
) -> #(runtime.Runtime, state.Session, p.Persona) {
  let assert Some(configured) =
    extension.compaction([
      lcm.configured_extension(lcm.Config(Some(20_000), 80, 25)),
    ])
  let bundle = personality.extension()
  let bundle =
    extension.Extension(
      ..bundle,
      plugins: list.map(bundle.plugins, fn(plugin) {
        case plugin {
          extension.CompactionPlugin(_) ->
            extension.CompactionPlugin(
              compaction.Strategy("personality", fn(catalog, reader) {
                use resolved <- result.try(configured.resolve(catalog, reader))
                lcm.strategy("personality").resolve(resolved.capacity, reader)
              }),
            )
          _ -> plugin
        }
      }),
    )
  let installed = [bundle, memory.extension()]
  let assert Ok(host) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(host)
  session_fixture.create(host, "owner", "/tmp")
  let assert Ok(persona) =
    ledger.create(runtime.ledger(host), "Ash", "Living identity", True, bind)
  case bind {
    True -> {
      ledger.bind(
        runtime.ledger(host),
        "owner",
        persona.id,
        0,
        0,
        runtime.installed(host),
      )
      |> should.be_ok
      Nil
    }
    False -> Nil
  }
  let session =
    state.Session(
      "owner",
      "/tmp",
      unused_kernel(),
      runtime.ledger(host),
      composition.compose(installed, runtime.ledger(host), "owner", "/tmp"),
      "static",
      [],
      state.Fresh,
    )
  #(host, session, persona)
}

fn save(host: runtime.Runtime, text: String, answer: String) -> Nil {
  let submission = turn.Submission(text, text, "", turn.Chat, [], None, None)
  conversation.commit_operations(
    runtime.ledger(host),
    "owner",
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

fn prepare(
  host: runtime.Runtime,
  session: state.Session,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
) -> compaction.Prepared {
  let assert Ok(rows) = conversation.load_sources(runtime.ledger(host), "owner")
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
      True,
      types.any_images,
    )
  prepared
}

pub fn own_memory_is_assistant_recall_test() -> Nil {
  let #(host, session, _) = setup()
  save(
    host,
    "Check ATLAS-17. Corrected path /tmp/new. REVIEW-OPEN remains.",
    "I checked ATLAS-17",
  )
  save(host, "latest retained unit", "tail action")
  let assert Ok(before) =
    conversation.load_sources(runtime.ledger(host), "owner")
  let prepared =
    prepare(host, session, fn(request) {
      let assert Ok(actual) = loop.summarizer_request(request)
      // The actual authenticated assistant source must stay an Assistant input.
      should.be_true(
        list.any(actual.input, fn(input) {
          case input {
            types.Assistant("I checked ATLAS-17") -> True
            _ -> False
          }
        }),
      )
      Ok("I checked ATLAS-17; corrected path /tmp/new; REVIEW-OPEN remains.")
    })
  should.be_true(
    list.any(prepared.inputs, fn(input) {
      case input {
        types.Assistant(text) -> string.contains(text, "REVIEW-OPEN")
        _ -> False
      }
    }),
  )
  conversation.load_sources(runtime.ledger(host), "owner")
  |> should.equal(Ok(before))
  let assert Ok([node]) = graph.frontier(runtime.ledger(host), "owner")
  should.be_true(string.contains(node.summary, "REVIEW-OPEN"))
  composition.close(session.composition)
  runtime.stop(host)
}

fn prepared_result(
  host: runtime.Runtime,
  session: state.Session,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  force: Bool,
) -> Result(compaction.Prepared, String) {
  use rows <- result.try(conversation.load_sources(
    runtime.ledger(host),
    session.id,
  ))
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
}

fn cleanup(host: runtime.Runtime, session: state.Session) -> Nil {
  composition.close(session.composition)
  runtime.stop(host)
}

fn contents(inputs: List(types.Input)) -> String {
  inputs
  |> list.map(fn(input) {
    case narration.text_input(input) {
      types.User(text) | types.Assistant(text) -> text
      _ -> ""
    }
  })
  |> string.join("\n")
}

fn facts(text: String) -> String {
  ["FIRST-ASH-ORBIT", "MIDDLE-ASH-QUAY", "LAST-ASH-LARCH"]
  |> list.filter(string.contains(text, _))
  |> string.join("; ")
}

pub fn long_first_person_document_uses_reader_chunks_test() -> Nil {
  let #(host, session, _) = setup()
  let document =
    "I, the author Ash, did FIRST-ASH-ORBIT. "
    <> string.repeat("é🧭é background ", 5000)
    <> " MIDDLE-ASH-QUAY "
    <> string.repeat("é🧭é background ", 5000)
    <> " I did LAST-ASH-LARCH."
  save(host, document, "I received Ash's account and will check its sources.")
  save(host, "latest unit", "retained")
  let db = runtime.ledger(host)
  let assert Ok(before) = conversation.load_sources(db, "owner")
  let assert [source, ..] = before
  let fail_seen = process.new_subject()
  process.send(fail_seen, 0)
  let failed =
    prepared_result(
      host,
      session,
      fn(request) {
        let assert Some(formation) = request.formation
        let assert Ok(count) = process.receive(fail_seen, 0)
        process.send(fail_seen, count + 1)
        case formation.mode == "reading" && count == 1 {
          True -> Error("middle reading failed")
          False -> Ok("I read this portion of Ash's account.")
        }
      },
      True,
    )
  failed |> should.equal(Error("compaction personality: middle reading failed"))
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  graph.last_seq(db, "owner") |> should.equal(Ok(0))
  let final_failure =
    prepared_result(
      host,
      session,
      fn(request) {
        let assert Some(formation) = request.formation
        case formation.mode {
          "consolidation" -> Error("whole reading fold failed")
          _ ->
            Ok(
              "I read "
              <> facts(contents(request.evicted))
              <> " from Ash's account.",
            )
        }
      },
      True,
    )
  final_failure
  |> should.equal(Error("compaction personality: whole reading fold failed"))
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  graph.last_seq(db, "owner") |> should.equal(Ok(0))
  let calls = process.new_subject()
  process.send(calls, [])
  let assert Ok(prepared) =
    prepared_result(
      host,
      session,
      fn(request) {
        let assert Some(formation) = request.formation
        let assert Ok(actual) = loop.summarizer_request(request)
        actual.tools |> should.equal([])
        let estimate =
          compaction.estimate_pinned(option.unwrap(actual.instructions, ""), [])
          + compaction.estimate_inputs(actual.input)
          + request.max_output_tokens
        should.be_true(estimate <= formation.budget)
        let assert Ok(seen) = process.receive(calls, 0)
        process.send(calls, [request, ..seen])
        Ok(
          "I read " <> facts(contents(request.evicted)) <> " in Ash's account.",
        )
      },
      True,
    )
  let assert Ok(calls) = process.receive(calls, 100)
  let calls = list.reverse(calls)
  let readings =
    list.filter(calls, fn(request) {
      case request.formation {
        Some(value) -> value.mode == "reading"
        _ -> False
      }
    })
  should.be_true(list.length(readings) > 3)
  let doc_calls =
    list.filter(readings, fn(request) {
      case request.formation {
        Some(n.Formation(portions: [portion], ..)) ->
          portion.seq == source.source.seq
        _ -> False
      }
    })
  let reconstructed =
    list.map(doc_calls, fn(request) { contents(request.evicted) })
    |> string.concat
  reconstructed |> should.equal(document)
  let _ =
    list.fold(doc_calls, 0, fn(after, request) {
      let assert Some(n.Formation(portions: [portion], ..)) = request.formation
      portion.start |> should.equal(after)
      portion.end - portion.start
      |> should.equal(string.byte_size(contents(request.evicted)))
      portion.total |> should.equal(string.byte_size(document))
      portion.session |> should.equal("owner")
      portion.end
    })
    |> should.equal(string.byte_size(document))
  list.each(list.drop(readings, 1), fn(request) {
    let assert Some(n.Formation(previous: Some(previous), ..)) =
      request.formation
    let assert Ok(actual) = loop.summarizer_request(request)
    should.be_true(list.contains(actual.input, types.Assistant(previous.text)))
  })
  let assert Ok(final) = list.last(calls)
  let assert Some(n.Formation(mode: "consolidation", source_only: True, ..)) =
    final.formation
  facts(contents(final.evicted))
  |> should.equal("FIRST-ASH-ORBIT; MIDDLE-ASH-QUAY; LAST-ASH-LARCH")
  let assert Ok([node]) = graph.frontier(db, "owner")
  facts(node.summary)
  |> should.equal("FIRST-ASH-ORBIT; MIDDLE-ASH-QUAY; LAST-ASH-LARCH")
  let assert Some(frame) = node.frame
  frame.perspective |> should.equal(n.Reading)
  conversation.load_sources(db, "owner") |> should.equal(Ok(before))
  should.be_true(list.contains(prepared.inputs, types.Assistant(node.summary)))
  cleanup(host, session)
}

pub fn list_page_frame_and_frontier_columns_are_independent_test() -> Nil {
  let #(host, session, persona) = setup()
  save(host, "first unit", "first action")
  save(host, "second unit", "second action")
  save(host, "third unit", "third action")
  let db = runtime.ledger(host)
  let assert Ok([a, b, c, d, e, f]) = conversation.load_sources(db, "owner")
  let frame =
    n.Frame(
      Some(n.Narrator(persona.id, persona.name, persona.identity_revision)),
      n.Witnessed,
      [],
      [],
    )
  graph.save_leaves(db, "owner", [
    graph.Leaf(a.source.seq, b.source.seq, "one", Some(frame)),
    graph.Leaf(c.source.seq, d.source.seq, "two", None),
    graph.Leaf(e.source.seq, f.source.seq, "three", Some(frame)),
  ])
  |> should.be_ok
  let assert Ok([one, two, three]) = graph.frontier(db, "owner")
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let parent_frame = narration.parent_frame([one, two], "owner")
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    [one, two],
    "parent",
    Some(parent_frame),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert Ok(graph.NodeListPage(4, [#(got_one, False), #(got_two, False)])) =
    graph.list_page(db, "owner", 2, 0)
  got_one.frame |> should.equal(Some(frame))
  got_two.frame |> should.equal(None)
  let assert Ok(graph.NodeListPage(4, [#(got_three, True), #(got_parent, True)])) =
    graph.list_page(db, "owner", 2, 2)
  got_three |> should.equal(three)
  got_parent.frame |> should.equal(Some(parent_frame))
  graph.node(db, "owner", got_one.id) |> should.equal(Ok(Some(got_one)))
  let assert Ok(graph.NodeSearchPage(1, [searched])) =
    graph.search_page(db, "owner", None, "one", 2, 0)
  searched.frame |> should.equal(Some(frame))
  cleanup(host, session)
}

pub fn concurrent_graph_commit_is_atomic_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "old", "action")
  save(host, "retained newest unit", "raw tail")
  let db = runtime.ledger(host)
  let assert Ok([first, last, _, _]) = conversation.load_sources(db, "owner")
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let results = process.new_subject()
  let ready = process.new_subject()
  list.each(list.repeat(Nil, 2), fn(_) {
    process.spawn(fn() {
      let gate = process.new_subject()
      process.send(ready, gate)
      let assert Ok(Nil) = process.receive(gate, 1000)
      process.send(
        results,
        graph.commit_leaves(
          db,
          "owner",
          snapshot,
          [graph.Leaf(first.source.seq, last.source.seq, "winner", None)],
          graph.unguarded,
        ),
      )
    })
    Nil
  })
  let assert Ok(gate_a) = process.receive(ready, 1000)
  let assert Ok(gate_b) = process.receive(ready, 1000)
  process.send(gate_a, Nil)
  process.send(gate_b, Nil)
  let assert Ok(a) = process.receive(results, 1000)
  let assert Ok(b) = process.receive(results, 1000)
  list.sort([a, b], fn(a, b) {
    case a, b {
      Ok(False), Ok(True) -> order.Lt
      Ok(True), Ok(False) -> order.Gt
      _, _ -> order.Eq
    }
  })
  |> should.equal([Ok(False), Ok(True)])
  let assert Ok([node]) = graph.frontier(db, "owner")
  graph.last_seq(db, "owner") |> should.equal(Ok(last.source.seq))
  graph.children(db, node.id) |> should.equal(Ok([]))
  let assert Ok(new_snapshot) = graph.snapshot(db, "owner")
  save(host, "new source", "later")
  graph.commit_leaves(db, "owner", new_snapshot, [], graph.unguarded)
  |> should.equal(Ok(False))
  graph.frontier(db, "owner") |> should.equal(Ok([node]))
  cleanup(host, session)
}

fn policy_for(db: store.Store, id: String) -> request_context.SummaryPolicy {
  let assert Ok(captured) = ledger.capture(db, id)
  let assert Ok(revision) =
    store.query(db, fn(connection) {
      store.one(
        connection,
        "SELECT config_revision FROM sessions WHERE id=?",
        [sqlight.text(id)],
        decode.field(0, decode.int, decode.success),
        "no config",
      )
    })
  request_context.SummaryPolicy(
    "personality-autobiographical-v1",
    "fixture",
    captured.persona.identity_revision,
    "Captured identity: " <> captured.persona.document,
    request_context.Lineage(
      captured.persona.id,
      captured.binding.generation,
      captured.binding.mode,
      captured.binding.pre_binding_through,
    ),
    captured.persona.name,
    revision,
  )
}

fn context_for(
  db: store.Store,
  id: String,
  policy: request_context.SummaryPolicy,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
) -> compaction.Context {
  compaction.Context(
    db,
    id,
    fn() { True },
    "model",
    "fixture",
    0,
    Some(compaction.Capacity(20_000, "fixture")),
    True,
    summarize,
    compaction.no_prior,
    None,
    types.any_images,
    Some(policy),
  )
}

pub fn witness_boundary_survives_mixed_consolidation_test() -> Nil {
  let path = "/tmp/stage2-mixed-" <> ledger.new_id() <> ".sqlite"
  let #(host, session, persona) = setup_at(path, False)
  let db = runtime.ledger(host)
  save(host, "Ash lived ASH-OLD before attachment.", "old participant acted")
  let assert Ok([a, b]) = conversation.load_sources(db, "owner")
  ledger.bind(db, "owner", persona.id, 0, b.source.seq, runtime.installed(host))
  |> should.be_ok
  // A different session's rows make the source IDs non-contiguous.
  session_fixture.create(host, "interleaved", "/tmp")
  conversation.commit_from(
    db,
    "interleaved",
    [types.User("gap"), types.Assistant("gap")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  save(
    host,
    "I am Ash and already did ASH-OLD. OWN-ASK remains.",
    "OWN-ACTION checked the corrected path.",
  )
  save(host, "latest retained", "tail")
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  let assert [_, _, c, d, _, _] = rows
  should.be_true(c.source.seq > b.source.seq + 1)
  let policy = policy_for(db, "owner")
  let calls = process.new_subject()
  let context =
    context_for(db, "owner", policy, fn(request) {
      process.send(calls, request)
      Ok("I carry Ash's old record and remember OWN-ACTION; OWN-ASK remains.")
    })
  let assert Ok([witness]) = formation.leaves(context, [a, b], 768, policy)
  let assert Some(witness_frame) = witness.frame
  witness_frame.perspective |> should.equal(n.Witnessed)
  let assert Ok([experience]) = formation.leaves(context, [c, d], 768, policy)
  let assert Some(experience_frame) = experience.frame
  experience_frame.perspective |> should.equal(n.Experienced)
  let assert Ok([straddled]) =
    formation.leaves(context, [a, b, c, d], 768, policy)
  let assert Some(mixed) = straddled.frame
  mixed.perspective |> should.equal(n.Mixed)
  list.map(mixed.sources, fn(source) { source.seq })
  |> should.equal([a.source.seq, b.source.seq, c.source.seq, d.source.seq])
  list.map(mixed.sources, fn(source) { source.perspective })
  |> should.equal([n.Witnessed, n.Witnessed, n.Experienced, n.Experienced])
  graph.save_leaves(db, "owner", [witness, experience]) |> should.be_ok
  let assert Ok(children) = graph.frontier(db, "owner")
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let assert Ok(#(summary, frame)) =
    formation.parent(context, children, 768, policy)
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    children,
    summary,
    frame,
    episodes.guard(policy, "owner"),
  )
  |> should.equal(Ok(True))
  let assert Ok([parent]) = graph.frontier(db, "owner")
  let assert Some(parent_frame) = parent.frame
  parent_frame.perspective |> should.equal(n.Mixed)
  list.map(parent_frame.children, fn(child) { child.id })
  |> should.equal(list.map(children, fn(child) { child.id }))
  history.fork(db, "owner", "full-fork", d.source.seq) |> should.be_ok
  let assert Ok([forked]) = graph.frontier(db, "full-fork")
  let assert Some(fork_frame) = forked.frame
  fork_frame.narrator |> should.equal(parent_frame.narrator)
  should.be_true(
    list.all(fork_frame.children, fn(child) { child.session == "full-fork" }),
  )
  let assert Ok(fork_children) = graph.children(db, forked.id)
  list.map(fork_frame.children, fn(child) { child.id })
  |> should.equal(fork_children)
  let assert Ok(Some(fork_witness)) =
    graph.node(db, "full-fork", list.first(fork_children) |> result.unwrap(0))
  let assert Some(fork_witness_frame) = fork_witness.frame
  should.be_true(
    list.all(fork_witness_frame.sources, fn(source) {
      source.session == "full-fork" && source.origin_session == "owner"
    }),
  )
  list.map(fork_witness_frame.sources, fn(source) { source.origin_seq })
  |> should.equal([a.source.seq, b.source.seq])
  let assert Ok(fork_rows) = conversation.load_sources(db, "full-fork")
  list.map(fork_witness_frame.sources, fn(source) { source.seq })
  |> should.equal(
    list.take(fork_rows, 2) |> list.map(fn(row) { row.source.seq }),
  )
  history.fork(db, "owner", "partial-fork", c.source.seq) |> should.be_ok
  let assert Ok([partial]) = graph.frontier(db, "partial-fork")
  partial.summary |> should.equal(witness.summary)
  let assert Some(partial_frame) = partial.frame
  partial_frame.perspective |> should.equal(n.Witnessed)
  let assert Ok(second) =
    ledger.create(
      db,
      "Ash",
      "Another deliberately created identity",
      True,
      False,
    )
  let assert Ok(through) = conversation.last_seq(db, "owner")
  ledger.bind(db, "owner", second.id, 1, through, runtime.installed(host))
  |> should.be_ok
  graph.frontier(db, "owner") |> should.equal(Ok([parent]))
  let rendered = narration.render_scoped(parent, "owner", Some(second.id))
  should.be_true(
    list.all(rendered, fn(input) {
      case input {
        types.User(_) -> True
        _ -> False
      }
    }),
  )
  let installed = composition.extensions(session.composition)
  cleanup(host, session)
  let assert Ok(reopened) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(reopened)
  let reopened_db = runtime.ledger(reopened)
  graph.frontier(reopened_db, "owner") |> should.equal(Ok([parent]))
  graph.frontier(reopened_db, "full-fork") |> should.equal(Ok([forked]))
  graph.frontier(reopened_db, "partial-fork") |> should.equal(Ok([partial]))
  let assert Ok(rebound) = ledger.capture(reopened_db, "owner")
  rebound.persona.id |> should.equal(second.id)
  narration.render_scoped(parent, "owner", Some(rebound.persona.id))
  |> should.equal(rendered)
  runtime.stop(reopened)
}

pub fn prior_memory_and_merge_sources_are_real_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "FIRST-DEEP-RAW ask", "first action")
  save(host, "retained second ask", "second action")
  let db = runtime.ledger(host)
  let _ = prepare(host, session, fn(_) { Ok("I recall the first event.") })
  let assert Ok([first]) = graph.frontier(db, "owner")
  save(host, "latest third ask", "tail")
  let calls = process.new_subject()
  let _ =
    prepare(host, session, fn(request) {
      process.send(calls, request)
      Ok("I recall the second event.")
    })
  let assert Ok(second_request) = process.receive(calls, 100)
  let assert Some(n.Formation(previous: Some(previous), ..)) =
    second_request.formation
  previous.text |> should.equal(first.summary)
  let assert Ok(actual) = loop.summarizer_request(second_request)
  should.be_true(list.contains(actual.input, types.Assistant(first.summary)))
  let assert Ok(children) = graph.frontier(db, "owner")
  let policy = policy_for(db, "owner")
  let context =
    context_for(db, "owner", policy, fn(request) {
      process.send(calls, request)
      Ok(
        "I reread "
        <> facts(contents(request.evicted))
        <> " and FIRST-DEEP-RAW remains in the actual source.",
      )
    })
  formation.parent(context, children, 768, policy) |> should.be_ok
  let assert Ok(merge) = process.receive(calls, 100)
  let assert Some(n.Formation(source_only: False, ..)) = merge.formation
  should.be_true(string.contains(contents(merge.evicted), "FIRST-DEEP-RAW"))
  // Force the actual raw reread above allowance while direct children fit.
  let assert Ok(all) = conversation.load_sources(db, "owner")
  let assert [a, b, c, d, _, _] = all
  conversation.commit_from(
    db,
    "owner",
    [
      types.User(string.repeat("huge deeper source ", 10_000)),
      types.Assistant("huge action"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok(all) = conversation.load_sources(db, "owner")
  let assert Ok(last) = list.last(all)
  let assert Ok(huge) = list.first(list.drop(all, list.length(all) - 2))
  graph.save_leaves(db, "owner", [
    graph.Leaf(
      huge.source.seq,
      last.source.seq,
      "I recall a short direct child.",
      first.frame,
    ),
  ])
  |> should.be_ok
  let assert Ok(frontier) = graph.frontier(db, "owner")
  let context =
    context_for(db, "owner", policy, fn(request) {
      process.send(calls, request)
      Ok("I consolidate all direct children as attributed memories.")
    })
  formation.parent(context, frontier, 768, policy) |> should.be_ok
  let assert Ok(fallback) = process.receive(calls, 100)
  let assert Some(n.Formation(source_only: True, frame: frame, ..)) =
    fallback.formation
  list.map(frame.children, fn(child) { child.id })
  |> should.equal(list.map(frontier, fn(node) { node.id }))
  list.each(frontier, fn(node) {
    should.be_true(string.contains(contents(fallback.evicted), node.summary))
  })
  // Do not accidentally consume/decode archived history on an ordinary read.
  let _ = #(a, b, c, d)
  cleanup(host, session)
}

pub fn persisted_frames_reconstruct_provider_roles_without_transcript_mutation_test() -> Nil {
  let path = "/tmp/stage2-narration-" <> ledger.new_id() <> ".sqlite"
  let #(host, session, persona) = setup_at(path, True)
  save(host, "Check ATLAS-17; REVIEW-OPEN remains.", "I corrected /tmp/new.")
  save(host, "latest retained", "tail action")
  let first =
    prepare(host, session, fn(_) {
      Ok("I checked ATLAS-17; REVIEW-OPEN remains.")
    })
  let db = runtime.ledger(host)
  let assert Ok([stored]) = graph.frontier(db, "owner")
  let assert Some(frame) = stored.frame
  frame.narrator
  |> should.equal(
    Some(n.Narrator(persona.id, persona.name, persona.identity_revision)),
  )
  frame.perspective |> should.equal(n.Experienced)
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  list.map(frame.sources, fn(source) { source.seq })
  |> should.equal(list.take(rows, 2) |> list.map(fn(row) { row.source.seq }))
  list.map(frame.sources, fn(source) { source.actor })
  |> should.equal(["user_assertion", "owner_agent"])
  let installed = composition.extensions(session.composition)
  cleanup(host, session)
  let assert Ok(reopened) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(reopened)
  let db = runtime.ledger(reopened)
  let resumed =
    state.Session(
      "owner",
      "/tmp",
      unused_kernel(),
      db,
      composition.compose(installed, db, "owner", "/tmp"),
      "static",
      [],
      state.Fresh,
    )
  graph.frontier(db, "owner") |> should.equal(Ok([stored]))
  let assert Ok(prepared) =
    prepared_result(
      reopened,
      resumed,
      fn(_) { panic as "below trigger cannot summarize" },
      False,
    )
  prepared.inputs |> should.equal(first.inputs)
  let actual =
    request_context.assemble(
      types.Request(
        "model",
        Some("static"),
        prepared.inputs,
        [],
        None,
        types.defaults,
      ),
      prepared.request_context,
    )
  list.each([types.Responses, types.ChatCompletions], fn(protocol) {
    let assert Ok(wire) = provider_request.encode(protocol, actual)
    let key = case protocol {
      types.Responses -> "input"
      types.ChatCompletions -> "messages"
    }
    let assert Ok(roles) =
      json.parse(
        string_tree.to_string(wire),
        decode.field(
          key,
          decode.list(decode.optional_field(
            "role",
            "",
            decode.string,
            decode.success,
          )),
          decode.success,
        ),
      )
    let offset = case protocol {
      types.Responses -> 0
      types.ChatCompletions -> 1
    }
    list.drop(roles, offset)
    |> should.equal(list.map(actual.input, narration.source_role))
  })
  let foreign =
    n.Frame(
      ..frame,
      narrator: Some(n.Narrator(
        "different",
        persona.name,
        persona.identity_revision,
      )),
    )
  list.each(
    [
      graph.Node(..stored, frame: None),
      graph.Node(..stored, frame: Some(foreign)),
    ],
    fn(node) {
      let assert [types.User(_)] = narration.render(node, Some(persona.id))
      Nil
    },
  )
  let assert [types.User(_), types.Assistant(_)] =
    narration.render(
      graph.Node(
        ..stored,
        frame: Some(n.Frame(..frame, perspective: n.Witnessed)),
      ),
      Some(persona.id),
    )
  conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
  cleanup(reopened, resumed)
}

pub fn cross_session_continuity_does_not_grant_access_test() -> Nil {
  let path = "/tmp/stage2-continuity-" <> ledger.new_id() <> ".sqlite"
  let #(host, session, persona) = setup_at(path, True)
  save(host, "continuity ask ATLAS", "own action")
  save(host, "latest tail", "tail")
  let _ =
    prepare(host, session, fn(_) { Ok("I remember the ATLAS continuity ask.") })
  let db = runtime.ledger(host)
  let assert Ok([original]) = graph.frontier(db, "owner")
  session_fixture.create(host, "new-owner", "/tmp")
  ledger.resolve_fresh_binding(db, "new-owner") |> should.be_ok
  let installed = composition.extensions(session.composition)
  let fresh =
    state.Session(
      "new-owner",
      "/tmp",
      unused_kernel(),
      db,
      composition.compose(installed, db, "new-owner", "/tmp"),
      "static",
      [],
      state.Fresh,
    )
  // A newer same-name permanent identity and unbound name-only rows are controls.
  let assert Ok(other) =
    ledger.create(db, persona.name, "Other deliberate identity", True, False)
  session_fixture.create(host, "other-owner", "/tmp")
  ledger.bind(db, "other-owner", other.id, 0, 0, runtime.installed(host))
  |> should.be_ok
  conversation.commit_from(
    db,
    "other-owner",
    [types.User("other"), types.Assistant("other action")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([other_a, other_b]) =
    conversation.load_sources(db, "other-owner")
  let other_frame =
    n.Frame(Some(n.Narrator(other.id, persona.name, 1)), n.Experienced, [], [])
  graph.save_leaves(db, "other-owner", [
    graph.Leaf(
      other_a.source.seq,
      other_b.source.seq,
      "I am the same name but different identity.",
      Some(other_frame),
    ),
  ])
  |> should.be_ok
  session_fixture.create(host, "unbound-name", "/tmp")
  conversation.commit_from(
    db,
    "unbound-name",
    [types.User("Ash"), types.Assistant("unbound name")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([unbound_a, unbound_b]) =
    conversation.load_sources(db, "unbound-name")
  graph.save_leaves(db, "unbound-name", [
    graph.Leaf(
      unbound_a.source.seq,
      unbound_b.source.seq,
      "I have only a matching name.",
      original.frame,
    ),
  ])
  |> should.be_ok
  // A controlled delegate-only binding fixture isolates continuity selection;
  // personality_delegation_test covers the native creation lifecycle.
  session_fixture.create(host, "delegate-only", "/tmp")
  store.query(db, fn(connection) {
    store.exec(
      connection,
      "INSERT INTO personality_session(session,persona_id,mode,generation,pre_binding_through) SELECT 'delegate-only',persona_id,'delegate',1,0 FROM personality_session WHERE session='owner'; INSERT INTO personality_binding_revision(session,generation,persona_id,mode,pre_binding_through,created_at) SELECT 'delegate-only',1,persona_id,'delegate',0,0 FROM personality_session WHERE session='owner'",
    )
  })
  |> should.be_ok
  conversation.commit_from(
    db,
    "delegate-only",
    [types.User("delegate"), types.Assistant("delegate")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([delegate_a, delegate_b]) =
    conversation.load_sources(db, "delegate-only")
  graph.save_leaves(db, "delegate-only", [
    graph.Leaf(
      delegate_a.source.seq,
      delegate_b.source.seq,
      "I only did delegated work.",
      original.frame,
    ),
  ])
  |> should.be_ok
  let assert Ok(prepared) =
    prepared_result(
      host,
      fresh,
      fn(_) { panic as "empty continuity must not summarize" },
      False,
    )
  let assert [types.User(cue), types.Assistant(memory)] = prepared.inputs
  should.be_true(string.contains(cue, "session owner"))
  memory |> should.equal(original.summary)
  graph.frontier(db, "new-owner") |> should.equal(Ok([]))
  let unavailable = kernels.kernel_routes(db, "new-owner", fresh.composition)
  list.each(["agents.messages", "agents.search_messages"], fn(method) {
    let output =
      unavailable(
        json.to_string(
          json.object([
            #("method", json.string(method)),
            #(
              "args",
              json.object([
                #("id", json.string("owner")),
                #("seq", json.int(0)),
                #("offset", json.int(0)),
                #("limit", json.int(4000)),
                #("pattern", json.string("ATLAS")),
              ]),
            ),
          ]),
        ),
      )
    let assert Ok(code) =
      json.parse(output, decode.field("code", decode.string, decode.success))
    code |> should.equal("unavailable")
  })
  let assert Ok(tool) =
    list.find(lcm_tools.definitions(), fn(tool) {
      tool.definition.name == "lcm_describe"
    })
  let outcome =
    extension.invoke(
      tool,
      extension.Context(
        db,
        "new-owner",
        unused_kernel(),
        "scope",
        "/tmp",
        types.any_images,
      ),
      json.to_string(json.object([#("id", json.int(original.id))])),
    )
  should.be_error(outcome)
  let with_agents =
    composition.compose(
      list.append(installed, [
        python.extension(),
        mail.extension(),
        agents.extension(),
      ]),
      db,
      "new-owner",
      "/tmp",
    )
  let available = kernels.kernel_routes(db, "new-owner", with_agents)
  list.each(["owner", "other-owner"], fn(target) {
    let output =
      available(
        json.to_string(
          json.object([
            #("method", json.string("agents.messages")),
            #(
              "args",
              json.object([
                #("id", json.string(target)),
                #("seq", json.int(0)),
                #("offset", json.int(0)),
                #("limit", json.int(4000)),
              ]),
            ),
          ]),
        ),
      )
    let assert Ok(ok) =
      json.parse(output, decode.field("ok", decode.bool, decode.success))
    ok |> should.equal(True)
  })
  composition.close(with_agents)
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "copied-frontier", through) |> should.be_ok
  let assert Ok(fork_binding) = ledger.capture(db, "copied-frontier")
  fork_binding.persona.id |> should.equal(persona.id)
  fork_binding.binding.mode |> should.equal("delegate")
  let forked =
    state.Session(
      "copied-frontier",
      "/tmp",
      unused_kernel(),
      db,
      composition.compose(installed, db, "copied-frontier", "/tmp"),
      "static",
      [],
      state.Fresh,
    )
  let assert Ok(fork_prepared) =
    prepared_result(
      host,
      forked,
      fn(_) { panic as "stored fork frontier cannot summarize" },
      False,
    )
  list.filter(fork_prepared.inputs, fn(input) {
    input == types.Assistant(original.summary)
  })
  |> list.length
  |> should.equal(1)
  composition.close(forked.composition)
  composition.close(fresh.composition)
  cleanup(host, session)
  let assert Ok(reopened) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(reopened)
  let db = runtime.ledger(reopened)
  let resumed =
    state.Session(
      "new-owner",
      "/tmp",
      unused_kernel(),
      db,
      composition.compose(installed, db, "new-owner", "/tmp"),
      "static",
      [],
      state.Fresh,
    )
  let assert Ok(repeated) =
    prepared_result(
      reopened,
      resumed,
      fn(_) { panic as "reopened continuity cannot summarize" },
      False,
    )
  let assert [types.User(_), types.Assistant(repeated_memory)] = repeated.inputs
  repeated_memory |> should.equal(original.summary)
  graph.frontier(db, "new-owner") |> should.equal(Ok([]))
  cleanup(reopened, resumed)
}

pub fn binding_selection_and_statement_failures_leave_no_graph_fragments_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "old ask", "old action")
  save(host, "latest tail", "tail")
  let db = runtime.ledger(host)
  let policy = policy_for(db, "owner")
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  let assert [a, b, _, _] = rows
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let leaves = [graph.Leaf(a.source.seq, b.source.seq, "candidate", None)]
  store.query(db, fn(connection) {
    store.exec(
      connection,
      "UPDATE sessions SET config_revision=config_revision+1 WHERE id='owner'",
    )
  })
  |> should.be_ok
  graph.commit_leaves(
    db,
    "owner",
    snapshot,
    leaves,
    episodes.guard(policy, "owner"),
  )
  |> should.equal(Ok(False))
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  let policy = policy_for(db, "owner")
  store.query(db, fn(connection) {
    store.exec(
      connection,
      "CREATE TRIGGER stage2_refuse_cursor BEFORE INSERT ON lcm_compaction_state BEGIN SELECT RAISE(ABORT,'refuse cursor'); END",
    )
  })
  |> should.be_ok
  graph.commit_leaves(
    db,
    "owner",
    snapshot,
    leaves,
    episodes.guard(policy, "owner"),
  )
  |> should.be_error
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  graph.last_seq(db, "owner") |> should.equal(Ok(0))
  store.query(db, fn(connection) {
    store.exec(connection, "DROP TRIGGER stage2_refuse_cursor")
  })
  |> should.be_ok
  let assert Ok(other) =
    ledger.create(db, "other", "other identity", True, False)
  let assert Ok(through) = conversation.last_seq(db, "owner")
  ledger.bind(db, "owner", other.id, 1, through, runtime.installed(host))
  |> should.be_ok
  graph.commit_leaves(
    db,
    "owner",
    snapshot,
    leaves,
    episodes.guard(policy, "owner"),
  )
  |> should.equal(Ok(False))
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
  cleanup(host, session)
}

pub fn reading_consolidation_folds_bounded_subsets_without_losing_early_portions_test() -> Nil {
  let #(host, session, _) = setup()
  let document =
    "FIRST-ASH-ORBIT "
    <> string.repeat("long source background ", 80_000)
    <> " MIDDLE-ASH-QUAY "
    <> string.repeat("long source background ", 80_000)
    <> " LAST-ASH-LARCH"
  save(host, document, "I received the whole account.")
  save(host, "retained", "tail")
  let calls = process.new_subject()
  process.send(calls, [])
  let _ =
    prepare(host, session, fn(request) {
      let assert Some(formation) = request.formation
      let assert Ok(actual) = loop.summarizer_request(request)
      should.be_true(
        compaction.estimate_pinned(option.unwrap(actual.instructions, ""), [])
        + compaction.estimate_inputs(actual.input)
        + request.max_output_tokens
        <= formation.budget,
      )
      let assert Ok(seen) = process.receive(calls, 0)
      process.send(calls, [request, ..seen])
      Ok(
        "I read "
        <> facts(contents(request.evicted))
        <> " in the source. "
        <> string.repeat("reflection detail ", 140),
      )
    })
  let assert Ok(seen) = process.receive(calls, 100)
  let chronological = list.reverse(seen)
  let folds =
    list.filter(chronological, fn(request) {
      case request.formation {
        Some(value) -> value.mode == "consolidation"
        _ -> False
      }
    })
  should.be_true(list.length(folds) > 1)
  list.each(folds, fn(request) {
    let assert Some(n.Formation(portions: [_, ..], source_only: True, ..)) =
      request.formation
    should.be_true(
      list.any(request.evicted, fn(input) {
        case input {
          types.Assistant(_) -> True
          _ -> False
        }
      }),
    )
  })
  let assert Ok(final) = list.last(folds)
  facts(contents(final.evicted))
  |> should.equal("FIRST-ASH-ORBIT; MIDDLE-ASH-QUAY; LAST-ASH-LARCH")
  let assert Ok([node]) = graph.frontier(runtime.ledger(host), "owner")
  facts(node.summary)
  |> should.equal("FIRST-ASH-ORBIT; MIDDLE-ASH-QUAY; LAST-ASH-LARCH")
  let assert Ok(expander) =
    list.find(lcm_tools.definitions(), fn(tool) {
      tool.definition.name == "lcm_expand"
    })
  let assert Ok(expanded) =
    extension.invoke(
      expander,
      extension.Context(
        runtime.ledger(host),
        "owner",
        unused_kernel(),
        "late-source",
        "/tmp",
        types.any_images,
      ),
      json.to_string(
        json.object([
          #("id", json.int(node.id)),
          #("offset", json.int(string.length(document) - 2048)),
          #("limit", json.int(4096)),
        ]),
      ),
    )
  should.be_true(string.contains(expanded.text, "LAST-ASH-LARCH"))
  cleanup(host, session)
}

pub fn normalized_tool_and_replay_sources_keep_order_without_orphan_wire_items_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  let assert Ok(replay) =
    json.parse(
      "{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"inspect\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/source\\\"}\"}",
      types.replay_decoder(types.Responses),
    )
  let submission =
    turn.Submission(
      "Check tool evidence",
      "Check tool evidence",
      "",
      turn.Chat,
      [],
      None,
      None,
    )
  conversation.commit_operations(
    db,
    "owner",
    [
      session_submission.input(submission),
      types.Replay(replay),
      types.ToolOutput("call-1", "TOOL-OBSERVED actual result", []),
      types.Assistant("I checked the result."),
    ],
    conversation.Idle,
    None,
    [],
    session_submission.commits([submission], 0),
    "tool-source",
    "/tmp",
  )
  |> should.be_ok
  save(host, "retained tail", "tail")
  let calls = process.new_subject()
  let _ =
    prepare(host, session, fn(request) {
      process.send(calls, request)
      let assert Ok(actual) = loop.summarizer_request(request)
      let assert [
        types.User(_),
        types.User("Check tool evidence"),
        types.Assistant(call),
        types.User(output),
        types.Assistant("I checked the result."),
      ] = actual.input
      should.be_true(string.contains(call, "assistant source call inspect"))
      should.be_true(string.contains(output, "tool source output call-1"))
      actual.tools |> should.equal([])
      list.each([types.Responses, types.ChatCompletions], fn(protocol) {
        let assert Ok(encoded) = provider_request.encode(protocol, actual)
        let key = case protocol {
          types.Responses -> "input"
          types.ChatCompletions -> "messages"
        }
        let assert Ok(roles) =
          json.parse(
            string_tree.to_string(encoded),
            decode.field(
              key,
              decode.list(decode.optional_field(
                "role",
                "",
                decode.string,
                decode.success,
              )),
              decode.success,
            ),
          )
        let offset = case protocol {
          types.Responses -> 0
          types.ChatCompletions -> 1
        }
        list.drop(roles, offset)
        |> should.equal(["user", "user", "assistant", "user", "assistant"])
      })
      Ok("I remember checking TOOL-OBSERVED and the source path.")
    })
  let assert Ok(request) = process.receive(calls, 100)
  let assert Some(n.Formation(frame: frame, ..)) = request.formation
  list.map(frame.sources, fn(source) { source.role })
  |> should.equal(["user", "assistant", "tool", "assistant"])
  list.map(frame.sources, fn(source) { source.actor })
  |> should.equal([
    "user_assertion",
    "owner_agent",
    "tool_report",
    "owner_agent",
  ])
  cleanup(host, session)
}

pub fn parent_rereads_actual_child_memory_one_level_deeper_test() -> Nil {
  let #(host, session, persona) = setup()
  let db = runtime.ledger(host)
  list.each(["one", "two", "three", "four"], fn(unit) {
    save(host, unit, "action " <> unit)
  })
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  let frame =
    n.Frame(
      Some(n.Narrator(persona.id, persona.name, 1)),
      n.Experienced,
      [],
      [],
    )
  let leaves =
    list.sized_chunk(rows, 2)
    |> list.index_map(fn(unit, index) {
      let assert [a, b] = unit
      graph.Leaf(
        a.source.seq,
        b.source.seq,
        "DEEP-CHILD-"
          <> case index {
          0 -> "FIRST"
          3 -> "LAST"
          _ -> "MIDDLE"
        },
        Some(frame),
      )
    })
  graph.save_leaves(db, "owner", leaves) |> should.be_ok
  let assert Ok([a, b, c, d]) = graph.frontier(db, "owner")
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    [a, b],
    "SHALLOW-PARENT-A",
    Some(narration.parent_frame([a, b], "owner")),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    [c, d],
    "SHALLOW-PARENT-B",
    Some(narration.parent_frame([c, d], "owner")),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert Ok(parents) = graph.frontier(db, "owner")
  let policy = policy_for(db, "owner")
  let context =
    context_for(db, "owner", policy, fn(request) {
      let assert Some(n.Formation(source_only: False, ..)) = request.formation
      let text = contents(request.evicted)
      should.be_true(string.contains(text, "DEEP-CHILD-FIRST"))
      should.be_true(string.contains(text, "DEEP-CHILD-LAST"))
      should.be_false(string.contains(text, "SHALLOW-PARENT-A"))
      should.be_false(string.contains(text, "SHALLOW-PARENT-B"))
      Ok("I remember DEEP-CHILD-FIRST through DEEP-CHILD-LAST.")
    })
  let assert Ok(#(summary, Some(frame))) =
    formation.parent(context, parents, 768, policy)
  should.be_true(string.contains(summary, "DEEP-CHILD-FIRST"))
  list.map(frame.children, fn(child) { child.id })
  |> should.equal(list.map(parents, fn(parent) { parent.id }))
  cleanup(host, session)
}

pub fn oversized_narration_metadata_keeps_durable_actor_boundaries_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  let older =
    list.repeat(Nil, 40)
    |> list.map(fn(_) {
      types.Assistant("small action with an independent source row")
    })
  save(host, "older ask", "first action")
  conversation.commit_from(db, "owner", older, conversation.Idle, None)
  |> should.be_ok
  save(host, "latest", "tail")
  let calls = process.new_subject()
  let _ =
    prepare(host, session, fn(request) {
      process.send(calls, request)
      Ok("I remember the recorded actions and their source boundaries.")
    })
  let assert Ok(request) = process.receive(calls, 100)
  let assert Some(n.Formation(frame: frame, ..)) = request.formation
  list.length(frame.sources) |> should.equal(42)
  let assert Ok(envelope) = compaction.summary_envelope(request)
  should.be_true(string.contains(envelope, "exact durable frame"))
  // Even a bounded request fallback must retain the trusted narrator, without
  // replacing it with current binding inferred from summary prose.
  let assert Some(n.Narrator(subject, _, _)) = frame.narrator
  should.be_true(string.contains(envelope, "\"subject\":\"" <> subject <> "\""))
  let assert Ok([node]) = graph.frontier(db, "owner")
  node.frame |> should.equal(Some(frame))
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  list.map(frame.sources, fn(source) { source.seq })
  |> should.equal(list.take(rows, 42) |> list.map(fn(row) { row.source.seq }))
  cleanup(host, session)
}

pub fn preceding_same_narrator_memory_survives_unknown_parent_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "older remembered ask", "own first action")
  save(host, "second legacy unit", "second action")
  save(host, "third new ask", "third action")
  save(host, "retained latest", "tail")
  let db = runtime.ledger(host)
  let assert Ok([a, b, c, d, e, f, _, _]) =
    conversation.load_sources(db, "owner")
  let policy = policy_for(db, "owner")
  let first_context =
    context_for(db, "owner", policy, fn(_) {
      Ok("I remember my earlier first action.")
    })
  let assert Ok([known]) = formation.leaves(first_context, [a, b], 768, policy)
  graph.save_leaves(db, "owner", [
    known,
    graph.Leaf(
      c.source.seq,
      d.source.seq,
      "I is only prose in a legacy unknown frame.",
      None,
    ),
  ])
  |> should.be_ok
  let assert Ok(children) = graph.frontier(db, "owner")
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    children,
    "Attributed mixed historical evidence.",
    Some(narration.parent_frame(children, "owner")),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let context =
    context_for(db, "owner", policy, fn(request) {
      let assert Some(n.Formation(previous: Some(previous), ..)) =
        request.formation
      previous.text |> should.equal(known.summary)
      let assert Ok(actual) = loop.summarizer_request(request)
      should.be_true(list.contains(actual.input, types.Assistant(known.summary)))
      Ok("I remember the third action.")
    })
  formation.leaves(context, [e, f], 768, policy) |> should.be_ok
  cleanup(host, session)
}

pub fn mandatory_summary_context_refuses_before_provider_or_source_progress_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "older actual source", "own action")
  let db = runtime.ledger(host)
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  let policy = policy_for(db, "owner")
  let calls = process.new_subject()
  let context =
    context_for(db, "owner", policy, fn(_) {
      process.send(calls, Nil)
      Ok("must never happen")
    })
  let context =
    compaction.Context(
      ..context,
      capacity: Some(compaction.Capacity(1000, "small actual allowance")),
    )
  formation.leaves(context, rows, 768, policy) |> should.be_error
  process.receive(calls, 0) |> should.equal(Error(Nil))
  graph.frontier(db, "owner") |> should.equal(Ok([]))
  graph.last_seq(db, "owner") |> should.equal(Ok(0))
  conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
  cleanup(host, session)
}

pub fn legacy_native_graph_adds_optional_frame_without_rewriting_rows_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "legacy one", "legacy action one")
  save(host, "legacy two", "legacy action two")
  let db = runtime.ledger(host)
  let assert Ok([a, b, c, d]) = conversation.load_sources(db, "owner")
  graph.save_leaves(db, "owner", [
    graph.Leaf(a.source.seq, b.source.seq, "I is just legacy prose.", None),
    graph.Leaf(c.source.seq, d.source.seq, "another legacy leaf", None),
  ])
  |> should.be_ok
  let assert Ok(children) = graph.frontier(db, "owner")
  graph.save_parent(db, "owner", children, "legacy parent") |> should.be_ok
  let assert Ok(before) = graph.frontier(db, "owner")
  store.query(db, fn(connection) {
    store.exec(
      connection,
      "DROP INDEX lcm_compaction_node_narrator_formation; ALTER TABLE lcm_compaction_node DROP COLUMN narration; ALTER TABLE lcm_compaction_node DROP COLUMN formation_id",
    )
  })
  |> should.be_ok
  graph.initialise(db) |> should.be_ok
  graph.frontier(db, "owner") |> should.equal(Ok(before))
  let assert Ok(graph.NodeListPage(3, listed)) =
    graph.list_page(db, "owner", 20, 0)
  should.be_true(list.all(listed, fn(item) { item.0.frame == None }))
  let assert Ok(parent) = list.last(before)
  graph.children(db, parent.id)
  |> should.equal(Ok(list.map(children, fn(child) { child.id })))
  graph.last_seq(db, "owner") |> should.equal(Ok(d.source.seq))
  conversation.load_sources(db, "owner") |> should.equal(Ok([a, b, c, d]))
  cleanup(host, session)
}

pub fn reading_many_source_rows_preserves_whole_unit_and_atomicity_test() -> Nil {
  list.each(
    [#(32, False), #(33, False), #(97, False), #(33, True), #(97, True)],
    fn(case_) {
      let #(count, background) = case_
      let #(host, session, _) = setup()
      let db = runtime.ledger(host)
      session_fixture.create(host, "gap-source", "/tmp")
      let rows = list.index_map(list.repeat(Nil, count), fn(_, index) { index })
      list.each(rows, fn(index) {
        let mark = case index {
          0 -> "FIRST-ASH-ORBIT"
          _ if index == count / 2 -> "MIDDLE-ASH-QUAY"
          _ if index == count - 1 -> "LAST-ASH-LARCH"
          _ -> "ordinary source"
        }
        let text = mark <> string.repeat(" source background ", 300)
        let input = case index {
          0 -> types.User(text)
          _ if count == 97 && index % 2 == 0 ->
            types.ToolOutput("call-" <> int.to_string(index - 1), text, [])
          _ if count == 97 -> {
            let assert Ok(replay) =
              json.parse(
                json.to_string(
                  json.object([
                    #("type", json.string("function_call")),
                    #("call_id", json.string("call-" <> int.to_string(index))),
                    #("name", json.string("read_source")),
                    #("arguments", json.string(text)),
                  ]),
                ),
                types.replay_decoder(types.Responses),
              )
            types.Replay(replay)
          }
          _ -> types.Assistant(text)
        }
        conversation.commit_from(
          db,
          "owner",
          case count {
            97 -> [input, types.Assistant("")]
            _ -> [input]
          },
          conversation.Idle,
          None,
        )
        |> should.be_ok
        // Global sequence gaps are not absent local source rows.
        conversation.commit_from(
          db,
          "gap-source",
          [types.Assistant("gap")],
          conversation.Idle,
          None,
        )
        |> should.be_ok
      })
      save(host, "retained", "tail")
      let assert Ok(all) = conversation.load_sources(db, "owner")
      let expected =
        list.take(all, case count {
          97 -> count * 2
          _ -> count
        })
      let failing =
        formation_result(host, session, background, fn(request) {
          let assert Some(formed) = request.formation
          case formed.mode {
            "consolidation" -> Error("reading final fold refused")
            _ ->
              Ok(
                "I read "
                <> facts(contents(request.evicted))
                <> " in this portion.",
              )
          }
        })
      failing
      |> should.equal(Error(
        "compaction personality: reading final fold refused",
      ))
      graph.frontier(db, "owner") |> should.equal(Ok([]))
      graph.last_seq(db, "owner") |> should.equal(Ok(0))
      let calls = process.new_subject()
      process.send(calls, [])
      let _ =
        formation_result(host, session, background, fn(request) {
          let assert Some(formed) = request.formation
          let assert Ok(actual) = loop.summarizer_request(request)
          should.be_true(
            compaction.estimate_pinned(
              option.unwrap(actual.instructions, ""),
              [],
            )
            + compaction.estimate_inputs(actual.input)
            + request.max_output_tokens
            <= formed.budget,
          )
          let assert Ok(seen) = process.receive(calls, 0)
          process.send(calls, [request, ..seen])
          Ok(
            "I read "
            <> facts(contents(request.evicted))
            <> " in this portion."
            <> case count {
              97 -> string.repeat(" reflection detail ", 130)
              _ -> ""
            },
          )
        })
      let assert Ok(seen) = process.receive(calls, 100)
      let readings =
        list.filter(seen, fn(call) {
          let assert Some(formed) = call.formation
          formed.mode == "reading"
        })
      list.length(readings) |> should.equal(count)
      let folds =
        list.filter(seen, fn(call) {
          let assert Some(formed) = call.formation
          formed.mode == "consolidation"
        })
      should.be_true(
        list.length(folds)
        >= case count {
          97 -> 2
          _ -> 1
        },
      )
      let assert [final, ..] = folds
      let assert Some(formed) = final.formation
      list.map(formed.portions, fn(portion) { portion.seq })
      |> should.equal(list.map(expected, fn(row) { row.source.seq }))
      let assert Ok([node]) = graph.frontier(db, "owner")
      facts(node.summary)
      |> should.equal("FIRST-ASH-ORBIT; MIDDLE-ASH-QUAY; LAST-ASH-LARCH")
      let assert Some(frame) = node.frame
      list.map(frame.sources, fn(source) { source.seq })
      |> should.equal(list.map(expected, fn(row) { row.source.seq }))
      let assert Ok(last) = list.last(expected)
      graph.last_seq(db, "owner") |> should.equal(Ok(last.source.seq))
      conversation.load_sources(db, "owner") |> should.equal(Ok(all))
      cleanup(host, session)
    },
  )
}

fn formation_result(
  host: runtime.Runtime,
  session: state.Session,
  background: Bool,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
) -> Result(Nil, String) {
  case background {
    False ->
      prepared_result(host, session, summarize, True) |> result.replace(Nil)
    True -> {
      let context =
        context_for(
          runtime.ledger(host),
          session.id,
          policy_for(runtime.ledger(host), session.id),
          summarize,
        )
      use strategy <- result.try(lcm.strategy("personality").resolve(
        context.capacity,
        None,
      ))
      let assert Some(ahead) = strategy.prepare_ahead
      ahead(context)
      |> result.replace(Nil)
      |> result.map_error(fn(error) { "compaction personality: " <> error })
    }
  }
}

fn invoke_lcm(db: store.Store, name: String, args: json.Json) -> String {
  let assert Ok(tool) =
    list.find(lcm_tools.definitions(), fn(tool) { tool.definition.name == name })
  let assert Ok(extension.Output(text, [])) =
    extension.invoke(
      tool,
      extension.Context(
        db,
        "owner",
        unused_kernel(),
        "metadata-page",
        "/tmp",
        types.any_images,
      ),
      json.to_string(args),
    )
  text
}

fn metadata_pages(
  db: store.Store,
  id: Int,
  offset: Int,
  acc: List(String),
) -> String {
  let text =
    invoke_lcm(
      db,
      "lcm_describe",
      json.object([
        #("id", json.int(id)),
        #("metadata_offset", json.int(offset)),
        #("metadata_limit", json.int(1024)),
      ]),
    )
  should.be_true(string.byte_size(text) <= 8000)
  let assert Ok(#(page, next)) =
    json.parse(text, {
      use page <- decode.field("metadata_content", decode.string)
      use next <- decode.field(
        "next_metadata_offset",
        decode.optional(decode.int),
      )
      decode.success(#(page, next))
    })
  case next {
    None -> list.reverse([page, ..acc]) |> string.concat
    Some(next) -> {
      should.be_true(next > offset)
      metadata_pages(db, id, next, [page, ..acc])
    }
  }
}

fn summary_pages(
  db: store.Store,
  id: Int,
  offset: Int,
  acc: List(String),
) -> String {
  let text =
    invoke_lcm(
      db,
      "lcm_describe",
      json.object([
        #("id", json.int(id)),
        #("summary_offset", json.int(offset)),
        #("summary_limit", json.int(128)),
      ]),
    )
  let assert Ok(#(page, next)) =
    json.parse(text, {
      use page <- decode.field("summary", decode.string)
      use next <- decode.field(
        "next_summary_offset",
        decode.optional(decode.int),
      )
      decode.success(#(page, next))
    })
  case next {
    None -> list.reverse([page, ..acc]) |> string.concat
    Some(next) -> {
      should.be_true(next > offset)
      summary_pages(db, id, next, [page, ..acc])
    }
  }
}

fn list_metadata_ids(
  db: store.Store,
  offset: Int,
  acc: List(Int),
) -> List(Int) {
  let text =
    invoke_lcm(db, "lcm_list", json.object([#("offset", json.int(offset))]))
  should.be_true(string.byte_size(text) <= 12_200)
  let assert Ok(#(ids, next)) =
    json.parse(text, {
      use ids <- decode.field(
        "folds",
        decode.list(decode.field("id", decode.int, decode.success)),
      )
      use next <- decode.field("next_offset", decode.optional(decode.int))
      decode.success(#(ids, next))
    })
  case next {
    None -> list.append(acc, ids)
    Some(next) -> {
      next |> should.equal(offset + list.length(ids))
      should.be_true(next > offset)
      list_metadata_ids(db, next, list.append(acc, ids))
    }
  }
}

pub fn legitimately_formed_source_heavy_retrieval_is_bounded_and_complete_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  let assert Ok(large_name) =
    ledger.create(
      db,
      "Q" <> string.repeat("\n", 255),
      "Living identity",
      True,
      False,
    )
  ledger.bind(db, "owner", large_name.id, 1, 0, runtime.installed(host))
  |> should.be_ok
  let summary =
    "é🧭 I received statuses " <> string.repeat("é🧭\"\n", 300) <> " retained."
  // Enough real nodes to exercise byte-bounded default and child paging, with
  // the source-heavy frame that previously bypassed its summary preview cap.
  list.each(
    list.index_map(list.repeat(Nil, 25), fn(_, index) { index + 1 }),
    fn(unit) {
      conversation.commit_from(
        db,
        "owner",
        [
          types.User("short source-heavy unit " <> int.to_string(unit)),
          ..list.repeat(types.Assistant("status é🧭"), 600)
        ],
        conversation.Idle,
        None,
      )
      |> should.be_ok
    },
  )
  save(host, "retained newest unit", "raw tail")
  list.each(list.repeat(Nil, 25), fn(_) {
    let assert Ok(rows) = conversation.load_sources(db, "owner")
    let assert Ok(after) = graph.last_seq(db, "owner")
    let rows =
      list.filter(rows, fn(row) { row.source.seq > after })
      |> list.take(601)
    let policy = policy_for(db, "owner")
    let context = context_for(db, "owner", policy, fn(_) { Ok(summary) })
    let assert Ok(leaves) = formation.leaves(context, rows, 768, policy)
    let assert Ok(snapshot) = graph.snapshot(db, "owner")
    graph.commit_leaves(
      db,
      "owner",
      snapshot,
      leaves,
      episodes.guard(policy, "owner"),
    )
    |> should.equal(Ok(True))
  })
  let one = invoke_lcm(db, "lcm_list", json.object([#("limit", json.int(1))]))
  let default = invoke_lcm(db, "lcm_list", json.object([]))
  should.be_true(string.byte_size(one) <= 4096)
  should.be_true(string.byte_size(default) <= 16_000)
  should.be_true(compaction.estimate_input(types.User(default)) <= 4096)
  let assert Ok(graph.NodeListPage(25, listed)) =
    graph.list_page(db, "owner", 20, 0)
  let assert Ok(returned) =
    json.parse(
      default,
      decode.field("folds", decode.list(decode.dynamic), decode.success),
    )
  should.be_true(list.length(returned) < 20)
  let assert Ok(all_frontier) = graph.frontier(db, "owner")
  list_metadata_ids(db, 0, [])
  |> should.equal(list.map(all_frontier, fn(node) { node.id }))
  list.each(listed, fn(item) {
    let node = item.0
    let assert Some(frame) = node.frame
    list.length(frame.sources) |> should.equal(601)
    let describe =
      invoke_lcm(db, "lcm_describe", json.object([#("id", json.int(node.id))]))
    should.be_true(string.byte_size(describe) <= 12_000)
  })
  let assert [#(node, _), ..] = listed
  summary_pages(db, node.id, 0, []) |> should.equal(node.summary)
  let assert Ok(describe_tool) =
    list.find(lcm_tools.definitions(), fn(tool) {
      tool.definition.name == "lcm_describe"
    })
  list.each(
    [
      json.object([#("id", json.int(node.id)), #("summary_offset", json.int(1))]),
      json.object([#("id", json.int(node.id)), #("summary_limit", json.int(1))]),
      json.object([
        #("id", json.int(node.id)),
        #("metadata_offset", json.int(-1)),
      ]),
    ],
    fn(args) {
      extension.invoke(
        describe_tool,
        extension.Context(
          db,
          "owner",
          unused_kernel(),
          "invalid-page",
          "/tmp",
          types.any_images,
        ),
        json.to_string(args),
      )
      |> should.be_error
    },
  )
  let huge =
    invoke_lcm(
      db,
      "lcm_describe",
      json.object([
        #("id", json.int(node.id)),
        #("metadata_limit", json.int(100_000)),
        #("summary_limit", json.int(100_000)),
      ]),
    )
  let assert Ok(#(metadata, summary)) =
    json.parse(huge, {
      use metadata <- decode.field("metadata_content", decode.string)
      use summary <- decode.field("summary", decode.string)
      decode.success(#(metadata, summary))
    })
  should.be_true(string.byte_size(metadata) <= 2048)
  should.be_true(string.byte_size(summary) <= 2048)
  let complete = metadata_pages(db, node.id, 0, [])
  let assert Ok(#(restored, children)) =
    json.parse(complete, {
      use frame <- decode.field("narration", n.decoder())
      use children <- decode.field("children", decode.list(decode.int))
      decode.success(#(frame, children))
    })
  Some(restored) |> should.equal(node.frame)
  children |> should.equal([])
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let assert Ok(frontier) = graph.frontier(db, "owner")
  let parent_frame = narration.parent_frame(frontier, "owner")
  graph.commit_parent(
    db,
    "owner",
    snapshot,
    frontier,
    "I remember the source-heavy statuses.",
    Some(parent_frame),
    graph.unguarded,
  )
  |> should.equal(Ok(True))
  let assert Ok([parent]) = graph.frontier(db, "owner")
  let complete = metadata_pages(db, parent.id, 0, [])
  let assert Ok(#(restored, children)) =
    json.parse(complete, {
      use frame <- decode.field("narration", n.decoder())
      use children <- decode.field("children", decode.list(decode.int))
      decode.success(#(frame, children))
    })
  restored |> should.equal(parent_frame)
  children |> should.equal(list.map(frontier, fn(node) { node.id }))
  cleanup(host, session)
}

fn commit_memory(db: store.Store, id: String, text: String) -> Nil {
  // Active native writers retain the newest complete unit.
  conversation.commit_from(
    db,
    id,
    [types.User("retained newer unit")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let policy = policy_for(db, id)
  let context = context_for(db, id, policy, fn(_) { Ok(text) })
  let assert Ok(after) = graph.last_seq(db, id)
  let assert Ok(rows) = conversation.load_sources(db, id)
  let rows = list.filter(rows, fn(row) { row.source.seq > after })
  let rows = list.take(rows, list.length(rows) - 1)
  let assert Ok(leaves) = formation.leaves(context, rows, 768, policy)
  let assert Ok(snapshot) = graph.snapshot(db, id)
  graph.commit_leaves(db, id, snapshot, leaves, episodes.guard(policy, id))
  |> should.equal(Ok(True))
}

fn latest_memory(db: store.Store) -> String {
  let policy = policy_for(db, "owner")
  let assert Ok(Some(#(_, node))) = episodes.latest(db, "fresh", policy)
  node.summary
}

pub fn old_fork_copy_cannot_replace_newer_correction_even_after_reopen_test() -> Nil {
  let path = "/tmp/stage2-fork-chronology-" <> ledger.new_id() <> ".sqlite"
  let #(host, session, persona) = setup_at(path, True)
  let db = runtime.ledger(host)
  save(host, "The earlier fact was OLD.", "I remember OLD.")
  commit_memory(db, "owner", "I remember OLD.")
  session_fixture.create(host, "recent-correction", "/tmp")
  ledger.bind(
    db,
    "recent-correction",
    persona.id,
    0,
    0,
    runtime.installed(host),
  )
  |> should.be_ok
  conversation.commit_from(
    db,
    "recent-correction",
    [types.User("Correction: use NEW now."), types.Assistant("I now use NEW.")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  commit_memory(db, "recent-correction", "I now use NEW.")
  latest_memory(db) |> should.equal("I now use NEW.")
  let assert Ok(through) = conversation.last_seq(db, "owner")
  history.fork(db, "owner", "old-fork", through) |> should.be_ok
  let assert Ok(branch_through) = conversation.last_seq(db, "old-fork")
  // Deliberately select an owner source to keep this chronology falsifier
  // meaningful. Ordinary Stage 3 forks instead remain delegate sources.
  ledger.bind(
    db,
    "old-fork",
    persona.id,
    1,
    branch_through,
    runtime.installed(host),
  )
  |> should.be_ok
  latest_memory(db) |> should.equal("I now use NEW.")
  // Nested copies preserve the same original chronology too.
  history.fork(db, "old-fork", "nested-old-fork", branch_through)
  |> should.be_ok
  let assert Ok(nested_through) = conversation.last_seq(db, "nested-old-fork")
  ledger.bind(
    db,
    "nested-old-fork",
    persona.id,
    1,
    nested_through,
    runtime.installed(host),
  )
  |> should.be_ok
  latest_memory(db) |> should.equal("I now use NEW.")
  let installed = composition.extensions(session.composition)
  cleanup(host, session)
  let assert Ok(reopened) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(reopened)
  let db = runtime.ledger(reopened)
  latest_memory(db) |> should.equal("I now use NEW.")
  conversation.commit_from(
    db,
    "old-fork",
    [
      types.User("Actual later fork work changes the state to FORK-LATER."),
      types.Assistant("I now use FORK-LATER."),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  commit_memory(db, "old-fork", "I now use FORK-LATER.")
  latest_memory(db) |> should.equal("I now use FORK-LATER.")
  runtime.stop(reopened)
  let assert Ok(last_open) =
    runtime.start_with_config(path, extensions.Config(installed, []))
  session_fixture.initialise(last_open)
  latest_memory(runtime.ledger(last_open))
  |> should.equal("I now use FORK-LATER.")
  runtime.stop(last_open)
}

// Inspect actual serialized session definitions. Native argument invocation
// cannot observe provider rejection of an invalid strict object schema.
fn complete_strict_objects(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> {
      let object =
        dict.has_key(fields, "properties")
        || decode.run(
          value,
          decode.field("type", decode.string, decode.success),
        )
        == Ok("object")
      let own = case object {
        False -> True
        True -> {
          let properties =
            decode.run(
              value,
              decode.field(
                "properties",
                decode.dict(decode.string, decode.dynamic),
                decode.success,
              ),
            )
          let required =
            decode.run(
              value,
              decode.field(
                "required",
                decode.list(decode.string),
                decode.success,
              ),
            )
          case properties, required {
            Ok(properties), Ok(required) ->
              decode.run(
                value,
                decode.field(
                  "additionalProperties",
                  decode.bool,
                  decode.success,
                ),
              )
              == Ok(False)
              && list.length(required) == dict.size(properties)
              && list.all(dict.keys(properties), list.contains(required, _))
            _, _ -> False
          }
        }
      }
      own && list.all(dict.values(fields), complete_strict_objects)
    }
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(values) -> list.all(values, complete_strict_objects)
        Error(_) -> True
      }
  }
}

pub fn actual_session_tool_schemas_preserve_strict_object_contract_test() -> Nil {
  // Positive and nested-negative controls keep validation meaningful even when
  // all optional retrieval/document tools correctly use non-strict schemas.
  let assert Ok(valid) =
    json.parse(
      "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"id\":{\"type\":\"integer\"}},\"required\":[\"id\"]}",
      decode.dynamic,
    )
  complete_strict_objects(valid) |> should.be_true
  let assert Ok(invalid) =
    json.parse(
      "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"nested\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"optional\":{\"type\":\"integer\"}},\"required\":[]}},\"required\":[\"nested\"]}",
      decode.dynamic,
    )
  complete_strict_objects(invalid) |> should.be_false
  let #(host, session, _) = setup()
  let tools = runtime.tools(session)
  should.be_true(list.any(tools, fn(tool) { tool.name == "lcm_describe" }))
  list.each([types.Responses, types.ChatCompletions], fn(protocol) {
    let request =
      types.Request(
        "fixture",
        None,
        [types.User("actual composed request")],
        tools,
        None,
        types.defaults,
      )
    let assert Ok(wire) = provider_request.encode(protocol, request)
    let function = {
      use name <- decode.field("name", decode.string)
      use strict <- decode.field("strict", decode.bool)
      use parameters <- decode.field("parameters", decode.dynamic)
      decode.success(#(name, strict, parameters))
    }
    let decoder = case protocol {
      types.Responses -> function
      types.ChatCompletions ->
        decode.field("function", function, decode.success)
    }
    let assert Ok(emitted) =
      json.parse(
        string_tree.to_string(wire),
        decode.field("tools", decode.list(decoder), decode.success),
      )
    list.map(emitted, fn(tool) { tool.0 })
    |> should.equal(list.map(tools, fn(tool) { tool.name }))
    let invalid =
      emitted
      |> list.filter(fn(tool) { tool.1 && !complete_strict_objects(tool.2) })
      |> list.map(fn(tool) { tool.0 })
    invalid |> should.equal([])
  })
  cleanup(host, session)
}

pub fn omitted_describe_paging_arguments_keep_native_defaults_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "Earlier source", "I checked the earlier source.")
  save(host, "retained", "tail")
  let _ = prepare(host, session, fn(_) { Ok("I remember the earlier check.") })
  let db = runtime.ledger(host)
  let assert Ok([node]) = graph.frontier(db, "owner")
  let assert Ok(before) = graph.snapshot(db, "owner")
  let defaults =
    invoke_lcm(db, "lcm_describe", json.object([#("id", json.int(node.id))]))
  let assert Ok(#(metadata_offset, summary_offset, summary)) =
    json.parse(defaults, {
      use metadata_offset <- decode.field("metadata_offset", decode.int)
      use summary_offset <- decode.field("summary_offset", decode.int)
      use summary <- decode.field("summary", decode.string)
      decode.success(#(metadata_offset, summary_offset, summary))
    })
  metadata_offset |> should.equal(0)
  summary_offset |> should.equal(0)
  summary |> should.equal(node.summary)
  // Supplying only one optional argument still defaults all the others.
  let partial =
    invoke_lcm(
      db,
      "lcm_describe",
      json.object([
        #("id", json.int(node.id)),
        #("metadata_limit", json.int(16)),
      ]),
    )
  let assert Ok(#(page, next, summary)) =
    json.parse(partial, {
      use page <- decode.field("metadata_content", decode.string)
      use next <- decode.field("next_metadata_offset", decode.int)
      use summary <- decode.field("summary", decode.string)
      decode.success(#(page, next, summary))
    })
  string.byte_size(page) |> should.equal(16)
  next |> should.equal(16)
  summary |> should.equal(node.summary)
  graph.snapshot(db, "owner") |> should.equal(Ok(before))
  cleanup(host, session)
}

pub fn leaf_commit_proves_actual_complete_source_prefix_test() -> Nil {
  list.each([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], fn(invalid) {
    let #(host, session, _) = setup()
    let db = runtime.ledger(host)
    session_fixture.create(host, "prefix-gap", "/tmp")
    list.each(
      [
        types.User(""),
        types.Assistant(""),
        types.ToolOutput("actual-call", "native result", []),
        types.User("newest unit stays raw"),
        types.Assistant("newest own action"),
      ],
      fn(input) {
        conversation.commit_from(db, "owner", [input], conversation.Idle, None)
        |> should.be_ok
        conversation.commit_from(
          db,
          "prefix-gap",
          [types.Assistant("foreign row")],
          conversation.Idle,
          None,
        )
        |> should.be_ok
      },
    )
    let assert Ok([a, b, c, d, e]) = conversation.load_sources(db, "owner")
    let assert Ok(source_snapshot) = conversation.snapshot(db, "owner")
    conversation.first_source_unit(db, source_snapshot, 0)
    |> should.equal(Ok(Some(#(a.source.seq, d.source.seq - 1))))
    let assert Ok(snapshot) = graph.snapshot(db, "owner")
    let policy = policy_for(db, "owner")
    let context = context_for(db, "owner", policy, fn(_) { Ok("I remember.") })
    let assert Ok([leaf]) = formation.leaves(context, [a, b, c], 768, policy)
    let assert Some(frame) = leaf.frame
    let assert [first_source, ..rest_sources] = frame.sources
    let leaves = case invalid {
      0 -> [graph.Leaf(..leaf, first_seq: b.source.seq)]
      1 -> [graph.Leaf(..leaf, first_seq: c.source.seq)]
      2 -> [
        graph.Leaf(a.source.seq, a.source.seq, "cut inside unit", None),
        graph.Leaf(c.source.seq, c.source.seq, "omitted empty row", None),
      ]
      3 -> [graph.Leaf(..leaf, last_seq: b.source.seq)]
      4 -> [graph.Leaf(..leaf, first_seq: a.source.seq + 1)]
      5 -> [graph.Leaf(..leaf, last_seq: c.source.seq + 1)]
      6 -> [graph.Leaf(..leaf, last_seq: e.source.seq)]
      8 -> [
        graph.Leaf(
          ..leaf,
          frame: Some(
            n.Frame(..frame, sources: [
              n.Boundary(..first_source, session: "prefix-gap"),
              ..rest_sources
            ]),
          ),
        ),
      ]
      9 -> [graph.Leaf(..leaf, last_seq: c.source.seq + 2)]
      _ -> [
        graph.Leaf(
          ..leaf,
          frame: Some(
            n.Frame(
              ..frame,
              sources: list.filter(frame.sources, fn(row) {
                row.seq != b.source.seq
              }),
            ),
          ),
        ),
      ]
    }
    graph.commit_leaves(db, "owner", snapshot, leaves, graph.unguarded)
    |> should.be_error
    graph.frontier(db, "owner") |> should.equal(Ok([]))
    graph.last_seq(db, "owner") |> should.equal(Ok(0))
    conversation.load_sources(db, "owner") |> should.equal(Ok([a, b, c, d, e]))
    graph.commit_leaves(db, "owner", snapshot, [leaf], graph.unguarded)
    |> should.equal(Ok(True))
    graph.last_seq(db, "owner") |> should.equal(Ok(c.source.seq))
    cleanup(host, session)
  })
}

pub fn personality_ahead_forms_below_overflow_and_holds_newest_unit_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  save(host, "older first task", "first own action")
  save(host, "older second task", "second own action")
  save(host, "newest raw task", "newest raw action")
  let assert Ok([a, b, c, d, e, f]) = conversation.load_sources(db, "owner")
  let calls = process.new_subject()
  let context =
    context_for(db, "owner", policy_for(db, "owner"), fn(request) {
      process.send(calls, request)
      Ok("I remember my earlier action.")
    })
  let assert Ok(strategy) =
    lcm.strategy("personality").resolve(context.capacity, None)
  let assert Some(ahead) = strategy.prepare_ahead
  ahead(context) |> should.equal(Ok(True))
  graph.last_seq(db, "owner") |> should.equal(Ok(b.source.seq))
  let assert Ok(first) = process.receive(calls, 0)
  let assert Some(formed) = first.formation
  list.map(formed.frame.sources, fn(row) { row.seq })
  |> should.equal([a.source.seq, b.source.seq])
  ahead(context) |> should.equal(Ok(True))
  graph.last_seq(db, "owner") |> should.equal(Ok(d.source.seq))
  // Pending parent work is graph progress even though leaf production is held.
  ahead(context) |> should.equal(Ok(True))
  let assert Ok([parent]) = graph.frontier(db, "owner")
  parent.depth |> should.equal(1)
  ahead(context) |> should.equal(Ok(False))
  conversation.load_sources(db, "owner") |> should.equal(Ok([a, b, c, d, e, f]))
  let assert Ok(plain) = lcm.strategy("lcm").resolve(context.capacity, None)
  plain.prepare_ahead |> should.equal(None)
  cleanup(host, session)
}

@external(erlang, "albedo_session_memory_test_support", "count_reads")
fn counted_source_reads(owner: process.Pid, work: fn() -> a) -> #(a, Int, Int)

pub fn one_unit_ahead_reads_only_selected_payloads_and_prefix_lookahead_test() -> Nil {
  list.each([10, 20, 40], fn(units) {
    let #(host, session, _) = setup()
    let db = runtime.ledger(host)
    list.each(list.repeat(Nil, units + 1), fn(_) {
      save(
        host,
        "Completed source unit with retained details",
        "Actual completed action",
      )
    })
    let context =
      context_for(db, "owner", policy_for(db, "owner"), fn(_) {
        Ok("I remember.")
      })
    let assert Ok(strategy) =
      lcm.strategy("personality").resolve(context.capacity, None)
    let assert Some(ahead) = strategy.prepare_ahead
    let #(first, payloads, prefix_rows) =
      counted_source_reads(store.owner(db), fn() { ahead(context) })
    let #(rest, remaining_payloads, remaining_prefix_rows) =
      counted_source_reads(store.owner(db), fn() {
        list.try_each(list.repeat(Nil, units - 1), fn(_) {
          ahead(context) |> result.replace(Nil)
        })
      })
    cleanup(host, session)
    first |> should.equal(Ok(True))
    rest |> should.equal(Ok(Nil))
    payloads |> should.equal(2)
    prefix_rows |> should.equal(3)
    payloads + remaining_payloads |> should.equal(2 * units)
    prefix_rows + remaining_prefix_rows |> should.equal(3 * units)
  })
}

pub fn background_preparation_uses_owned_composition_without_booting_kernel_test() -> Nil {
  let #(host, session, _) = setup()
  save(host, "actual older ask", "actual older own action")
  save(host, "newest unit", "raw newest action")
  selection.record_selected(
    runtime.ledger(host),
    "owner",
    selection.SetSession("lcm-memory", True),
    [],
    runtime.installed(host),
    runtime.installed(host),
  )
  |> should.be_ok
  let assert Ok(cached) = runtime.prepare_composition(host, "owner", "/tmp")
  let seen = process.new_subject()
  runtime.prepare_ahead(
    host,
    "owner",
    cached,
    "model",
    "fixture",
    None,
    fn(request) {
      process.send(seen, request)
      Ok("I remember my action.")
    },
    types.any_images,
    fn() { True },
  )
  |> should.equal(Ok(True))
  let assert Ok(request) = process.receive(seen, 0)
  let assert Some(policy) = request.policy
  policy.lineage.subject
  |> should.equal(policy_for(runtime.ledger(host), "owner").lineage.subject)
  store.query(runtime.ledger(host), link.apply) |> should.be_ok
  let assert Ok(observed) = runtime.observe_loaded(host, "owner")
  observed.kernel |> should.equal(None)
  runtime.loaded_sessions(host) |> should.equal(["owner"])
  cleanup(host, session)
}

pub fn shared_summarizer_keeps_native_usage_when_output_is_unusable_test() -> Nil {
  let #(host, session, _) = setup()
  let seen = process.new_subject()
  let sent = process.new_subject()
  let upstream =
    extension.Upstream(
      "native-test",
      types.Responses,
      fn(request, _) {
        process.send(seen, request)
        Ok(
          types.Turn(
            None,
            [],
            [],
            Some(types.Usage(123, 7, Some(100), None, None, None, Some(2))),
            types.Complete,
            None,
            [],
          ),
        )
      },
      fn(_) { None },
      fn() { Some("verified-account") },
      fn(_) { [] },
      types.any_images,
    )
  let context =
    loop.CallContext(
      runtime.ledger(host),
      upstream,
      "owner",
      "fixture",
      "memory-call",
      Some(fn(call) { process.send(sent, call) }),
    )
  loop.summarize_call(
    context,
    compaction.SummaryRequest(
      "model",
      None,
      [types.User("native source")],
      768,
      "native summary instruction",
      compaction.NoEvidence,
      None,
      None,
    ),
  )
  |> should.equal(Error("summarizer provider returned no text"))
  let assert Ok(request) = process.receive(seen, 0)
  request.tools |> should.equal([])
  request.max_output_tokens |> should.equal(Some(768))
  process.receive(sent, 0) |> should.equal(Error(Nil))
  store.read(
    runtime.ledger(host),
    "SELECT kind,input_tokens,output_tokens,account,seq FROM provider_requests WHERE session='owner'",
    [],
    {
      use kind <- decode.field(0, decode.string)
      use input <- decode.field(1, decode.int)
      use output <- decode.field(2, decode.int)
      use account <- decode.field(3, decode.string)
      use seq <- decode.field(4, decode.optional(decode.int))
      decode.success(#(kind, input, output, account, seq))
    },
  )
  |> should.equal(Ok([#("summarizer", 123, 7, "verified-account", None)]))
  conversation.load_sources(runtime.ledger(host), "owner")
  |> should.equal(Ok([]))
  cleanup(host, session)
}

// Exercise the native Turn boundary and exact graph CAS snapshots without
// racing the daemon's automatic leaf-to-parent progression. The HTTP regression
// covers real wire reducers; these cases also reach inconsistent custom-provider
// Turns that those reducers cannot emit, and failed intermediate reading folds.
fn disposition_turn(protocol: types.Protocol, kind: String) -> types.Turn {
  let text = case kind {
    "empty" -> "  \n "
    _ -> "I remember verified work."
  }
  let refusal = kind == "refusal"
  let item = case protocol {
    types.Responses ->
      json.object([
        #("type", json.string("message")),
        #("role", json.string("assistant")),
        #("status", json.string("completed")),
        #(
          "content",
          json.array(
            list.append(
              [
                json.object([
                  #("type", json.string("output_text")),
                  #("text", json.string(text)),
                ]),
              ],
              case refusal {
                True -> [
                  json.object([
                    #("type", json.string("refusal")),
                    #("refusal", json.string("I cannot supply this memory.")),
                  ]),
                ]
                False -> []
              },
            ),
            fn(value) { value },
          ),
        ),
      ])
    types.ChatCompletions ->
      json.object(
        list.append(
          [
            #("role", json.string("assistant")),
            #("content", json.string(text)),
          ],
          case refusal {
            True -> [#("refusal", json.string("I cannot supply this memory."))]
            False -> []
          },
        ),
      )
  }
  let assert Ok(item) =
    json.parse(json.to_string(item), types.replay_decoder(protocol))
  let output = case protocol, kind {
    types.Responses, "complete_reasoning" -> {
      let assert Ok(reasoning) =
        json.parse(
          "{\"type\":\"reasoning\",\"id\":\"reasoning-fixture\",\"summary\":[],\"status\":\"completed\",\"content\":null}",
          types.replay_decoder(protocol),
        )
      [reasoning, item]
    }
    _, _ -> [item]
  }
  types.Turn(
    None,
    output,
    case kind {
      "tools" | "complete_with_tools" -> [types.ToolCall("call", "read", "{}")]
      _ -> []
    },
    Some(types.Usage(123, 7, Some(100), None, None, None, Some(2))),
    case kind {
      "length" -> types.LengthLimit
      "filter" -> types.ContentFiltered
      "incomplete" -> types.OtherFinish("incomplete")
      "tools" -> types.ToolCalls
      _ -> types.Complete
    },
    None,
    [],
  )
}

fn native_summary(
  db: store.Store,
  protocol: types.Protocol,
  turn: types.Turn,
  request: compaction.SummaryRequest,
) -> Result(String, String) {
  loop.summarize_call(
    loop.CallContext(
      db,
      extension.Upstream(
        "native-disposition-test",
        protocol,
        fn(_, _) { Ok(turn) },
        fn(_) { None },
        fn() { Some("verified-account") },
        fn(_) { [] },
        types.any_images,
      ),
      "owner",
      "fixture",
      "disposition-call",
      None,
    ),
    request,
  )
}

fn assert_disposition_accounting(db: store.Store) -> Nil {
  store.read(
    db,
    "SELECT kind,input_tokens,output_tokens,account,seq FROM provider_requests WHERE session='owner'",
    [],
    {
      use kind <- decode.field(0, decode.string)
      use input <- decode.field(1, decode.int)
      use output <- decode.field(2, decode.int)
      use account <- decode.field(3, decode.string)
      use seq <- decode.field(4, decode.optional(decode.int))
      decode.success(#(kind, input, output, account, seq))
    },
  )
  |> should.equal(Ok([#("summarizer", 123, 7, "verified-account", None)]))
}

fn rejected_dispositions_preserve_graph(
  kinds: List(String),
  parent: Bool,
) -> Nil {
  list.each([types.Responses, types.ChatCompletions], fn(protocol) {
    list.each(kinds, fn(kind) {
      let #(host, session, _) = setup()
      let db = runtime.ledger(host)
      save(host, string.repeat("first source ", 100), "first action")
      save(host, string.repeat("second source ", 100), "second action")
      save(host, "retained tail", "tail action")
      let policy = policy_for(db, "owner")
      let context =
        context_for(db, "owner", policy, fn(_) {
          Ok("I remember verified work.")
        })
      let assert Ok(strategy) =
        lcm.strategy("personality").resolve(context.capacity, None)
      let assert Some(ahead) = strategy.prepare_ahead
      case parent {
        True -> {
          ahead(context) |> should.equal(Ok(True))
          ahead(context) |> should.equal(Ok(True))
        }
        False -> Nil
      }
      let assert Ok(before) = graph.snapshot(db, "owner")
      let assert Ok(frontier) = graph.frontier(db, "owner")
      let assert Ok(rows) = conversation.load_sources(db, "owner")
      let rejected =
        compaction.Context(..context, summarize: native_summary(
          db,
          protocol,
          disposition_turn(protocol, kind),
          _,
        ))
      ahead(rejected) |> should.be_error
      graph.snapshot(db, "owner") |> should.equal(Ok(before))
      graph.frontier(db, "owner") |> should.equal(Ok(frontier))
      conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
      assert_disposition_accounting(db)
      // The same durable sources/frontier remain usable by a complete attempt.
      let accepted =
        compaction.Context(..context, summarize: native_summary(
          db,
          protocol,
          // Completed reasoning items may have null content; their visible
          // assistant answer must still succeed for the retained frontier.
          disposition_turn(protocol, case protocol {
            types.Responses -> "complete_reasoning"
            types.ChatCompletions -> "complete"
          }),
          _,
        ))
      ahead(accepted) |> should.equal(Ok(True))
      graph.snapshot(db, "owner") |> should.not_equal(Ok(before))
      conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
      cleanup(host, session)
    })
  })
}

pub fn incomplete_summary_finishes_preserve_leaf_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(
    ["length", "filter", "incomplete"],
    False,
  )
}

pub fn incomplete_summary_finishes_preserve_parent_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(["length", "filter", "incomplete"], True)
}

pub fn tools_and_refusal_preserve_leaf_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(
    ["tools", "complete_with_tools", "refusal"],
    False,
  )
}

pub fn tools_and_refusal_preserve_parent_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(
    ["tools", "complete_with_tools", "refusal"],
    True,
  )
}

pub fn empty_summary_preserves_leaf_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(["empty"], False)
}

pub fn empty_summary_preserves_parent_frontier_test() -> Nil {
  rejected_dispositions_preserve_graph(["empty"], True)
}

pub fn incomplete_native_reading_and_consolidation_commit_no_partial_leaf_test() -> Nil {
  list.each([types.Responses, types.ChatCompletions], fn(protocol) {
    list.each(["reading", "consolidation"], fn(failed_mode) {
      let #(host, session, _) = setup()
      let db = runtime.ledger(host)
      save(
        host,
        string.repeat("é🧭 actual long source ", 5000),
        "received account",
      )
      save(host, "retained tail", "tail action")
      let assert Ok(before) = graph.snapshot(db, "owner")
      let assert Ok(rows) = conversation.load_sources(db, "owner")
      let calls = process.new_subject()
      process.send(calls, 0)
      let failed =
        prepared_result(
          host,
          session,
          fn(request) {
            let assert Some(formation) = request.formation
            let assert Ok(count) = process.receive(calls, 0)
            process.send(calls, count + 1)
            let reject = formation.mode == failed_mode && count > 0
            native_summary(
              db,
              protocol,
              disposition_turn(protocol, case reject {
                True -> "length"
                False -> "complete"
              }),
              request,
            )
          },
          True,
        )
      failed |> should.be_error
      let assert Ok(count) = process.receive(calls, 0)
      should.be_true(count > 1)
      graph.snapshot(db, "owner") |> should.equal(Ok(before))
      graph.frontier(db, "owner") |> should.equal(Ok([]))
      conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
      cleanup(host, session)
    })
  })
}

pub fn incomplete_native_tool_unit_defers_leaves_but_not_faithful_parent_progress_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  save(host, "first closed ask", "first own action")
  save(host, "second closed ask", "second own action")
  let assert Ok(call) =
    json.parse(
      "{\"type\":\"function_call\",\"call_id\":\"interrupted-native-call\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
      types.replay_decoder(types.Responses),
    )
  conversation.commit_from(
    db,
    "owner",
    [
      types.User("interrupted ask"),
      types.Replay(call),
      types.User("native capability note one"),
      types.User("native capability note two"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([a, b, c, d, _, _, _, _]) =
    conversation.load_sources(db, "owner")
  let policy = policy_for(db, "owner")
  let context =
    context_for(db, "owner", policy, fn(_) {
      Ok("I remember my completed action.")
    })
  let assert Ok(left) = formation.leaves(context, [a, b], 768, policy)
  let assert Ok(right) = formation.leaves(context, [c, d], 768, policy)
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  graph.commit_leaves(
    db,
    "owner",
    snapshot,
    list.append(left, right),
    episodes.guard(policy, "owner"),
  )
  |> should.equal(Ok(True))
  let calls = process.new_subject()
  let context =
    compaction.Context(..context, summarize: fn(request) {
      process.send(calls, request)
      Ok("I remember my completed actions.")
    })
  let assert Ok(strategy) =
    lcm.strategy("personality").resolve(context.capacity, None)
  let assert Some(ahead) = strategy.prepare_ahead
  ahead(context) |> should.equal(Ok(True))
  // Unanswered replay is still raw. The only permitted progress was a parent.
  graph.last_seq(db, "owner") |> should.equal(Ok(d.source.seq))
  let assert Ok([parent]) = graph.frontier(db, "owner")
  parent.depth |> should.equal(1)
  let assert Ok(merged) = process.receive(calls, 0)
  let assert Some(formed) = merged.formation
  formed.mode |> should.equal("consolidation")
  ahead(context) |> should.equal(Ok(False))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  // Native foreground recovery appends and settles the result. It cannot
  // remap any already covered source position because that unit was deferred.
  conversation.commit_from(
    db,
    "owner",
    [
      types.ToolOutput("interrupted-native-call", "native recovered result", []),
      types.User("foreground newest ask"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok(rows) = conversation.load_sources(db, "owner")
  let recovered = list.drop(rows, 4) |> list.take(3)
  list.map(recovered, fn(row) { narration.source_role(row.entry.input) })
  |> should.equal(["user", "assistant", "tool"])
  ahead(context) |> should.equal(Ok(True))
  let assert Ok(last) = list.last(recovered)
  graph.last_seq(db, "owner") |> should.equal(Ok(last.source.seq))
  let assert Ok([_, next]) = graph.frontier(db, "owner")
  let assert Some(frame) = next.frame
  list.map(frame.sources, fn(row) { row.seq })
  |> should.equal(list.map(recovered, fn(row) { row.source.seq }))
  cleanup(host, session)
}

pub fn forced_lcm_cannot_bypass_unresolved_leading_tool_unit_test() -> Nil {
  list.each(["personality", "lcm"], fn(name) {
    let #(host, session, _) = setup()
    let db = runtime.ledger(host)
    let assert Ok(call) =
      json.parse(
        "{\"type\":\"function_call\",\"call_id\":\"interrupted-call\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
        types.replay_decoder(types.Responses),
      )
    conversation.commit_from(
      db,
      "owner",
      [
        types.User("interrupted ask"),
        types.Replay(call),
        types.User("native capability note one"),
        types.User("native capability note two"),
      ],
      conversation.Idle,
      None,
    )
    |> should.be_ok
    let assert Ok(rows) = conversation.load_sources(db, "owner")
    let seen = process.new_subject()
    let context =
      context_for(db, "owner", policy_for(db, "owner"), fn(request) {
        process.send(seen, request)
        Ok("I remember the supplied history.")
      })
    let context = case name {
      "lcm" -> compaction.Context(..context, summary_policy: None)
      _ -> context
    }
    let assert Ok(strategy) = lcm.strategy(name).resolve(context.capacity, None)
    compaction.prepare(
      strategy,
      context,
      list.map(rows, fn(row) { row.entry.input }),
    )
    |> should.be_error
    process.receive(seen, 0) |> should.equal(Error(Nil))
    graph.last_seq(db, "owner") |> should.equal(Ok(0))
    graph.frontier(db, "owner") |> should.equal(Ok([]))
    conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
    cleanup(host, session)
  })
}

pub fn active_prefix_accepts_actual_leading_assistant_tool_continuation_test() -> Nil {
  let #(host, session, _) = setup()
  let db = runtime.ledger(host)
  conversation.commit_from(
    db,
    "owner",
    [types.User("legacy covered ask")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([covered]) = conversation.load_sources(db, "owner")
  graph.save_leaves(db, "owner", [
    graph.Leaf(covered.source.seq, covered.source.seq, "legacy fold", None),
  ])
  |> should.be_ok
  conversation.commit_from(
    db,
    "owner",
    [
      types.Assistant("actual continuation"),
      types.ToolOutput("retained-native-answer", "actual answer", []),
      types.User("newest"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([_, assistant, tool, newest]) =
    conversation.load_sources(db, "owner")
  let policy = policy_for(db, "owner")
  let context =
    context_for(db, "owner", policy, fn(_) {
      Ok("I remember the continuation.")
    })
  let assert Ok(leaves) =
    formation.leaves(context, [assistant, tool], 768, policy)
  let assert Ok(snapshot) = graph.snapshot(db, "owner")
  let assert Ok(source_snapshot) = conversation.snapshot(db, "owner")
  conversation.first_source_unit(db, source_snapshot, covered.source.seq)
  |> should.equal(Ok(Some(#(assistant.source.seq, newest.source.seq - 1))))
  graph.commit_leaves(
    db,
    "owner",
    snapshot,
    leaves,
    episodes.guard(policy, "owner"),
  )
  |> should.equal(Ok(True))
  graph.last_seq(db, "owner") |> should.equal(Ok(tool.source.seq))
  conversation.load_sources(db, "owner")
  |> should.equal(Ok([covered, assistant, tool, newest]))
  cleanup(host, session)
}

pub fn forced_lcm_can_condense_valid_frontier_while_leading_raw_unit_is_unresolved_test() -> Nil {
  list.each(["personality", "lcm"], fn(name) {
    let #(host, session, _) = setup()
    let db = runtime.ledger(host)
    save(host, "first completed ask", "first actual action")
    save(host, "second completed ask", "second actual action")
    let assert Ok(call) =
      json.parse(
        "{\"type\":\"function_call\",\"call_id\":\"pending\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
        types.replay_decoder(types.Responses),
      )
    conversation.commit_from(
      db,
      "owner",
      [
        types.User("interrupted ask"),
        types.Replay(call),
        types.User("later note"),
        types.User("newest note"),
      ],
      conversation.Idle,
      None,
    )
    |> should.be_ok
    let assert Ok(rows) = conversation.load_sources(db, "owner")
    let assert [a, b, c, d, ..] = rows
    // An existing oversized generic frontier can still be condensed without
    // consuming or skipping the first unresolved raw source unit.
    graph.save_leaves(db, "owner", [
      graph.Leaf(
        a.source.seq,
        b.source.seq,
        string.repeat("retained detail ", 5000),
        None,
      ),
      graph.Leaf(
        c.source.seq,
        d.source.seq,
        string.repeat("retained detail ", 5000),
        None,
      ),
    ])
    |> should.be_ok
    let calls = process.new_subject()
    let context =
      context_for(db, "owner", policy_for(db, "owner"), fn(request) {
        process.send(calls, request)
        Ok("Completed earlier actions.")
      })
    let context = case name {
      "lcm" -> compaction.Context(..context, summary_policy: None)
      _ -> context
    }
    let assert Ok(strategy) = lcm.strategy(name).resolve(context.capacity, None)
    compaction.prepare(
      strategy,
      context,
      list.map(rows, fn(row) { row.entry.input }),
    )
    |> should.be_ok
    let assert Ok([parent]) = graph.frontier(db, "owner")
    parent.depth |> should.equal(1)
    graph.last_seq(db, "owner") |> should.equal(Ok(d.source.seq))
    process.receive(calls, 0) |> should.be_ok
    conversation.load_sources(db, "owner") |> should.equal(Ok(rows))
    cleanup(host, session)
  })
}
