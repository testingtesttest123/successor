import albedo/daemon/session_requirements
import albedo/daemon/store
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import successor/personality/ledger
import successor/personality/projection
import successor/personality/types as p

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

fn start() -> store.Store {
  let assert Ok(bytes) = read_file("test/fixtures/ledger-host.sql")
  let assert Ok(sql) = bit_array.to_string(bytes)
  let assert Ok(db) = store.start(":memory:", sql)
  let assert Ok(_) = session_requirements.initialise(db)
  let assert Ok(_) = ledger.initialise(db)
  db
}

fn exec(db: store.Store, sql: String) {
  let assert Ok(_) = store.query(db, store.exec(_, sql))
  Nil
}

fn count(db: store.Store, table: String) -> Int {
  let assert Ok([n]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM " <> table,
      [],
      decode.field(0, decode.int, decode.success),
    )
  n
}

fn setup(db: store.Store) -> p.Captured {
  let assert Ok(captured) =
    ledger.setup(db, "owner", "main", "first", True, "setup", [])
  captured
}

pub fn explicit_setup_is_singleton_replay_and_requirement_atomic_test() {
  let db = start()
  ledger.capture(db, "owner") |> should.equal(Error(p.SetupRequired))
  let captured = setup(db)
  ledger.setup(db, "owner", "main", "first", True, "setup", [])
  |> should.equal(Ok(captured))
  ledger.setup(db, "owner", "main", "changed", True, "setup", [])
  |> should.equal(Error(p.CallReused))
  ledger.setup(db, "other", "other", "second", True, "other", [])
  |> should.be_error
  count(db, "personality_persona") |> should.equal(1)
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok(["personality"]))
  store.close(db)
}

pub fn missing_requirement_is_not_silently_backfilled_test() {
  let db = start()
  let _ = setup(db)
  let assert Ok(_) =
    store.query(db, session_requirements.release_in(_, "owner", "personality"))
  ledger.capture(db, "owner") |> should.be_error
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok([]))
  store.close(db)
}

pub fn failed_receipt_rolls_back_identity_binding_and_requirement_test() {
  let db = start()
  exec(
    db,
    "CREATE TRIGGER fail_setup BEFORE INSERT ON personality_setup_receipt BEGIN SELECT RAISE(ABORT,'receipt failure'); END;",
  )
  ledger.setup(db, "owner", "main", "first", True, "setup", [])
  |> should.be_error
  count(db, "personality_persona") |> should.equal(0)
  count(db, "personality_session") |> should.equal(0)
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok([]))
  store.close(db)
}

pub fn revisions_are_captured_immutably_and_operations_are_idempotent_test() {
  let db = start()
  let captured = setup(db)
  let before = projection.contribution(captured)
  let assert Ok(receipt) =
    ledger.write_document(
      db,
      "owner",
      p.OwnerAgent("write1"),
      "second",
      Some(1),
    )
  receipt.identity_revision |> should.equal(2)
  ledger.write_document(db, "owner", p.OwnerAgent("write1"), "second", Some(1))
  |> should.equal(Ok(receipt))
  ledger.write_document(db, "owner", p.OwnerAgent("write1"), "other", Some(1))
  |> should.equal(Error(p.CallReused))
  ledger.write_document(db, "owner", p.OwnerAgent("write2"), "stale", Some(1))
  |> should.equal(Error(p.RevisionConflict(2)))
  let assert Ok(next) = ledger.capture(db, "owner")
  next.persona.document |> should.equal("second")
  projection.contribution(captured) |> should.equal(before)
  count(db, "personality_revision") |> should.equal(2)
  store.close(db)
}

pub fn projection_never_truncates_identity_to_read_page_test() {
  let db = start()
  let captured = setup(db)
  let document = string.repeat("x", 40_000) <> "THE END"
  let projected =
    projection.contribution(p.Captured(
      p.Persona(..captured.persona, document: document),
      captured.binding,
    ))
  let assert [block] = projected.instructions
  string.contains(block.content, document) |> should.be_true
  store.close(db)
}

pub fn mutations_require_expected_revision_and_owner_binding_test() {
  let db = start()
  let _ = setup(db)
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("missing"),
    "new",
    option.None,
  )
  |> should.be_error
  exec(
    db,
    "UPDATE personality_session SET mode='delegate' WHERE session='owner';",
  )
  ledger.write_document(db, "owner", p.OwnerAgent("delegate"), "new", Some(1))
  |> should.be_error
  count(db, "personality_revision") |> should.equal(1)
  store.close(db)
}

