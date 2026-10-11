//// Store transactions expose commit-before-publication and receipt insert
//// failures that HTTP cannot deterministically interrupt without a kernel.

import albedo/daemon/store
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should

@external(erlang, "albedo_personality_edit_test_support", "count_replacements")
fn count_replacements(
  owner: process.Pid,
  run: fn() -> Result(p.Receipt, p.DomainError),
) -> #(Result(p.Receipt, p.DomainError), Int)

fn setup() -> store.Store {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY,config_revision INTEGER NOT NULL DEFAULT 0); CREATE TABLE transcript(seq INTEGER PRIMARY KEY,session TEXT); CREATE TABLE session_family(session TEXT,parent TEXT); CREATE TABLE session_extensions(session TEXT,name TEXT,enabled INTEGER,PRIMARY KEY(session,name)); INSERT INTO sessions(id) VALUES('owner'),('other');",
    )
  ledger.initialise(db) |> should.be_ok
  let assert Ok(persona) =
    ledger.create(db, "identity", "paragraph paragraph", True, True)
  ledger.bind(db, "owner", persona.id, 0, 0, []) |> should.be_ok
  db
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

pub fn oversized_edit_refuses_before_replacement_allocation_test() -> Nil {
  let db = setup()
  ledger.write_document(
    db,
    "owner",
    p.User("initial"),
    string.repeat("a", 1024),
    None,
  )
  |> should.be_ok
  let assert Ok(before) = ledger.capture(db, "owner")
  let revisions = count(db, "personality_revision")
  let receipts = count(db, "personality_tool_receipt")
  // Both arguments are permitted; only their 2-MiB product is oversized.
  let #(refused, allocations) =
    count_replacements(store.owner(db), fn() {
      ledger.edit_document(
        db,
        "owner",
        p.OwnerAgent("amplified"),
        "a",
        string.repeat("é", 1024),
        True,
      )
    })
  refused |> should.be_error
  allocations |> should.equal(0)
  ledger.capture(db, "owner") |> should.equal(Ok(before))
  count(db, "personality_revision") |> should.equal(revisions)
  count(db, "personality_tool_receipt") |> should.equal(receipts)
  ledger.recover(db, "owner", "amplified") |> should.equal(Ok(None))
  // A positive control proves that this trace observes the real allocator.
  let #(accepted, allocations) =
    count_replacements(store.owner(db), fn() {
      ledger.edit_document(db, "owner", p.OwnerAgent("valid"), "aa", "b", True)
    })
  accepted |> should.be_ok
  allocations |> should.equal(1)
  store.close(db)
}

pub fn replacement_size_uses_utf8_bytes_and_nonoverlapping_matches_test() -> Nil {
  let half = string.repeat("a", domain.document_limit / 2)
  let assert Ok(exact) = domain.edit(half, "a", "é", True)
  string.byte_size(exact) |> should.equal(domain.document_limit)
  domain.edit(half <> "a", "a", "é", True) |> should.be_error
  domain.edit("ééé", "éé", "x", False) |> should.equal(Ok("xé"))
  domain.edit("aaaaa", "aa", "x", True) |> should.equal(Ok("xxa"))
  domain.edit("aaaaa", "aa", "x", False) |> should.be_error
  domain.edit(exact, "éé", "x", True)
  |> should.equal(Ok(string.repeat("x", domain.document_limit / 4)))
  domain.edit(exact, "é", "", True) |> should.equal(Ok(""))
  domain.edit("literal .$[", ".$[", "é", False)
  |> should.equal(Ok("literal é"))
  domain.edit("a", "", "b", True) |> should.be_error
  Nil
}

