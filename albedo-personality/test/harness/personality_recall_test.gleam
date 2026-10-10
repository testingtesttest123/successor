//// Bounded selection and snapshot invariants through real stores/native tools.
//// Socket-free adapters cover deterministic ranking and small/unknown windows
//// while the restricted executor cannot boot the Python AF_UNIX kernel.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/projection
import albedo/harness/extensions/personality/recall
import albedo/harness/extensions/personality/sources
import albedo/harness/extensions/personality/tools
import albedo/harness/extensions/personality/types as p
import albedo/harness/extensions/python/kernel
import albedo/harness/request_context
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import sqlight

fn setup() -> #(store.Store, Int) {
  let assert Ok(db) = store.start(":memory:", "")
  conversation.initialise(db) |> should.be_ok
  family.initialise(db) |> should.be_ok
  ledger.initialise(db) |> should.be_ok
  session_requirements.initialise(db) |> should.be_ok
  conversation.create(
    db,
    conversation.Info(
      "owner",
      "recall",
      "/tmp",
      "provider",
      "model",
      types.Responses,
      conversation.Idle,
      None,
      None,
    ),
  )
  |> should.be_ok
  let assert Ok(persona) =
    ledger.create(db, p.Creation("create", "recall owner", False, True, True))
  ledger.bind(db, "owner", p.Bind("bind", persona.id, 0, 0)) |> should.be_ok
  conversation.commit_from(
    db,
    "owner",
    [types.User("Source assertion")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok(seq) = conversation.last_seq(db, "owner")
  #(db, seq)
}

fn change(seq: Int, text: String, tags: List(String)) -> p.MemoryChange {
  p.MemoryChange(
    "",
    0,
    "remember",
    text,
    "experienced",
    "unverified",
    1,
    tags,
    "",
    [
      p.Evidence(
        "supports",
        p.SourceRef("", "", seq, seq, "", [], "", 0, 0, None, ""),
      ),
    ],
  )
}

fn edit(
  db: store.Store,
  op: String,
  changes: List(p.MemoryChange),
) -> p.Receipt {
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let assert Ok(receipt) =
    domain.mutate(
      db,
      "owner",
      p.User,
      p.Mutation(
        op,
        snapshot.persona.revision,
        snapshot.persona.identity_revision,
        [],
        "deliberate source-backed recall fixture",
        None,
        changes,
      ),
    )
  receipt
}

fn prepared(
  db: store.Store,
  query: String,
  remaining: Option(Int),
) -> request_context.Contribution {
  let assert Ok(value) =
    projection.prepare(request_context.Input(
      db,
      "owner",
      ["personality"],
      query,
      request_context.Budget(remaining, None, 0, remaining),
    ))
  value
}

pub fn recall_is_bounded_stable_and_correction_aware_test() -> Nil {
  let #(db, seq) = setup()
  list.repeat(Nil, 10)
  |> list.index_map(fn(_, batch) {
    edit(
      db,
      "batch-" <> int.to_string(batch),
      list.repeat(Nil, 30)
        |> list.index_map(fn(_, index) {
          change(
            seq,
            "needle candidate " <> int.to_string(batch * 30 + index),
            [],
          )
        }),
    )
  })
  let corrected =
    edit(db, "old-exact-match", [change(seq, "needle obsolete", ["pinned"])])
  let assert [#(corrected_id, _)] = corrected.records
  edit(db, "correction", [
    p.MemoryChange(
      ..change(seq, "replacement without old term", ["pinned"]),
      id: corrected_id,
      expected_revision: 1,
      action: "correct",
    ),
  ])
  let unresolved =
    edit(db, "contradiction", [change(seq, "needle disputed", ["pinned"])])
  let assert [#(unresolved_id, _)] = unresolved.records
  edit(db, "mark-unresolved", [
    p.MemoryChange(
      ..change(seq, "needle new disputed assertion", ["pinned"]),
      id: unresolved_id,
      expected_revision: 1,
      action: "contradict",
      sources: [
        p.Evidence(
          "contradicts",
          p.SourceRef("", "", seq, seq, "", [], "", 0, 0, None, ""),
        ),
      ],
    ),
  ])
  edit(db, "large-multibyte", [
    change(seq, string.repeat("🧭", 1024), ["pinned"]),
  ])
  let first = prepared(db, "needle", None)
  first.candidate_count |> should.equal(256)
  should.be_true(list.length(first.selected_ids) <= 16)
  should.be_true(list.contains(first.selected_ids, corrected_id))
  should.be_true(list.contains(first.selected_ids, unresolved_id))
  should.be_true(first.excluded_count > 0)
  first |> should.equal(prepared(db, "needle", None))
  let rendered =
    list.map(first.data, fn(block) {
      request_context.render(first.snapshot_id, block)
    })
    |> string.concat
  should.be_true(string.byte_size(rendered) <= 8192)
  should.be_false(string.contains(rendered, "needle obsolete"))
  should.be_true(string.contains(rendered, "unresolved"))
  should.be_true(string.contains(rendered, "contradicts"))
  let assert Ok(history) = conversation.load(db, "owner")
  history |> should.equal([types.User("Source assertion")])
  Nil
}

pub fn unknown_and_small_windows_drop_whole_records_and_keep_identity_failure_test() -> Nil {
  let #(db, seq) = setup()
  let _ =
    edit(db, "unicode", [change(seq, string.repeat("é", 2000), ["pinned"])])
  let unknown = prepared(db, "", None)
  unknown.selected_ids |> list.length |> should.equal(1)
  let small = prepared(db, "", Some(400))
  small.selected_ids |> should.equal([])
  small.excluded_count |> should.equal(1)
  let assert Ok(projected) =
    request_context.prepare(
      [projection.prepare],
      request_context.Input(
        db,
        "owner",
        ["personality"],
        "",
        request_context.Budget(Some(400), None, 0, Some(400)),
      ),
    )
  should.be_true(projected.estimated_tokens < 400)
  request_context.prepare(
    [projection.prepare],
    request_context.Input(
      db,
      "owner",
      ["personality"],
      "",
      request_context.Budget(Some(20), None, 0, Some(20)),
    ),
  )
  |> should.be_error
  projection.prepare(request_context.Input(
    db,
    "owner",
    ["personality"],
    string.repeat("🧭", 1025),
    request_context.Budget(None, None, 0, None),
  ))
  |> should.be_error
  Nil
}

pub fn native_recall_rejects_foreign_scope_and_query_cursor_tampering_test() -> Nil {
  let #(db, seq) = setup()
  let _ =
    edit(db, "paged", [
      change(seq, "needle one", []),
      change(seq, "needle two", []),
    ])
  let assert Ok(page) =
    invoke_recall(db, json.object([#("query", json.string("needle"))]))
  let assert Ok(Some(cursor)) =
    json.parse(
      page.text,
      decode.field(
        "next_cursor",
        decode.optional(decode.string),
        decode.success,
      ),
    )
  let assert Ok(denied) =
    invoke_recall(
      db,
      json.object([
        #("query", json.string("needle")),
        #("session", json.string("foreign")),
      ]),
    )
  should.be_true(string.contains(denied.text, "invalid_request"))
  let assert Ok(tampered) =
    invoke_recall(
      db,
      json.object([
        #("query", json.string("another")),
        #("cursor", json.string(cursor)),
      ]),
    )
  should.be_true(string.contains(tampered.text, "conflict"))
}

pub fn lowercase_matching_is_consistent_for_non_ascii_current_claims_test() -> Nil {
  let #(db, seq) = setup()
  let _ = edit(db, "unicode-case", [change(seq, "ÉCLAIR", [])])
  let assert Ok(page) =
    invoke_recall(db, json.object([#("query", json.string("éclair"))]))
  let assert Ok(records) =
    json.parse(
      page.text,
      decode.field("records", decode.list(decode.dynamic), decode.success),
    )
  list.length(records) |> should.equal(1)
}

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

fn invoke_recall(
  db: store.Store,
  body: json.Json,
) -> Result(extension.Output, extension.Failure) {
  let assert Ok(tool) =
    list.find(tools.tools(), fn(tool) {
      tool.definition.name == "persona_recall"
    })
  extension.invoke(
    tool,
    extension.Context(
      db,
      "owner",
      unused_kernel(),
      "recall",
      "/tmp",
      types.any_images,
    ),
    json.to_string(body),
  )
}

pub fn episodic_recall_pages_authorized_older_summary_and_expands_exact_sources_test() -> Nil {
  let #(db, _) = setup()
  graph.initialise(db) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let old_seq =
    older_summary(
      db,
      "older",
      "needle authorized derived summary " <> string.repeat("🧭", 300),
    )
  ledger.bind(
    db,
    "older",
    p.Bind("bind-older", snapshot.persona.id, 0, old_seq),
  )
  |> should.be_ok
  let _ = older_summary(db, "foreign", "needle private unrelated summary")
  let assert Ok(page) =
    invoke_recall(
      db,
      json.object([
        #("view", json.string("episodes")),
        #("query", json.string("needle")),
      ]),
    )
  let assert Ok(records) =
    json.parse(
      page.text,
      decode.field(
        "records",
        decode.list({
          use session <- decode.field(
            "source",
            decode.field("session", decode.string, decode.success),
          )
          use id <- decode.field(
            "source",
            decode.field("id", decode.string, decode.success),
          )
          use first <- decode.field(
            "source",
            decode.field("first_seq", decode.int, decode.success),
          )
          use last <- decode.field(
            "source",
            decode.field("last_seq", decode.int, decode.success),
          )
          decode.success(#(session, id, first, last))
        }),
        decode.success,
      ),
    )
  let assert [record] = records
  record.0 |> should.equal("older")
  record.2 |> should.equal(old_seq)
  record.3 |> should.equal(old_seq)
  should.be_true(string.byte_size(page.text) <= 8192)
  let assert Ok(Some(cursor)) =
    json.parse(
      page.text,
      decode.field(
        "next_cursor",
        decode.optional(decode.string),
        decode.success,
      ),
    )
  let assert Ok(next) =
    invoke_recall(
      db,
      json.object([
        #("view", json.string("episodes")),
        #("query", json.string("needle")),
        #("cursor", json.string(cursor)),
      ]),
    )
  should.be_false(string.contains(next.text, "private unrelated"))
  let assert Ok(tool) =
    list.find(tools.tools(), fn(tool) {
      tool.definition.name == "persona_source"
    })
  let assert Ok(expanded) =
    extension.invoke(
      tool,
      extension.Context(
        db,
        "owner",
        unused_kernel(),
        "expand-episode",
        "/tmp",
        types.any_images,
      ),
      json.to_string(json.object([#("source_id", json.string(record.1))])),
    )
  should.be_true(string.contains(expanded.text, "canonical older evidence"))
  let assert Ok(tampered) =
    invoke_recall(
      db,
      json.object([
        #("view", json.string("episodes")),
        #("query", json.string("another")),
        #("cursor", json.string(cursor)),
      ]),
    )
  should.be_true(string.contains(tampered.text, "conflict"))
}

fn older_summary(db: store.Store, id: String, summary: String) -> Int {
  conversation.create(
    db,
    conversation.Info(
      id,
      "episodic",
      "/tmp",
      "provider",
      "model",
      types.Responses,
      conversation.Idle,
      None,
      None,
    ),
  )
  |> should.be_ok
  conversation.commit_from(
    db,
    id,
    [types.User("canonical older evidence")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok(seq) = conversation.last_seq(db, id)
  graph.save_leaves(db, id, [graph.Leaf(seq, seq, summary)]) |> should.be_ok
  seq
}

pub fn old_related_unresolved_head_has_reserved_candidate_room_test() -> Nil {
  let #(db, seq) = setup()
  let disputed =
    edit(db, "old-dispute", [change(seq, "old uncertain assertion", [])])
  let assert [#(disputed_id, _)] = disputed.records
  let _ =
    edit(db, "old-unresolved", [
      p.MemoryChange(
        ..change(seq, "old disputed current assertion", []),
        id: disputed_id,
        expected_revision: 1,
        action: "contradict",
      ),
    ])
  let pinned = edit(db, "related-pin", [change(seq, "anchor", ["pinned"])])
  let assert [#(pinned_id, _)] = pinned.records
  list.repeat(Nil, 10)
  |> list.index_map(fn(_, batch) {
    edit(
      db,
      "newer-" <> int.to_string(batch),
      list.repeat(change(seq, "recent optional", []), 30),
    )
  })
  let chosen = prepared(db, "", None)
  should.be_true(list.contains(chosen.selected_ids, pinned_id))
  should.be_true(list.contains(chosen.selected_ids, disputed_id))
}

pub fn typed_ranking_is_stable_and_commitment_relevance_is_not_inferred_from_tags_test() -> Nil {
  let #(db, seq) = setup()
  let _ = edit(db, "ranking-base", [change(seq, "needle", ["open"])])
  let assert Ok(snapshot) = ledger.capture(db, "owner", "needle")
  let assert [base] = snapshot.candidates
  base.open_commitment |> should.equal(False)
  base.due |> should.equal(False)
  let alpha =
    p.Record(..base, memory: p.Memory(..base.memory, id: "alpha", event_id: 1))
  let beta = p.Record(..alpha, memory: p.Memory(..alpha.memory, id: "beta"))
  let open =
    p.Record(
      ..alpha,
      memory: p.Memory(..alpha.memory, id: "open"),
      open_commitment: True,
    )
  let due =
    p.Record(..open, memory: p.Memory(..open.memory, id: "due"), due: True)
  let high =
    p.Record(..beta, memory: p.Memory(..beta.memory, id: "high", importance: 3))
  let pinned =
    p.Record(
      ..beta,
      pinned: True,
      memory: p.Memory(..beta.memory, id: "pin", text: "unmatched"),
    )
  let rows = [beta, alpha, open, due, high, pinned]
  let snapshot = p.Snapshot(..snapshot, candidates: rows, eligible_count: 6)
  let first =
    recall.select(
      snapshot,
      "needle",
      request_context.Budget(None, None, 0, None),
    )
  list.map(first.records, fn(record) { record.memory.id })
  |> should.equal(["pin", "high", "due", "open", "alpha", "beta"])
  recall.select(
    p.Snapshot(..snapshot, candidates: list.reverse(rows)),
    "needle",
    request_context.Budget(None, None, 0, None),
  )
  |> should.equal(first)
}

pub fn captured_recall_heads_remain_immutable_after_a_later_correction_test() -> Nil {
  let #(db, seq) = setup()
  let receipt =
    edit(db, "capture-old", [change(seq, "old assertion", ["pinned"])])
  let assert [#(id, _)] = receipt.records
  let assert Ok(captured) = ledger.capture(db, "owner", "old")
  let before =
    recall.select(captured, "old", request_context.Budget(None, None, 0, None))
  let _ =
    edit(db, "capture-new", [
      p.MemoryChange(
        ..change(seq, "corrected assertion", ["pinned"]),
        id: id,
        expected_revision: 1,
        action: "correct",
      ),
    ])
  recall.select(captured, "old", request_context.Budget(None, None, 0, None))
  |> should.equal(before)
  let assert Ok(current) = ledger.capture(db, "owner", "old")
  let chosen =
    recall.select(current, "old", request_context.Budget(None, None, 0, None))
  let assert [record] = chosen.records
  record.memory.revision |> should.equal(2)
  record.memory.text |> should.equal("corrected assertion")
  list.all(record.memory.sources, fn(link) {
    link.relation == "supports" || link.relation == "corrects"
  })
  |> should.be_true
}

pub fn excluded_contradiction_cannot_be_silently_lost_from_a_selected_group_test() -> Nil {
  let #(db, seq) = setup()
  let _ = edit(db, "incomplete-base", [change(seq, "claim", ["pinned"])])
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let assert [base] = snapshot.candidates
  let omitted =
    p.Record(..base, related_unresolved_ids: ["outside-candidate-bound"])
  recall.select(
    p.Snapshot(..snapshot, candidates: [omitted]),
    "",
    request_context.Budget(None, None, 0, None),
  ).records
  |> should.equal([])
}

pub fn episodic_search_lowercases_unicode_without_scanning_whole_summary_history_test() -> Nil {
  let #(db, _) = setup()
  graph.initialise(db) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let seq = older_summary(db, "unicode-episode", "ÉCLAIR derived evidence")
  ledger.bind(
    db,
    "unicode-episode",
    p.Bind("bind-unicode-episode", snapshot.persona.id, 0, seq),
  )
  |> should.be_ok
  let assert Ok(answer) =
    invoke_recall(
      db,
      json.object([
        #("view", json.string("episodes")),
        #("query", json.string("éclair")),
      ]),
    )
  let assert Ok(records) =
    json.parse(
      answer.text,
      decode.field("records", decode.list(decode.dynamic), decode.success),
    )
  list.length(records) |> should.equal(1)
}

pub fn escaped_record_labels_are_counted_before_whole_record_admission_test() -> Nil {
  let #(db, seq) = setup()
  let tags =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, index) {
      string.repeat("\"", 120) <> int.to_string(index)
    })
  let receipt =
    edit(db, "oversized-labels", [change(seq, string.repeat("🧭", 1024), tags)])
  let assert [#(id, _)] = receipt.records
  let selected = prepared(db, "", None)
  selected.selected_ids |> should.equal([])
  selected.excluded_count |> should.equal(1)
  let assert Ok(page) = ledger.memories(db, "owner", id, False, None)
  let assert [record] = page.records
  should.be_true(string.byte_size(record.text) > 0)
  // The current head is retained in storage and can be explicitly inspected.
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let assert [captured] = snapshot.candidates
  captured.memory.text |> should.equal(string.repeat("🧭", 1024))
}

pub fn inspector_reports_selection_reasons_and_complete_exclusion_counts_test() -> Nil {
  let #(db, seq) = setup()
  let _ = edit(db, "inspect-selected", [change(seq, "needle", ["pinned"])])
  let contribution = prepared(db, "needle", None)
  let encoded =
    context_snapshot.request_context_json(request_context.Prepared(
      [contribution],
      0,
      [],
      0,
    ))
    |> json.to_string
  let assert Ok([diagnostics]) =
    json.parse(
      encoded,
      decode.list({
        use ids <- decode.field("selected_ids", decode.list(decode.string))
        use candidates <- decode.field("candidate_count", decode.int)
        use excluded <- decode.field("excluded_count", decode.int)
        use diagnostics <- decode.field(
          "diagnostics",
          decode.list(decode.string),
        )
        decode.success(#(ids, candidates, excluded, diagnostics))
      }),
    )
  diagnostics.0 |> should.equal(contribution.selected_ids)
  diagnostics.1 |> should.equal(1)
  diagnostics.2 |> should.equal(0)
  list.length(diagnostics.3) |> should.equal(1)
  should.be_true(string.contains(string.concat(diagnostics.3), "pinned"))
  should.be_true(string.contains(string.concat(diagnostics.3), "query_match"))
}

pub fn uncurated_episode_source_survives_hint_loss_and_refuses_changed_or_missing_raw_test() -> Nil {
  let #(db, _) = setup()
  graph.initialise(db) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let seq = older_summary(db, "older-fallback", "needle derived")
  ledger.bind(
    db,
    "older-fallback",
    p.Bind("fallback-bind", snapshot.persona.id, 0, seq),
  )
  |> should.be_ok
  let assert Ok(before) = ledger.capture(db, "owner", "")
  let assert Ok(page) = recall.episodes(db, "owner", "needle", None)
  let assert [episode] = page.records
  let id = episode.source.id
  should.be_true(string.byte_size(id) <= 128)
  store.write(db, "DELETE FROM lcm_compaction_node WHERE session=?", [
    sqlight.text("older-fallback"),
  ])
  |> should.be_ok
  let assert Ok(expanded) = sources.expand(db, "owner", id, None)
  should.be_true(string.contains(expanded.text, "canonical older evidence"))
  expanded.source.digest |> should.equal(episode.source.digest)
  expanded.source.origin |> should.equal(episode.source.origin)
  expanded.source.binding_revision
  |> should.equal(episode.source.binding_revision)
  expanded.source.pre_binding_through
  |> should.equal(episode.source.pre_binding_through)
  expanded.source.lcm_hint |> should.equal(None)
  let assert Ok(tool) =
    list.find(tools.tools(), fn(tool) {
      tool.definition.name == "persona_source"
    })
  let assert Ok(native) =
    extension.invoke(
      tool,
      extension.Context(
        db,
        "owner",
        unused_kernel(),
        "fallback-expand",
        "/tmp",
        types.any_images,
      ),
      json.to_string(json.object([#("source_id", json.string(id))])),
    )
  should.be_true(string.contains(native.text, "canonical older evidence"))
  let assert Ok(after) = ledger.capture(db, "owner", "")
  after.persona |> should.equal(before.persona)
  after.eligible_count |> should.equal(0)
  sources.expand(db, "unbound", id, None) |> should.be_error
  let foreign_seq = older_summary(db, "foreign-owner", "private unrelated")
  let assert Ok(foreign) =
    ledger.create(
      db,
      p.Creation("foreign-persona", "foreign", False, True, True),
    )
  ledger.bind(
    db,
    "foreign-owner",
    p.Bind("bind-foreign", foreign.id, 0, foreign_seq),
  )
  |> should.be_ok
  let assert Error(p.Forbidden(_)) =
    sources.expand(db, "foreign-owner", id, None)
  ledger.bind(
    db,
    "older-fallback",
    p.Bind("revoke-source-owner", foreign.id, 1, seq),
  )
  |> should.be_ok
  let assert Error(p.Forbidden(_)) = sources.expand(db, "owner", id, None)
  ledger.bind(
    db,
    "older-fallback",
    p.Bind("restore-source-owner", snapshot.persona.id, 2, seq),
  )
  |> should.be_ok
  sources.expand(db, "owner", id, None) |> should.be_ok
  conversation.commit_from(
    db,
    "older-fallback",
    [types.User("altered raw evidence")],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok(other) = conversation.last_seq(db, "older-fallback")
  store.write(
    db,
    "UPDATE transcript SET payload=(SELECT payload FROM transcript WHERE seq=?) WHERE seq=?",
    [sqlight.int(other), sqlight.int(seq)],
  )
  |> should.be_ok
  let assert Error(p.SourceUnavailable(_)) =
    sources.expand(db, "owner", id, None)
  store.write(db, "DELETE FROM transcript WHERE seq=?", [sqlight.int(seq)])
  |> should.be_ok
  let assert Error(p.SourceUnavailable(_)) =
    sources.expand(db, "owner", id, None)
  Nil
}

// Change trusted cursor fields while retaining the original signature, if any.
// The same regression exercises the unsigned pre-fix format for the red run.
fn changed_cursor(cursor: String, index: Int, value: String) -> String {
  let #(payload, state, signature) = case string.split(cursor, ".") {
    [encoded, signature] -> {
      let assert Ok(bytes) = bit_array.base64_url_decode(encoded)
      let assert Ok(payload) = bit_array.to_string(bytes)
      let assert Ok(state) =
        json.parse(
          payload,
          decode.field("state", decode.string, decode.success),
        )
      #(payload, state, Some(signature))
    }
    _ -> #(cursor, cursor, None)
  }
  let assert Ok(parts) = json.parse(state, decode.list(decode.string))
  let changed =
    list.index_map(parts, fn(part, at) {
      case at == index {
        True -> value
        False -> part
      }
    })
    |> json.array(json.string)
    |> json.to_string
  case signature {
    None -> changed
    Some(signature) ->
      string.replace(
        payload,
        json.to_string(json.string(state)),
        json.to_string(json.string(changed)),
      )
      |> bit_array.from_string
      |> bit_array.base64_url_encode(False)
      |> string.append("." <> signature)
  }
}

pub fn episode_continuation_authenticates_all_positions_and_preserves_insert_snapshot_test() -> Nil {
  let #(db, owner_seq) = setup()
  graph.initialise(db) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let seq =
    older_summary(db, "cursor-older", "needle " <> string.repeat("x", 300))
  ledger.bind(
    db,
    "cursor-older",
    p.Bind("cursor-bind", snapshot.persona.id, 0, seq),
  )
  |> should.be_ok
  let assert Ok(page) = recall.episodes(db, "owner", "needle", None)
  let assert Some(cursor) = page.next
  graph.save_leaves(db, "cursor-older", [
    graph.Leaf(seq, seq, "new unrelated summary"),
  ])
  |> should.be_ok
  let assert Ok(next) = recall.episodes(db, "owner", "needle", Some(cursor))
  let assert [episode] = next.records
  episode.scalar_offset |> should.equal(128)
  should.be_false(string.contains(episode.summary, "unrelated"))
  // Scope, captured upper bound, node, scalar offset and matched flag are all covered.
  [
    #(1, "999999"),
    #(2, "999999"),
    #(3, "0"),
    #(4, "searching"),
    #(0, "foreign-scope"),
  ]
  |> list.each(fn(change) {
    let assert Ok(rejected) =
      invoke_recall(
        db,
        json.object([
          #("view", json.string("episodes")),
          #("query", json.string("needle")),
          #("cursor", json.string(changed_cursor(cursor, change.0, change.1))),
        ]),
      )
    should.be_true(string.contains(rejected.text, "invalid"))
  })
  let assert Ok([later]) =
    store.read(
      db,
      "SELECT MAX(id) FROM lcm_compaction_node",
      [],
      decode.field(0, decode.int, decode.success),
    )
  let combined =
    cursor
    |> changed_cursor(1, int.to_string(later))
    |> changed_cursor(2, int.to_string(later))
    |> changed_cursor(3, "0")
    |> changed_cursor(4, "matched")
  recall.episodes(db, "owner", "needle", Some(combined)) |> should.be_error
  recall.episodes(db, "owner", "different", Some(cursor)) |> should.be_error
  recall.episodes(db, "cursor-older", "needle", Some(cursor)) |> should.be_error
  let _ = edit(db, "change-head", [change(owner_seq, "head changes", [])])
  recall.episodes(db, "owner", "needle", Some(cursor)) |> should.be_error
  Nil
}

pub fn read_signing_state_loss_or_corruption_fails_closed_without_regeneration_test() -> Nil {
  [
    "DELETE FROM personality_read_key",
    "UPDATE personality_read_key SET secret='invalid'",
    "UPDATE personality_read_key SET secret=hex(randomblob(32))",
    "DROP TABLE personality_read_key",
  ]
  |> list.each(fn(damage) {
    let #(db, _) = setup()
    graph.initialise(db) |> should.be_ok
    store.write(db, damage, []) |> should.be_ok
    ledger.initialise(db) |> should.be_error
    recall.episodes(db, "owner", "", None) |> should.be_error
  })
}

pub fn episodic_source_id_preserves_maximum_sqlite_ranges_inside_existing_id_limit_test() -> Nil {
  let #(db, owner_seq) = setup()
  graph.initialise(db) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let _ = older_summary(db, "largest-source", "old summary")
  let maximum = 9_223_372_036_854_775_807
  store.write(db, "DELETE FROM lcm_compaction_node WHERE session=?", [
    sqlight.text("largest-source"),
  ])
  |> should.be_ok
  store.write(
    db,
    "INSERT INTO transcript(seq,session,payload) SELECT ?,'largest-source',payload FROM transcript WHERE seq=?",
    [sqlight.int(maximum), sqlight.int(owner_seq)],
  )
  |> should.be_ok
  graph.save_leaves(db, "largest-source", [
    graph.Leaf(maximum, maximum, "boundary summary"),
  ])
  |> should.be_ok
  ledger.bind(
    db,
    "largest-source",
    p.Bind("bind-largest", snapshot.persona.id, 0, maximum),
  )
  |> should.be_ok
  store.write(
    db,
    "UPDATE personality_session SET binding_revision=? WHERE session=?",
    [sqlight.int(maximum), sqlight.text("largest-source")],
  )
  |> should.be_ok
  let assert Ok(page) = recall.episodes(db, "owner", "", None)
  let assert [episode] = page.records
  string.byte_size(episode.source.id) |> should.equal(127)
  store.write(db, "DELETE FROM lcm_compaction_node WHERE session=?", [
    sqlight.text("largest-source"),
  ])
  |> should.be_ok
  let assert Ok(raw) = sources.expand(db, "owner", episode.source.id, None)
  raw.source.first_seq |> should.equal(maximum)
  raw.source.last_seq |> should.equal(maximum)
  raw.source.binding_revision |> should.equal(maximum)
  raw.source.pre_binding_through |> should.equal(maximum)
}