pub fn unbind_releases_requirement_atomically_and_preserves_identity_test() {
  let db = start()
  let _ = setup(db)
  ledger.unbind(db, "owner", 0) |> should.be_error
  ledger.unbind(db, "owner", 1) |> should.be_ok
  ledger.capture(db, "owner") |> should.equal(Error(p.SetupRequired))
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok([]))
  count(db, "personality_persona") |> should.equal(1)
  ledger.bind(db, "owner", "", 0, 0, []) |> should.be_error
  ledger.bind(db, "owner", "", 1, 0, []) |> should.be_ok
  store.close(db)
}

pub fn binding_does_not_repair_existing_unprotected_state_test() {
  let db = start()
  let captured = setup(db)
  let assert Ok(_) =
    store.query(db, session_requirements.release_in(_, "owner", "personality"))
  ledger.bind(db, "owner", captured.persona.id, 1, 0, []) |> should.be_error
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok([]))
  store.close(db)
}

pub fn edited_substrings_also_require_expected_revision_test() {
  let db = start()
  let _ = setup(db)
  let assert Ok(receipt) =
    ledger.edit_document(
      db,
      "owner",
      p.OwnerAgent("edit1"),
      "first",
      "second",
      False,
      1,
    )
  receipt.identity_revision |> should.equal(2)
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("edit1"),
    "first",
    "second",
    False,
    1,
  )
  |> should.equal(Ok(receipt))
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("edit2"),
    "second",
    "third",
    False,
    1,
  )
  |> should.equal(Error(p.RevisionConflict(2)))
  store.close(db)
}

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Dynamic

pub fn restart_preserves_current_revision_binding_and_requirement_test() {
  let path = "/tmp/main-identity-" <> ledger.new_id() <> ".sqlite3"
  let assert Ok(bytes) = read_file("test/fixtures/ledger-host.sql")
  let assert Ok(sql) = bit_array.to_string(bytes)
  let assert Ok(db) = store.start(path, sql)
  let assert Ok(_) = session_requirements.initialise(db)
  let assert Ok(_) = ledger.initialise(db)
  let original = setup(db)
  ledger.write_document(
    db,
    "owner",
    p.User("change"),
    "survives restart",
    Some(1),
  )
  |> should.be_ok
  store.close(db)
  let assert Ok(reopened) = store.start(path, "")
  let assert Ok(_) = ledger.initialise(reopened)
  let assert Ok(captured) = ledger.capture(reopened, "owner")
  captured.binding |> should.equal(original.binding)
  captured.persona.identity_revision |> should.equal(2)
  captured.persona.document |> should.equal("survives restart")
  store.query(reopened, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok(["personality"]))
  store.close(reopened)
  let _ = delete_file(path)
  Nil
}

pub fn missing_tables_refuse_capture_without_repair_test() {
  let db = start()
  let _ = setup(db)
  exec(db, "ALTER TABLE personality_revision RENAME TO retained_revision;")
  ledger.capture(db, "owner") |> should.be_error
  ledger.initialise(db) |> should.be_error
  count(db, "retained_revision") |> should.equal(1)
  store.query(db, session_requirements.required_in(_, "owner"))
  |> should.equal(Ok(["personality"]))
  store.close(db)
}

pub fn unbound_child_cannot_setup_or_bind_main_identity_test() {
  let db = start()
  ledger.setup(db, "child", "main", "first", True, "child", [])
  |> should.be_error
  let original = setup(db)
  ledger.bind(db, "child", original.persona.id, 0, 0, []) |> should.be_error
  count(db, "personality_session") |> should.equal(1)
  store.close(db)
}

pub fn explicit_rebind_invalidates_native_prepared_configuration_test() {
  let db = start()
  let original = setup(db)
  let assert Ok(_) = ledger.bind(db, "owner", original.persona.id, 1, 0, [])
  let assert Ok([revision]) =
    store.read(
      db,
      "SELECT config_revision FROM sessions WHERE id='owner'",
      [],
      decode.field(0, decode.int, decode.success),
    )
  revision |> should.equal(2)
  store.close(db)
}
