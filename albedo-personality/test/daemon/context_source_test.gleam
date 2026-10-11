//// Indexed costs must equal complete native units; per-row Chat costs overcount coalesced replay.
//// Metadata reads and same-MAX rewrites cannot be observed reliably through HTTP E2E.

import albedo/context_cost
import albedo/daemon/context_source
import albedo/daemon/conversation
import albedo/daemon/image_fit
import albedo/daemon/images
import albedo/daemon/projection
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import sqlight

@external(erlang, "albedo_lcm_preparation_test_support", "count_decodes")
fn count_decodes(owner: process.Pid, run: fn() -> a) -> #(a, Int)

fn started() -> #(runtime.Runtime, store.Store) {
  let assert Ok(host) = runtime.start(":memory:")
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "source",
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
  #(host, ledger)
}

fn profile(
  provider: String,
  protocol: types.Protocol,
) -> context_cost.CostProfile {
  context_cost.CostProfile(
    provider,
    protocol,
    "model",
    types.any_images,
    None,
    "identity-1",
  )
}

fn inventory(
  ledger: store.Store,
  profile: context_cost.CostProfile,
) -> Result(List(context_source.SourceUnit), String) {
  store.query(ledger, fn(db) {
    let assert Ok(scope) = context_source.bound_in(db, "source")
    context_source.inventory_in(db, scope, profile)
  })
}

fn replay(raw: String) -> types.Input {
  let assert Ok(item) = json.parse(raw, types.replay_decoder(types.Responses))
  types.Replay(item)
}

pub fn moving_source_row_invalidates_and_repairs_both_session_units_test() -> Nil {
  list.each([1, 2], check_source_move)
}

fn check_source_move(position: Int) -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "destination",
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
      "source",
      [types.User("u"), types.Assistant("answer"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok([before, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.run(
        db,
        "UPDATE transcript SET session='destination' WHERE session='source' AND seq=?",
        [sqlight.int(position)],
      )
    })
  inventory(ledger, profile("provider", types.Responses)) |> should.be_error
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      use _ <- result.try(context_source.reindex_in(db, "source"))
      context_source.reindex_in(db, "destination")
    })
  let assert Ok([after, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let #(remaining, transferred) = case position {
    1 -> #(types.Assistant("answer"), types.User("u"))
    _ -> #(types.User("u"), types.Assistant("answer"))
  }
  should.equal(after.tokens, context_cost.estimate_input(remaining))
  should.be_true(after.content_identity != before.content_identity)
  let assert Ok([moved]) =
    store.query(ledger, fn(db) {
      let assert Ok(scope) = context_source.bound_in(db, "destination")
      context_source.inventory_in(
        db,
        scope,
        profile("provider", types.Responses),
      )
    })
  should.equal(moved.tokens, context_cost.estimate_input(transferred))
  runtime.stop(host)
}

pub fn batch_ingestion_refreshes_each_affected_unit_once_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE TABLE cost_refreshes(n INTEGER); CREATE TRIGGER count_cost_refreshes AFTER DELETE ON context_source_unit_cost BEGIN INSERT INTO cost_refreshes VALUES(1); END",
      )
    })
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("large unit"), ..list.repeat(types.Assistant("status"), 300)],
      conversation.Idle,
    )
  let assert Ok([refreshes]) =
    store.read(
      ledger,
      "SELECT COUNT(*) FROM cost_refreshes",
      [],
      decode.field(0, decode.int, decode.success),
    )
  should.be_true(refreshes <= 3)
  let assert Ok(entries) = conversation.load_entries(ledger, "source")
  let assert Ok(inputs) =
    projection.for_model(entries, "provider", types.Responses)
  let assert Ok([unit]) =
    inventory(ledger, profile("provider", types.Responses))
  should.equal(unit.tokens, context_cost.estimate_inputs(inputs))
  runtime.stop(host)
}

