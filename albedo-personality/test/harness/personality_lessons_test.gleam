//// Optional storage/injection separation is a cross-extension invariant.
//// Native transaction failure points and absent optional tables cannot be
//// deterministically exposed by one ordinary daemon HTTP session.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/extension as personality
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/lessons
import albedo/harness/extensions/personality/lessons_extension
import albedo/harness/extensions/personality/projection
import albedo/harness/extensions/personality/types as p
import albedo/harness/extensions/python/kernel
import albedo/harness/request_context
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

fn setup() -> store.Store {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY,config_revision INTEGER NOT NULL DEFAULT 0); CREATE TABLE transcript(seq INTEGER PRIMARY KEY,session TEXT); CREATE TABLE session_family(session TEXT,parent TEXT); CREATE TABLE session_extensions(session TEXT,name TEXT,enabled INTEGER,PRIMARY KEY(session,name)); INSERT INTO sessions(id) VALUES('owner');",
    )
  ledger.initialise(db) |> should.be_ok
  ledger.setup(
    db,
    "owner",
    "Albedo",
    "living free-form document",
    True,
    "setup",
    [],
  )
  |> should.be_ok
  db
}

fn projection(db: store.Store) -> request_context.Contribution {
  let assert Ok(projected) =
    projection.prepare(request_context.Input(
      db,
      "owner",
      ["personality"],
      "",
      request_context.Budget(None, None, 0, None),
    ))
  projected
}

fn invoke(
  db: store.Store,
  name: String,
  call: String,
  args: json.Json,
) -> lessons.Lesson {
  let assert Ok(tool) =
    list.find(lessons_extension.tools(), fn(tool) {
      tool.definition.name == name
    })
  let context =
    extension.Context(
      db,
      "owner",
      unused_kernel(),
      call,
      "/tmp",
      types.any_images,
    )
  let assert Ok(answer) = extension.invoke(tool, context, json.to_string(args))
  let assert Ok(lesson) = json.parse(answer.text, lessons.decoder())
  lesson
}

pub fn lessons_are_optional_and_simple_test() -> Nil {
  let db = setup()
  let assert Ok(before) = ledger.capture(db, "owner")
  let assert Ok([]) =
    store.read(
      db,
      "SELECT name FROM sqlite_master WHERE name LIKE 'personality_lesson%'",
      [],
      decode.dynamic,
    )
  let first_projection = projection(db)
  lessons.initialise(db) |> should.be_ok
  let created =
    invoke(
      db,
      "lesson_create",
      "create",
      json.object([
        #("content", json.string("Read primary sources")),
        #("tags", json.array(["research"], json.string)),
      ]),
    )
  created.confidence |> should.equal(0.5)
  created.evidence |> should.equal([])
  created.actor |> should.equal("owner_agent")
  created.origin_session |> should.equal("owner")
  let updated =
    invoke(
      db,
      "lesson_update",
      "update",
      json.object([
        #("id", json.string(created.id)),
        #(
          "content",
          json.string("Check the primary source before forming a belief"),
        ),
        #(
          "evidence",
          json.array(["https://example.org/reference"], json.string),
        ),
      ]),
    )
  updated.evidence |> should.equal(["https://example.org/reference"])
  let assert Ok(page) =
    lessons.query(db, "owner", "primary", ["research"], False, 0, 20)
  page.records |> should.equal([updated])
  let deprecated =
    invoke(
      db,
      "lesson_deprecate",
      "deprecate",
      json.object([
        #("id", json.string(created.id)),
        #("reason", json.string("superseded")),
      ]),
    )
  deprecated.deprecated |> should.be_true
  let assert Ok(history) = lessons.history(db, "owner", created.id, 0, 2)
  history.records |> should.equal([created, updated])
  history.next_offset |> should.equal(Some(2))
  let assert Ok(rest) = lessons.history(db, "owner", created.id, 2, 2)
  rest.records |> should.equal([deprecated])
  let assert Ok(empty) = lessons.query(db, "owner", "", [], False, 0, 20)
  empty.records |> should.equal([])
  projection(db) |> should.equal(first_projection)
  ledger.capture(db, "owner") |> should.equal(Ok(before))
  let optional =
    composition.compose([lessons_extension.extension()], db, "owner", "/tmp")
  composition.request_context(optional) |> should.equal([])
  composition.close(optional)
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "DROP TABLE personality_lesson_receipt; DROP TABLE personality_lesson_revision; DROP TABLE personality_lesson",
    ))
  ledger.capture(db, "owner") |> should.equal(Ok(before))
  projection(db) |> should.equal(first_projection)
  store.close(db)
}

pub fn failed_lesson_receipt_rolls_back_all_revisions_test() -> Nil {
  let db = setup()
  lessons.initialise(db) |> should.be_ok
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "CREATE TRIGGER refuse_lesson_receipt BEFORE INSERT ON personality_lesson_receipt BEGIN SELECT RAISE(ABORT,'unavailable'); END",
    ))
  lessons.create(db, "owner", p.OwnerAgent("failed"), "lesson", [], None, None)
  |> result.is_error
  |> should.be_true
  let assert Ok([0]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM personality_lesson_revision",
      [],
      decode.field(0, decode.int, decode.success),
    )
  lessons.recover(db, "owner", "failed") |> should.equal(Ok(None))
  ledger.capture(db, "owner") |> should.be_ok
  store.close(db)
}

