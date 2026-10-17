//// Fresh identity storage only. Existing state is validated without repair.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/result
import sqlight
import successor/personality/schema_validation

const fresh_schema =
  "CREATE TABLE personality_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL); INSERT INTO personality_meta VALUES(1,2); CREATE TABLE personality_persona(id TEXT PRIMARY KEY,name TEXT NOT NULL,identity_revision INTEGER NOT NULL CHECK(identity_revision>0),writable INTEGER NOT NULL CHECK(writable IN (0,1))); CREATE TABLE personality_revision(persona_id TEXT NOT NULL REFERENCES personality_persona(id),revision INTEGER NOT NULL,document TEXT NOT NULL,actor TEXT NOT NULL,origin_session TEXT NOT NULL,call_id TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(persona_id,revision)); CREATE TABLE personality_default(singleton INTEGER PRIMARY KEY CHECK(singleton=1),persona_id TEXT NOT NULL REFERENCES personality_persona(id)); CREATE TABLE personality_session(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,persona_id TEXT NOT NULL REFERENCES personality_persona(id),mode TEXT NOT NULL CHECK(mode IN ('owner','delegate')),generation INTEGER NOT NULL CHECK(generation>0),pre_binding_through INTEGER NOT NULL CHECK(pre_binding_through>=0)); CREATE INDEX personality_session_persona ON personality_session(persona_id); CREATE TABLE personality_binding_revision(session TEXT NOT NULL,generation INTEGER NOT NULL,persona_id TEXT NOT NULL,mode TEXT NOT NULL,pre_binding_through INTEGER NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(session,generation)); CREATE TABLE personality_tool_receipt(session TEXT NOT NULL,call_id TEXT NOT NULL,persona_id TEXT NOT NULL REFERENCES personality_persona(id),request TEXT NOT NULL,result TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(session,call_id)); CREATE TABLE personality_setup_receipt(retry_key TEXT PRIMARY KEY,request TEXT NOT NULL,result TEXT NOT NULL,created_at INTEGER NOT NULL);"

/// Install owned v2 tables only when the identity namespace is absent.
/// Existing tables, views and other namespace artifacts are never upgraded.
pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.transaction(db, fn() {
    use existing <- result.try(store.rows(
      db,
      "SELECT name FROM main.sqlite_master WHERE name GLOB 'personality_*'",
      [],
      decode.field(0, decode.string, decode.success),
    ))
    use _ <- result.try(case existing {
      [] -> store.exec(db, fresh_schema)
      _ -> Ok(Nil)
    })
    schema_validation.validate(db)
  })
}