pub fn ingestion_indexes_complete_source_units_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "source",
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
      "source",
      [
        types.Assistant("leading continuation"),
        types.User("first"),
        types.Assistant("answer"),
        types.User("tail"),
      ],
      conversation.Idle,
    )
  let assert Ok(rows) =
    store.read(
      ledger,
      "SELECT first_seq,last_seq,total_utf16,external_utf16 FROM context_source_unit WHERE session=? ORDER BY first_seq",
      [sqlight.text("source")],
      {
        use first <- decode.field(0, decode.int)
        use last <- decode.field(1, decode.int)
        use total <- decode.field(2, decode.int)
        use external <- decode.field(3, decode.int)
        decode.success(#(first, last, total, external))
      },
    )
  rows |> should.equal([#(1, 1, 20, 0), #(2, 3, 11, 0), #(4, 4, 4, 0)])
  runtime.stop(host)
}

pub fn metadata_costs_equal_native_whole_unit_projection_on_both_protocols_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.User("u"),
        replay(
          "{\"type\":\"message\",\"id\":\"one\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"first\\n👩‍💻\"}]}",
        ),
        replay(
          "{\"type\":\"message\",\"id\":\"two\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"second\\\"line\"}]}",
        ),
        replay(
          "{\"type\":\"function_call\",\"id\":\"three\",\"call_id\":\"call\",\"name\":\"run\",\"arguments\":\"{\\\"x\\\":1}\"}",
        ),
        types.ToolOutput("call", "answer", []),
        types.User("tail"),
      ],
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(entries) = conversation.load_entries(ledger, "source")
  let older = list.take(entries, list.length(entries) - 1)
  list.each([types.Responses, types.ChatCompletions], fn(protocol) {
    list.each(["provider", "foreign"], fn(provider) {
      let assert Ok(projected) = projection.for_model(older, provider, protocol)
      let assert Ok([unit, _]) = inventory(ledger, profile(provider, protocol))
      unit.tokens |> should.equal(context_cost.estimate_inputs(projected))
    })
  })
  runtime.stop(host)
}

pub fn append_preserves_archived_metadata_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [
        types.User("archived"),
        types.Assistant("```code```"),
        types.User("tail"),
      ],
      conversation.Idle,
    )
  let assert Ok([before, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE TABLE metadata_rebuilds(n INTEGER); CREATE TRIGGER archived_cost_rebuild AFTER DELETE ON context_source_unit_cost WHEN OLD.first_seq=1 BEGIN INSERT INTO metadata_rebuilds VALUES(1); END",
      )
    })
  let #(appended, decodes) =
    count_decodes(store.owner(ledger), fn() {
      conversation.commit(
        ledger,
        "source",
        [types.Assistant("more tail")],
        conversation.Idle,
      )
    })
  let assert Ok(_) = appended
  should.equal(decodes, 0)
  let #(captured, capture_decodes) =
    count_decodes(store.owner(ledger), fn() {
      inventory(ledger, profile("provider", types.Responses))
    })
  let assert Ok([after, _]) = captured
  should.equal(capture_decodes, 0)
  should.equal(after.cost_key, before.cost_key)
  should.equal(after.salience, before.salience)
  let assert Ok([writes]) =
    store.read(
      ledger,
      "SELECT COUNT(*) FROM metadata_rebuilds",
      [],
      decode.field(0, decode.int, decode.success),
    )
  should.equal(writes, 0)
  runtime.stop(host)
}

