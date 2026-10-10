//// Extension-owned schema. Installation is atomic and creates no identity.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.transaction(db, fn() {
    use _ <- result.try(store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS personality_persona(id TEXT PRIMARY KEY,name TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('active','archived')),revision INTEGER NOT NULL CHECK(revision>0),identity_revision INTEGER NOT NULL CHECK(identity_revision>0),creation_operation TEXT NOT NULL UNIQUE,agent_identity_edits INTEGER NOT NULL CHECK(agent_identity_edits IN (0,1)),agent_memory_edits INTEGER NOT NULL CHECK(agent_memory_edits IN (0,1))); CREATE TABLE IF NOT EXISTS personality_revision(persona_id TEXT NOT NULL REFERENCES personality_persona(id),revision INTEGER NOT NULL,self_description TEXT NOT NULL,values_text TEXT NOT NULL,communication TEXT NOT NULL,instructions TEXT NOT NULL,author TEXT NOT NULL,origin_session TEXT,reason TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(persona_id,revision)); CREATE TABLE IF NOT EXISTS personality_default(singleton INTEGER PRIMARY KEY CHECK(singleton=1),persona_id TEXT NOT NULL REFERENCES personality_persona(id)); CREATE TABLE IF NOT EXISTS personality_session(session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,persona_id TEXT REFERENCES personality_persona(id),mode TEXT NOT NULL CHECK(mode IN ('owner','delegate')),binding_revision INTEGER NOT NULL CHECK(binding_revision>0),pre_binding_through INTEGER NOT NULL CHECK(pre_binding_through>=0),authority TEXT NOT NULL CHECK(authority='user')); CREATE INDEX IF NOT EXISTS personality_session_persona ON personality_session(persona_id); CREATE TABLE IF NOT EXISTS personality_event(id INTEGER PRIMARY KEY AUTOINCREMENT,persona_id TEXT NOT NULL REFERENCES personality_persona(id),operation_id TEXT NOT NULL,actor TEXT NOT NULL,origin_session TEXT,event_type TEXT NOT NULL,base_revision INTEGER NOT NULL,head_revision INTEGER NOT NULL,reason TEXT NOT NULL,created_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS personality_operation(operation_id TEXT PRIMARY KEY,request TEXT NOT NULL,result TEXT NOT NULL,created_at INTEGER NOT NULL);",
    ))
    use _ <- result.try(store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS personality_controls(persona_id TEXT PRIMARY KEY REFERENCES personality_persona(id),field_locks TEXT NOT NULL); CREATE TABLE IF NOT EXISTS personality_capacity(persona_id TEXT PRIMARY KEY REFERENCES personality_persona(id),ordinary_bytes INTEGER NOT NULL DEFAULT 0 CHECK(ordinary_bytes>=0),corrective_bytes INTEGER NOT NULL DEFAULT 0 CHECK(corrective_bytes>=0),ordinary_limit INTEGER NOT NULL DEFAULT 104857600 CHECK(ordinary_limit>=0),corrective_limit INTEGER NOT NULL DEFAULT 10485760 CHECK(corrective_limit>=0)); CREATE TABLE IF NOT EXISTS personality_tool_receipt(persona_id TEXT NOT NULL REFERENCES personality_persona(id),session TEXT NOT NULL,call_id TEXT NOT NULL,operation_key TEXT NOT NULL REFERENCES personality_operation(operation_id),result TEXT NOT NULL,PRIMARY KEY(persona_id,session,call_id)); CREATE INDEX IF NOT EXISTS personality_event_persona ON personality_event(persona_id);",
    ))
    // CREATE IF NOT EXISTS may leave an existing malformed relation untouched.
    // Check the real main-schema tables and every used column before committing
    // any new schema. Failure preserves existing data and quarantines the bundle.
    use _ <- result.try(
      list.try_each(
        [
          #(
            "personality_persona",
            "id,name,state,revision,identity_revision,creation_operation,agent_identity_edits,agent_memory_edits",
          ),
          #(
            "personality_revision",
            "persona_id,revision,self_description,values_text,communication,instructions,author,origin_session,reason,created_at",
          ),
          #("personality_default", "singleton,persona_id"),
          #(
            "personality_session",
            "session,persona_id,mode,binding_revision,pre_binding_through,authority",
          ),
          #(
            "personality_event",
            "id,persona_id,operation_id,actor,origin_session,event_type,base_revision,head_revision,reason,created_at",
          ),
          #("personality_operation", "operation_id,request,result,created_at"),
          #("personality_controls", "persona_id,field_locks"),
          #(
            "personality_capacity",
            "persona_id,ordinary_bytes,corrective_bytes,ordinary_limit,corrective_limit",
          ),
          #(
            "personality_tool_receipt",
            "persona_id,session,call_id,operation_key,result",
          ),
        ],
        fn(table) {
          let #(name, columns) = table
          use kind <- result.try(store.one(
            db,
            "SELECT type FROM main.sqlite_master WHERE name=?",
            [sqlight.text(name)],
            decode.field(0, decode.string, decode.success),
            "personality table is missing: " <> name,
          ))
          use _ <- result.try(case kind {
            "table" -> Ok(Nil)
            _ -> Error("personality state must be a real table: " <> name)
          })
          // Names and columns are fixed internal schema constants, never input.
          store.run(
            db,
            "SELECT " <> columns <> " FROM main." <> name <> " LIMIT 0",
            [],
          )
        },
      ),
    )
    use personas <- result.try(store.rows(
      db,
      "SELECT id FROM personality_persona",
      [],
      decode.field(0, decode.string, decode.success),
    ))
    list.try_each(personas, capacity(db, _))
  })
}

pub fn capacity(
  db: sqlight.Connection,
  persona: String,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO personality_capacity(persona_id,ordinary_bytes) SELECT ?,COALESCE((SELECT SUM(length(CAST(self_description||values_text||communication||instructions||author||reason AS BLOB))) FROM personality_revision WHERE persona_id=? AND revision=1),0)+COALESCE((SELECT SUM(length(CAST(persona_id||operation_id||actor||COALESCE(origin_session,'')||event_type||base_revision||head_revision||reason||created_at AS BLOB))) FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited')),0)+COALESCE((SELECT SUM(length(CAST(request||result AS BLOB))) FROM personality_operation WHERE operation_id IN (SELECT operation_id FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited'))),0) ON CONFLICT(persona_id) DO NOTHING",
    [
      sqlight.text(persona),
      sqlight.text(persona),
      sqlight.text(persona),
      sqlight.text(persona),
    ],
  )
}
