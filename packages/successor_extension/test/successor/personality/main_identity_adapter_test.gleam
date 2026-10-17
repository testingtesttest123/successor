import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/python/kernel
import albedo/harness/request_context
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import successor/personality/ledger
import successor/personality/projection
import successor/personality/tools
import successor/personality/types as p

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

fn start(writable: Bool) -> store.Store {
  let assert Ok(bytes) = read_file("test/fixtures/ledger-host.sql")
  let assert Ok(sql) = bit_array.to_string(bytes)
  let assert Ok(db) = store.start(":memory:", sql)
  let assert Ok(_) = session_requirements.initialise(db)
  let assert Ok(_) = ledger.initialise(db)
  let assert Ok(_) =
    ledger.setup(
      db,
      "owner",
      "main",
      "original identity",
      writable,
      "setup",
      [],
    )
  db
}

fn input(db: store.Store) -> request_context.Input {
  request_context.Input(
    db,
    "owner",
    ["personality"],
    "untrusted user text",
    request_context.Budget(None, None, 0, None),
  )
}

fn tool(name: String) -> extension.Tool {
  let assert Ok(tool) =
    list.find(tools.tools(), fn(item) { item.definition.name == name })
  tool
}

fn context(
  db: store.Store,
  session: String,
  call: String,
) -> extension.Context {
  extension.Context(
    db,
    session,
    unused_kernel(),
    call,
    "/tmp",
    types.any_images,
  )
}

pub fn actual_projection_keeps_one_capture_and_next_capture_observes_edit_test() {
  let db = start(True)
  let assert Ok(first) = projection.prepare(input(db))
  let assert Ok(_) =
    ledger.write_document(
      db,
      "owner",
      p.User("human"),
      "changed identity",
      Some(1),
    )
  let assert Ok(next) = projection.prepare(input(db))
  should.not_equal(first.snapshot_id, next.snapshot_id)
  let assert [before] = first.instructions
  let assert [after] = next.instructions
  string.contains(before.content, "original identity") |> should.be_true
  string.contains(after.content, "changed identity") |> should.be_true
  let assert Ok(page) = ledger.read_document(db, "owner", Some(1), 0, 32_768)
  page.text |> should.equal("original identity")
  store.close(db)
}

pub fn tool_uses_native_session_actor_and_operation_id_test() {
  let db = start(True)
  let write = tool("persona_write")
  let args = "{\"content\":\"new identity\",\"expected_revision\":1}"
  write.invoke(context(db, "other", "wrong-session"), args) |> should.be_ok
  let assert Ok(first) = ledger.capture(db, "owner")
  first.persona.identity_revision |> should.equal(1)
  write.invoke(context(db, "owner", "native-call"), args) |> should.be_ok
  let assert Ok(next) = ledger.capture(db, "owner")
  next.persona.identity_revision |> should.equal(2)
  let assert Ok(Some(receipt)) = ledger.recover(db, "owner", "native-call")
  string.contains(receipt, "owner_agent") |> should.be_true
  write.invoke(context(db, "owner", "native-call"), args) |> should.be_ok
  let assert Ok(again) = ledger.capture(db, "owner")
  again |> should.equal(next)
  store.close(db)
}

pub fn model_cannot_supply_authority_or_omit_revision_test() {
  let db = start(True)
  let write = tool("persona_write")
  write.invoke(
    context(db, "owner", "bad"),
    "{\"content\":\"new\",\"expected_revision\":1,\"actor\":\"user\"}",
  )
  |> should.be_ok
  write.invoke(context(db, "owner", "no-revision"), "{\"content\":\"new\"}")
  |> should.be_ok
  let assert Ok(captured) = ledger.capture(db, "owner")
  captured.persona.identity_revision |> should.equal(1)
  store.close(db)
}

pub fn read_only_identity_refuses_model_but_allows_revision_checked_user_edit_test() {
  let db = start(False)
  tool("persona_write").invoke(
    context(db, "owner", "model"),
    "{\"content\":\"new\",\"expected_revision\":1}",
  )
  |> should.be_ok
  let assert Ok(captured) = ledger.capture(db, "owner")
  captured.persona.identity_revision |> should.equal(1)
  ledger.write_document(db, "owner", p.User("human"), "approved", Some(1))
  |> should.be_ok
  store.close(db)
}

pub fn receipt_recovery_requires_exact_origin_session_and_call_test() {
  let db = start(True)
  let assert Ok(_) =
    ledger.write_document(
      db,
      "owner",
      p.OwnerAgent("native-call"),
      "new identity",
      Some(1),
    )
  let assert Ok(Some(_)) = ledger.recover(db, "owner", "native-call")
  ledger.recover(db, "other", "native-call") |> should.equal(Ok(None))
  ledger.recover(db, "owner", "different-call") |> should.equal(Ok(None))
  tool("persona_write").recover(context(db, "other", "native-call"))
  |> should.equal(None)
  tool("persona_write").recover(context(db, "owner", "different-call"))
  |> should.equal(None)
  let assert Ok(captured) = ledger.capture(db, "owner")
  captured.persona.identity_revision |> should.equal(2)
  store.close(db)
}

pub fn user_operation_cannot_be_replayed_as_an_owner_mutation_test() {
  let db = start(True)
  let assert Ok(receipt) =
    ledger.write_document(
      db,
      "owner",
      p.User("shared-key"),
      "approved",
      Some(1),
    )
  receipt.call_id |> should.equal("human:shared-key")
  ledger.recover(db, "owner", "shared-key") |> should.equal(Ok(None))
  tool("persona_write").recover(context(db, "owner", "shared-key"))
  |> should.equal(None)
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("shared-key"),
    "approved",
    Some(1),
  )
  |> should.equal(Error(p.RevisionConflict(2)))
  // Even an exact collision with the user namespace cannot replay its mutation:
  // the receipt request hash includes the trusted actor supplied by the adapter.
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("human:shared-key"),
    "approved",
    Some(1),
  )
  |> should.equal(Error(p.CallReused))
  ledger.write_document(db, "owner", p.User("shared-key"), "approved", Some(1))
  |> should.equal(Ok(receipt))
  let assert Ok(captured) = ledger.capture(db, "owner")
  captured.persona.identity_revision |> should.equal(2)
  store.close(db)
}

pub fn model_recovery_refuses_user_receipt_even_with_exact_prefixed_call_id_test() {
  let db = start(True)
  let assert Ok(_) =
    ledger.write_document(db, "owner", p.User("existing"), "approved", Some(1))
  tool("persona_write").recover(context(db, "owner", "human:existing"))
  |> should.equal(None)
  ledger.recover(db, "owner", "human:existing") |> should.equal(Ok(None))
  let assert Ok(captured) = ledger.capture(db, "owner")
  captured.persona.identity_revision |> should.equal(2)
  store.close(db)
}

pub fn model_recovery_preserves_owner_receipts_with_human_prefixed_provider_ids_test() {
  let db = start(True)
  let assert Ok(_) =
    ledger.write_document(
      db,
      "owner",
      p.OwnerAgent("human:provider-call"),
      "model edit",
      Some(1),
    )
  let assert Ok(Some(receipt)) =
    ledger.recover(db, "owner", "human:provider-call")
  string.contains(receipt, "owner_agent") |> should.be_true
  let assert Some(_) =
    tool("persona_write").recover(context(db, "owner", "human:provider-call"))
  store.close(db)
}