pub fn lesson_replay_is_exact_and_does_not_change_document_revision_test() -> Nil {
  let db = setup()
  lessons.initialise(db) |> should.be_ok
  let assert Ok(created) =
    lessons.create(
      db,
      "owner",
      p.OwnerAgent("create"),
      "one lesson",
      [],
      None,
      None,
    )
  lessons.create(
    db,
    "owner",
    p.OwnerAgent("create"),
    "one lesson",
    [],
    Some(0.5),
    Some([]),
  )
  |> should.equal(Ok(created))
  lessons.create(
    db,
    "owner",
    p.OwnerAgent("create"),
    "different",
    [],
    None,
    None,
  )
  |> should.equal(Error(p.CallReused))
  lessons.recover(db, "owner", "create")
  |> should.equal(Ok(Some(json.to_string(lessons.to_json(created)))))
  let assert Ok(before) = ledger.capture(db, "owner")
  lessons.update(
    db,
    "owner",
    p.OwnerAgent("bad"),
    created.id,
    None,
    None,
    Some(2.0),
    None,
  )
  |> should.be_error
  ledger.write_document(
    db,
    "owner",
    p.OwnerAgent("write"),
    "new",
    Some(before.persona.identity_revision),
  )
  |> should.be_ok
  let assert Ok(current) = lessons.read(db, "owner", created.id)
  current |> should.equal(created)
  let assert Ok(after) = ledger.capture(db, "owner")
  after.persona.identity_revision
  |> should.equal(before.persona.identity_revision + 1)
  let composed =
    composition.compose([personality.extension()], db, "owner", "/tmp")
  // A missing required lcm-memory removes the entire bundle, not lesson state.
  composition.request_context(composed) |> should.equal([])
  composition.close(composed)
  domain.validate_document(after.persona.document) |> should.be_ok
  store.close(db)
}

pub fn optional_install_never_adds_tables_to_quarantined_legacy_identity_test() -> Nil {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE personality_persona(id TEXT); INSERT INTO personality_persona VALUES('legacy data')",
    )
  lessons.initialise(db) |> should.be_error
  let assert Ok(tables) =
    store.read(
      db,
      "SELECT name FROM sqlite_master WHERE name LIKE 'personality_%'",
      [],
      decode.field(0, decode.string, decode.success),
    )
  tables |> should.equal(["personality_persona"])
  store.close(db)
}

pub fn damaged_optional_schema_is_not_recreated_test() -> Nil {
  let db = setup()
  lessons.initialise(db) |> should.be_ok
  let assert Ok(_) =
    lessons.create(
      db,
      "owner",
      p.OwnerAgent("saved"),
      "retained lesson",
      [],
      None,
      None,
    )
  let assert Ok(_) =
    store.query(db, store.exec(_, "DROP TABLE personality_lesson_receipt"))
  lessons.initialise(db) |> should.be_error
  let assert Ok([]) =
    store.read(
      db,
      "SELECT name FROM sqlite_master WHERE name='personality_lesson_receipt'",
      [],
      decode.dynamic,
    )
  let assert Ok([1]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM personality_lesson_revision",
      [],
      decode.field(0, decode.int, decode.success),
    )
  ledger.capture(db, "owner") |> should.be_ok
  store.close(db)
}

pub fn lesson_receipt_survives_rebinding_without_copying_the_lesson_test() -> Nil {
  let db = setup()
  lessons.initialise(db) |> should.be_ok
  let assert Ok(created) =
    lessons.create(
      db,
      "owner",
      p.OwnerAgent("create"),
      "learned",
      [],
      None,
      None,
    )
  let assert Ok(before) = ledger.capture(db, "owner")
  let assert Ok(other) = ledger.create(db, "other", "separate", True, False)
  ledger.bind(db, "owner", other.id, before.binding.generation, 0, [])
  |> should.be_ok
  lessons.recover(db, "owner", "create")
  |> should.equal(Ok(Some(json.to_string(lessons.to_json(created)))))
  lessons.create(db, "owner", p.OwnerAgent("create"), "learned", [], None, None)
  |> should.equal(Ok(created))
  lessons.read(db, "owner", created.id) |> should.equal(Error(p.NotFound))
  let assert Ok(rows) = lessons.query(db, "owner", "", [], False, 0, 20)
  rows.records |> should.equal([])
  store.close(db)
}

pub fn optional_install_rejects_damaged_identity_even_with_schema_marker_test() -> Nil {
  let db = setup()
  let assert Ok(_) =
    store.query(db, store.exec(
      _,
      "ALTER TABLE personality_revision RENAME TO retained_revision",
    ))
  lessons.initialise(db) |> should.be_error
  let assert Ok([]) =
    store.read(
      db,
      "SELECT name FROM sqlite_master WHERE name LIKE 'personality_lesson%'",
      [],
      decode.dynamic,
    )
  let assert Ok([1]) =
    store.read(
      db,
      "SELECT COUNT(*) FROM retained_revision",
      [],
      decode.field(0, decode.int, decode.success),
    )
  store.close(db)
}
