//// Fresh experimental stores only. Existing or damaged schemas are never rewritten.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

const tables = [
  #("personality_meta", "singleton,version"),
  #("personality_persona", "id,name,identity_revision,writable"),
  #(
    "personality_revision",
    "persona_id,revision,document,actor,origin_session,call_id,created_at",
  ),
  #("personality_default", "singleton,persona_id"),
  #(
    "personality_session",
    "session,persona_id,mode,generation,pre_binding_through",
  ),
  #(
    "personality_binding_revision",
    "session,generation,persona_id,mode,pre_binding_through,created_at",
  ),
  #(
    "personality_tool_receipt",
    "session,call_id,persona_id,request,result,created_at",
  ),
  #("personality_setup_receipt", "retry_key,request,result,created_at"),
]

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.transaction(db, fn() {
    use existing <- result.try(store.rows(
      db,
      "SELECT name FROM main.sqlite_master WHERE name LIKE 'personality_%' AND name NOT LIKE 'personality_lesson%'",
      [],
      decode.field(0, decode.string, decode.success),
    ))
    use _ <- result.try(case existing {
      [] ->
        store.exec(
          db,
          "CREATE TABLE personality_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL); INSERT INTO personality_meta VALUES(1,2); CREATE TABLE personality_persona(id TEXT PRIMARY KEY,name TEXT NOT NULL,identity_revision INTEGER NOT NULL CHECK(identity_revision>0),writable INTEGER NOT NULL CHECK(writable IN (0,1))); CREATE TABLE personality_revision(persona_id TEXT NOT NULL REFERENCES personality_persona(id),revision INTEGER NOT NULL,document TEXT NOT NULL,actor TEXT NOT NULL,origin_session TEXT NOT NULL,call_id TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(persona_id,revision)); CREATE TABLE personality_default(singleton INTEGER PRIMARY KEY CHECK(singleton=1),persona_id TEXT NOT NULL REFERENCES personality_persona(id)); CREATE TABLE personality_session(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,persona_id TEXT NOT NULL REFERENCES personality_persona(id),mode TEXT NOT NULL CHECK(mode IN ('owner','delegate')),generation INTEGER NOT NULL CHECK(generation>0),pre_binding_through INTEGER NOT NULL CHECK(pre_binding_through>=0)); CREATE INDEX personality_session_persona ON personality_session(persona_id); CREATE TABLE personality_binding_revision(session TEXT NOT NULL,generation INTEGER NOT NULL,persona_id TEXT NOT NULL,mode TEXT NOT NULL,pre_binding_through INTEGER NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(session,generation)); CREATE TABLE personality_tool_receipt(session TEXT NOT NULL,call_id TEXT NOT NULL,persona_id TEXT NOT NULL REFERENCES personality_persona(id),request TEXT NOT NULL,result TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(session,call_id)); CREATE TABLE personality_setup_receipt(retry_key TEXT PRIMARY KEY,request TEXT NOT NULL,result TEXT NOT NULL,created_at INTEGER NOT NULL);",
        )
      _ -> {
        use _ <- result.try(case list.contains(existing, "personality_meta") {
          True -> Ok(Nil)
          False ->
            Error(
              "legacy personality schema requires a separately reviewed lossless migration; data left intact",
            )
        })
        use version <- result.try(store.one(
          db,
          "SELECT version FROM personality_meta WHERE singleton=1",
          [],
          decode.field(0, decode.int, decode.success),
          "personality schema marker missing",
        ))
        case version {
          2 -> Ok(Nil)
          _ -> Error("unsupported personality schema; data left intact")
        }
      }
    })
    validate(db)
  })
}

/// Read-only integrity check shared by request capture and optional installation.
pub fn validate(db: sqlight.Connection) -> Result(Nil, String) {
  use version <- result.try(store.one(
    db,
    "SELECT version FROM main.personality_meta WHERE singleton=1",
    [],
    decode.field(0, decode.int, decode.success),
    "personality schema marker missing",
  ))
  use _ <- result.try(case version {
    2 -> Ok(Nil)
    _ -> Error("unsupported personality schema; data left intact")
  })
  list.try_each(tables, fn(table) {
    use kind <- result.try(store.one(
      db,
      "SELECT type FROM main.sqlite_master WHERE name=?",
      [sqlight.text(table.0)],
      decode.field(0, decode.string, decode.success),
      "personality table missing: " <> table.0,
    ))
    use _ <- result.try(case kind {
      "table" -> Ok(Nil)
      _ -> Error("personality state must be a real table: " <> table.0)
    })
    store.run(
      db,
      "SELECT " <> table.1 <> " FROM main." <> table.0 <> " LIMIT 0",
      [],
    )
  })
}
