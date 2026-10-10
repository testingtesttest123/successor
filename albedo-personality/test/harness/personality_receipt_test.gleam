//// Invariant at the transaction/publication boundary: daemon HTTP cannot
//// deterministically kill a caller after commit but before tool publication.
//// Real store transactions prove recovery reads exact trusted call receipts,
//// never reinvokes unknown writes, and cannot cross persona/origin authority.

import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn setup() -> #(store.Store, p.Persona) {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); CREATE TABLE transcript(seq INTEGER PRIMARY KEY,session TEXT); CREATE TABLE session_family(session TEXT,parent TEXT); INSERT INTO sessions(id) VALUES('owner'),('second');",
    )
  ledger.initialise(db) |> should.be_ok
  session_requirements.initialise(db) |> should.be_ok
  let assert Ok(persona) =
    ledger.create(db, p.Creation("create", "owner identity", False, True, True))
  ledger.bind(db, "owner", p.Bind("bind", persona.id, 0, 0)) |> should.be_ok
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  #(db, snapshot.persona)
}

fn mutation(
  persona: p.Persona,
  operation: String,
  value: String,
) -> p.Mutation {
  p.Mutation(
    operation,
    persona.revision,
    persona.identity_revision,
    [#("values", value)],
    "foreground edit",
    None,
    [],
  )
}

fn count(db: store.Store, table: String) -> Int {
  let assert Ok(rows) =
    store.read(
      db,
      "SELECT COUNT(*) FROM " <> table,
      [],
      decode.field(0, decode.int, decode.success),
    )
  let assert [count] = rows
  count
}

pub fn committed_native_edit_recovers_exact_response_without_repeating_write_test() -> Nil {
  let #(db, persona) = setup()
  ledger.recover(db, "owner", "unknown-call") |> should.equal(Ok(None))
  let change = mutation(persona, "edit", "candid")
  let assert Ok(receipt) =
    domain.mutate(db, "owner", p.OwnerAgent("committed-call"), change)
  let encoded = json.to_string(ledger.receipt_json(receipt))
  ledger.recover(db, "owner", "committed-call")
  |> should.equal(Ok(Some(encoded)))
  // Simulate losing publication: no transcript tool result exists in this store.
  count(db, "transcript") |> should.equal(0)
  let events = count(db, "personality_event")
  domain.mutate(db, "owner", p.OwnerAgent("retry-call"), change)
  |> should.equal(Ok(receipt))
  ledger.recover(db, "owner", "retry-call") |> should.equal(Ok(Some(encoded)))
  count(db, "personality_event") |> should.equal(events)
  count(db, "personality_tool_receipt") |> should.equal(2)
  ledger.recover(db, "owner", "unknown-call") |> should.equal(Ok(None))
  count(db, "personality_event") |> should.equal(events)
  store.close(db)
}

pub fn trusted_call_reuse_rolls_back_the_entire_second_operation_test() -> Nil {
  let #(db, persona) = setup()
  let assert Ok(receipt) =
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("same-call"),
      mutation(persona, "one", "first"),
    )
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  let events = count(db, "personality_event")
  let revisions = count(db, "personality_revision")
  let assert Ok(before) = ledger.editing(db, "owner")
  domain.mutate(
    db,
    "owner",
    p.OwnerAgent("same-call"),
    mutation(snapshot.persona, "two", "second"),
  )
  |> should.equal(Error(p.OperationIdReused))
  count(db, "personality_event") |> should.equal(events)
  count(db, "personality_revision") |> should.equal(revisions)
  ledger.editing(db, "owner") |> should.equal(Ok(before))
  ledger.receipt(db, "owner", "two") |> should.equal(Ok(None))
  ledger.recover(db, "owner", "same-call")
  |> should.equal(Ok(Some(json.to_string(ledger.receipt_json(receipt)))))
  store.close(db)
}

pub fn recovery_cannot_cross_current_persona_or_origin_session_test() -> Nil {
  let #(db, persona) = setup()
  let assert Ok(_) =
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("origin-call"),
      mutation(persona, "edit", "private origin"),
    )
  ledger.bind(db, "second", p.Bind("bind-second", persona.id, 0, 0))
  |> should.be_ok
  ledger.recover(db, "second", "origin-call") |> should.equal(Ok(None))
  ledger.receipt(db, "second", "edit") |> should.equal(Ok(None))
  let assert Ok(other) =
    ledger.create(
      db,
      p.Creation("create-other", "new empty identity", False, True, True),
    )
  ledger.bind(db, "owner", p.Bind("rebind", other.id, 1, 0)) |> should.be_ok
  ledger.recover(db, "owner", "origin-call") |> should.equal(Ok(None))
  ledger.receipt(db, "owner", "edit") |> should.equal(Ok(None))
  store.close(db)
}