pub fn same_max_rewrite_invalidates_scope_and_metadata_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("before"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok(before) =
    store.query(ledger, context_source.bound_in(_, "source"))
  let assert Ok([first, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok(_) =
    store.write(
      ledger,
      "UPDATE transcript SET payload=? WHERE session=? AND seq=1",
      [sqlight.blob(pack(types.User("rewritten"))), sqlight.text("source")],
    )
  let assert Ok(after) =
    store.query(ledger, context_source.bound_in(_, "source"))
  should.equal(after.transcript_upper, before.transcript_upper)
  should.be_true(after.revision > before.revision)
  inventory(ledger, profile("provider", types.Responses)) |> should.be_error
  let assert Ok(_) = store.query(ledger, context_source.reindex_in(_, "source"))
  let assert Ok([changed, _]) =
    inventory(ledger, profile("provider", types.Responses))
  should.not_equal(changed.content_identity, first.content_identity)
  runtime.stop(host)
}

pub fn image_fit_reprices_only_matching_metadata_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(image) = types.image("image/png", "AA==", 1024, 1024, 1)
  let assert Ok(other) = types.image("image/png", "Ag==", 1024, 1024, 1)
  let assert Ok(scaled) = types.image("image/png", "AQ==", 256, 256, 1)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [
        types.UserImage("first", [image]),
        types.UserImage("other", [other]),
        types.User("tail"),
      ],
      conversation.Idle,
    )
  let assert Ok([before, untouched, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let #(fit_result, decodes) =
    count_decodes(store.owner(ledger), fn() {
      conversation.commit_fits(
        ledger,
        "source",
        [transcript.ImageFit("fitted", image_fit.source(image), scaled)],
        "provider",
      )
    })
  let assert Ok(_) = fit_result
  // Only the newly appended fit carrier is decoded; old image rows are metadata-only.
  should.be_true(decodes <= 2)
  let assert Ok([after, other_after, _, _]) =
    inventory(ledger, profile("provider", types.Responses))
  should.be_true(after.tokens < before.tokens)
  should.equal(after.content_identity, before.content_identity)
  should.be_true(after.affected_fit_revision > before.affected_fit_revision)
  should.equal(other_after.cost_key, untouched.cost_key)
  let assert Ok([first, ..]) = conversation.load_sources(ledger, "source")
  should.equal(after.tokens, context_cost.estimate_input(first.entry.input))
  // A same-position rewrite must keep the later durable fit effective.
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      let assert Ok(stored) =
        images.externalize(db, types.UserImage("rewritten", [image]), fn(_) {
          Error(Nil)
        })
      store.run(
        db,
        "UPDATE transcript SET payload=? WHERE session=? AND seq=1",
        [sqlight.blob(pack(stored)), sqlight.text("source")],
      )
    })
  let assert Ok(_) = store.query(ledger, context_source.reindex_in(_, "source"))
  let assert Ok([rewritten, ..]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok([actual, ..]) = conversation.load_sources(ledger, "source")
  should.equal(
    rewritten.tokens,
    context_cost.estimate_input(actual.entry.input),
  )
  // Removing the fit restores the immutable source image price.
  let assert Ok(_) =
    store.write(
      ledger,
      "DELETE FROM transcript WHERE session=? AND row_class='image_fit'",
      [sqlight.text("source")],
    )
  let assert Ok(_) = store.query(ledger, context_source.reindex_in(_, "source"))
  let assert Ok([restored, ..]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok([original, ..]) = conversation.load_sources(ledger, "source")
  should.equal(
    restored.tokens,
    context_cost.estimate_input(original.entry.input),
  )
  runtime.stop(host)
}

pub fn empty_response_text_retains_native_chat_framing_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        replay(
          "{\"type\":\"message\",\"id\":\"empty\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]}",
        ),
        types.User("tail"),
      ],
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(entries) = conversation.load_entries(ledger, "source")
  let assert Ok(projected) =
    projection.for_model(
      list.take(entries, list.length(entries) - 1),
      "foreign",
      types.ChatCompletions,
    )
  let assert Ok([unit, _]) =
    inventory(ledger, profile("foreign", types.ChatCompletions))
  should.equal(unit.tokens, context_cost.estimate_inputs(projected))
  runtime.stop(host)
}

pub fn provider_configuration_refreshes_metadata_in_its_transaction_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("old"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok(_) =
    conversation.set_configuration(
      ledger,
      "source",
      "other",
      "model",
      types.ChatCompletions,
      None,
    )
  inventory(ledger, profile("other", types.ChatCompletions)) |> should.be_ok
  runtime.stop(host)
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

pub fn duplicate_call_occurrences_require_distinct_later_answers_test() -> Nil {
  let #(host, ledger) = started()
  let call =
    replay(
      "{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"same\",\"name\":\"run\",\"arguments\":\"{}\"}",
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.User("u"),
        call,
        call,
        types.ToolOutput("same", "one answer", []),
        types.User("tail"),
      ],
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok([unit, _]) =
    inventory(ledger, profile("provider", types.Responses))
  should.be_false(unit.closed)
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"run\",\"arguments\":\"{}\"}},{\"id\":\"same\",\"type\":\"function\",\"function\":{\"name\":\"run\",\"arguments\":\"{}\"}}]}",
      types.replay_decoder(types.ChatCompletions),
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.Replay(item),
        types.ToolOutput("same", "one answer", []),
        types.User("new tail"),
      ],
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok([_, duplicate, _]) =
    inventory(ledger, profile("provider", types.ChatCompletions))
  should.be_false(duplicate.closed)
  runtime.stop(host)
}