pub fn ordinary_edit_matches_text_and_recovers_test() -> Nil {
  let db = setup()
  let assert Ok(before) = ledger.capture(db, "owner")
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("ambiguous"),
    "paragraph",
    "changed",
    False,
  )
  |> result.is_error
  |> should.be_true
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("missing"),
    "absent",
    "changed",
    False,
  )
  |> result.is_error
  |> should.be_true
  ledger.edit_document(db, "owner", p.OwnerAgent("empty"), "", "changed", True)
  |> result.is_error
  |> should.be_true
  ledger.capture(db, "owner") |> should.equal(Ok(before))
  count(db, "personality_tool_receipt") |> should.equal(0)
  // Another session's binding is unrelated to the document revision.
  ledger.bind(db, "other", before.persona.id, 0, 0, []) |> should.be_ok
  let assert Ok(receipt) =
    ledger.edit_document(
      db,
      "owner",
      p.OwnerAgent("same-call"),
      "paragraph",
      "changed",
      True,
    )
  let encoded = json.to_string(ledger.receipt_json(receipt))
  ledger.recover(db, "owner", "same-call") |> should.equal(Ok(Some(encoded)))
  ledger.recover(db, "other", "same-call") |> should.equal(Ok(None))
  ledger.recover(db, "owner", "unknown") |> should.equal(Ok(None))
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("same-call"),
    "paragraph",
    "changed",
    True,
  )
  |> should.equal(Ok(receipt))
  ledger.edit_document(
    db,
    "owner",
    p.OwnerAgent("same-call"),
    "changed",
    "different",
    True,
  )
  |> should.equal(Error(p.CallReused))
  count(db, "personality_tool_receipt") |> should.equal(1)
  count(db, "personality_revision") |> should.equal(2)
  let assert Ok(after) = ledger.capture(db, "owner")
  after.persona.document |> should.equal("changed changed")
  ledger.read_document(db, "owner", Some(1), 0, 32_768)
  |> should.equal(Ok(p.DocumentPage(1, "paragraph paragraph", None)))
  count(db, "transcript") |> should.equal(0)
  store.close(db)
}

pub fn failed_receipt_insert_rolls_back_document_and_revision_test() -> Nil {
  let db = setup()
  let assert Ok(before) = ledger.capture(db, "owner")
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "CREATE TRIGGER refuse_receipt BEFORE INSERT ON personality_tool_receipt BEGIN SELECT RAISE(ABORT,'receipt unavailable'); END",
    ))
  ledger.write_document(db, "owner", p.OwnerAgent("failed"), "new", None)
  |> result.is_error
  |> should.be_true
  ledger.capture(db, "owner") |> should.equal(Ok(before))
  count(db, "personality_revision") |> should.equal(1)
  ledger.recover(db, "owner", "failed") |> should.equal(Ok(None))
  store.close(db)
}

pub fn write_revision_conflicts_are_document_only_and_receipts_survive_rebinding_test() -> Nil {
  let db = setup()
  let assert Ok(before) = ledger.capture(db, "owner")
  let assert Ok(receipt) =
    ledger.write_document(db, "owner", p.OwnerAgent("write"), "new", Some(1))
  ledger.write_document(db, "owner", p.OwnerAgent("write"), "new", Some(1))
  |> should.equal(Ok(receipt))
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("stale"),
    "discarded",
    Some(1),
  )
  |> should.equal(Error(p.RevisionConflict(2)))
  let assert Ok(other) = ledger.create(db, "other", "separate", False, False)
  ledger.bind(db, "owner", other.id, before.binding.generation, 0, [])
  |> should.be_ok
  ledger.recover(db, "owner", "write")
  |> should.equal(Ok(Some(json.to_string(ledger.receipt_json(receipt)))))
  ledger.write_document(db, "owner", p.OwnerAgent("write"), "new", Some(1))
  |> should.equal(Ok(receipt))
  let assert Ok(rebound) = ledger.capture(db, "owner")
  rebound.persona |> should.equal(other)
  ledger.write_document(db, "owner", p.OwnerAgent("write"), "different", None)
  |> should.equal(Error(p.CallReused))
  count(db, "personality_revision") |> should.equal(3)
  ledger.write_document(db, "owner", p.OwnerAgent("readonly"), "denied", None)
  |> should.equal(Error(p.Forbidden("identity document is read-only")))
  ledger.write_document(db, "owner", p.User("human"), "human correction", None)
  |> should.be_ok
  count(db, "personality_tool_receipt") |> should.equal(2)
  store.close(db)
}