pub fn canonical_payload_ignores_object_and_lock_order_without_ignoring_actor_test() -> Nil {
  let base =
    p.Mutation(
      "id",
      2,
      1,
      [#("values", "é"), #("instructions", "data")],
      "reason",
      Some(p.ControlChange(Some(["values", "instructions"]), None, None)),
      [],
    )
  let reordered =
    p.Mutation(
      ..base,
      changes: list.reverse(base.changes),
      controls: Some(p.ControlChange(
        Some(["instructions", "values"]),
        None,
        None,
      )),
    )
  domain.canonical(base, p.User)
  |> should.equal(domain.canonical(reordered, p.User))
  domain.hash(domain.canonical(base, p.User))
  |> should.not_equal(
    domain.hash(domain.canonical(base, p.OwnerAgent("trusted"))),
  )
}

pub fn agent_controls_and_locked_fields_are_refused_but_user_corrections_commit_test() -> Nil {
  let #(db, persona) = setup()
  let configuration =
    p.Mutation(
      "locks",
      persona.revision,
      persona.identity_revision,
      [],
      "user field lock",
      Some(p.ControlChange(Some(["values"]), None, None)),
      [],
    )
  let assert Ok(configured) = domain.mutate(db, "owner", p.User, configuration)
  configured.identity_revision |> should.equal(persona.identity_revision)
  let assert Ok(snapshot) = ledger.capture(db, "owner", "")
  case
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("locked-call"),
      mutation(snapshot.persona, "locked", "agent locked write"),
    )
  {
    Error(p.Forbidden(_)) -> Nil
    _ -> should.fail()
  }
  ledger.recover(db, "owner", "locked-call") |> should.equal(Ok(None))
  let assert Ok(_) =
    domain.mutate(
      db,
      "owner",
      p.User,
      mutation(snapshot.persona, "correction", "user correction"),
    )
  let assert Ok(current) = ledger.capture(db, "owner", "")
  let disable =
    p.Mutation(
      "disable",
      current.persona.revision,
      current.persona.identity_revision,
      [],
      "disable agent edits",
      Some(p.ControlChange(None, Some(False), None)),
      [],
    )
  domain.mutate(db, "owner", p.User, disable) |> should.be_ok
  let assert Ok(disabled) = ledger.capture(db, "owner", "")
  case
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("disabled-call"),
      p.Mutation(..mutation(disabled.persona, "disabled", "data"), changes: [
        #("instructions", "not locked"),
      ]),
    )
  {
    Error(p.Forbidden(_)) -> Nil
    _ -> should.fail()
  }
  case
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("spoof-call"),
      p.Mutation(
        ..disable,
        operation_id: "spoof",
        expected_revision: disabled.persona.revision,
      ),
    )
  {
    Error(p.Forbidden(_)) -> Nil
    _ -> should.fail()
  }
  store.close(db)
}

pub fn failed_trusted_receipt_mapping_rolls_back_event_head_usage_and_operation_test() -> Nil {
  let #(db, persona) = setup()
  let assert Ok(before) = ledger.editing(db, "owner")
  store.write(
    db,
    "CREATE TRIGGER reject_tool_receipt BEFORE INSERT ON personality_tool_receipt BEGIN SELECT RAISE(ABORT,'mapping failure'); END",
    [],
  )
  |> should.be_ok
  let events = count(db, "personality_event")
  case
    domain.mutate(
      db,
      "owner",
      p.OwnerAgent("failed-call"),
      mutation(persona, "failed-edit", "must roll back"),
    )
  {
    Error(p.Storage("mapping failure")) -> Nil
    _ -> should.fail()
  }
  count(db, "personality_event") |> should.equal(events)
  count(db, "personality_revision") |> should.equal(1)
  ledger.editing(db, "owner") |> should.equal(Ok(before))
  ledger.receipt(db, "owner", "failed-edit") |> should.equal(Ok(None))
  ledger.recover(db, "owner", "failed-call") |> should.equal(Ok(None))
  store.close(db)
}

pub fn identical_native_replay_at_full_reserve_returns_original_receipt_without_write_test() -> Nil {
  let #(db, persona) = setup()
  let change = mutation(persona, "committed", "reserve still permits reads")
  let assert Ok(receipt) =
    domain.mutate(db, "owner", p.OwnerAgent("original-call"), change)
  store.write(
    db,
    "UPDATE personality_capacity SET corrective_limit=corrective_bytes",
    [],
  )
  |> should.be_ok
  let assert Ok(before) = ledger.editing(db, "owner")
  domain.mutate(db, "owner", p.OwnerAgent("unmapped-retry"), change)
  |> should.equal(Ok(receipt))
  ledger.editing(db, "owner") |> should.equal(Ok(before))
  count(db, "personality_tool_receipt") |> should.equal(1)
  ledger.recover(db, "owner", "original-call")
  |> should.equal(Ok(Some(json.to_string(ledger.receipt_json(receipt)))))
  ledger.recover(db, "owner", "unmapped-retry") |> should.equal(Ok(None))
  count(db, "personality_revision") |> should.equal(2)
  store.close(db)
}