pub fn nullable_chat_calls_are_indexed_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"native text\",\"tool_calls\":null}",
      types.replay_decoder(types.ChatCompletions),
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [types.Replay(item), types.User("tail")],
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok([unit, _]) =
    inventory(ledger, profile("provider", types.ChatCompletions))
  should.be_true(unit.closed)
  runtime.stop(host)
}

pub fn provider_provenance_changes_cost_identity_test() -> Nil {
  let #(host, ledger) = started()
  let item =
    replay(
      "{\"type\":\"message\",\"id\":\"native\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"native text\"}]}",
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [item, types.User("tail")],
      conversation.Idle,
    )
  let assert Ok([before, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok(_) =
    conversation.set_configuration(
      ledger,
      "source",
      "other",
      "model",
      types.Responses,
      None,
    )
  let assert Ok([after, _]) =
    inventory(ledger, profile("provider", types.Responses))
  should.not_equal(before.content_identity, after.content_identity)
  should.not_equal(before.cost_key, after.cost_key)
  let assert Ok(entries) = conversation.load_entries(ledger, "source")
  let assert Ok(native) =
    projection.for_model(list.take(entries, 1), "provider", types.Responses)
  should.equal(after.tokens, context_cost.estimate_inputs(native))
  runtime.stop(host)
}

pub fn source_metadata_version_changes_rebuild_at_startup_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("```code```"), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok([before, _]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "UPDATE context_source_versions SET estimator=99,salience=99; UPDATE context_source_entry SET total_utf16=0,external_utf16=0; UPDATE context_source_unit_cost SET tokens=1",
      )
    })
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok([after, _]) =
    inventory(ledger, profile("provider", types.Responses))
  should.equal(after.tokens, before.tokens)
  should.equal(after.salience, before.salience)
  runtime.stop(host)
}

pub fn rewriting_earlier_fit_replays_lineage_before_later_overrides_test() -> Nil {
  let #(host, ledger) = started()
  let assert Ok(a) = types.image("image/png", "AA==", 1024, 1024, 1)
  let assert Ok(b) = types.image("image/png", "AQ==", 768, 768, 1)
  let assert Ok(c) = types.image("image/png", "Ag==", 256, 256, 1)
  let assert Ok(d) = types.image("image/png", "Aw==", 128, 128, 1)
  let assert Ok(e) = types.image("image/png", "BA==", 768, 768, 1)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.UserImage("first", [a]), types.User("tail")],
      conversation.Idle,
    )
  let assert Ok(_) =
    conversation.commit_fits(
      ledger,
      "source",
      [
        transcript.ImageFit("first fit", image_fit.source(a), b),
        transcript.ImageFit("second fit", image_fit.source(b), c),
        transcript.ImageFit("later original fit", image_fit.source(a), d),
      ],
      "provider",
    )
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      let assert Ok(stored) =
        images.externalize(db, types.UserImage("replaced fit", [e]), fn(_) {
          Error(Nil)
        })
      let assert types.UserImage(_, [image]) = stored
      store.run(
        db,
        "UPDATE transcript SET payload=? WHERE session='source' AND seq=3",
        [
          sqlight.blob(pack_fit("replaced fit", image_fit.source(a), image)),
        ],
      )
    })
  let assert Ok(_) = store.query(ledger, context_source.reindex_in(_, "source"))
  let assert Ok([unit, ..]) =
    inventory(ledger, profile("provider", types.Responses))
  let assert Ok([native, ..]) = conversation.load_sources(ledger, "source")
  should.equal(unit.tokens, context_cost.estimate_input(native.entry.input))
  runtime.stop(host)
}

@external(erlang, "albedo_conversation", "pack_fit")
fn pack_fit(note: String, source: String, image: types.Image) -> BitArray
