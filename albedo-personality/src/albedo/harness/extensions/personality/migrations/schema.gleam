//// Extension-owned schema. Installation is atomic and creates no identity.

import albedo/daemon/store
import albedo/harness/extensions/personality/read_tokens
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
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
    use _ <- result.try(store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS personality_memory(id TEXT PRIMARY KEY,persona_id TEXT NOT NULL REFERENCES personality_persona(id),revision INTEGER NOT NULL CHECK(revision>0),lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','retracted')),importance INTEGER NOT NULL CHECK(importance BETWEEN 0 AND 3),tags TEXT NOT NULL,temporal_scope TEXT NOT NULL,unresolved INTEGER NOT NULL CHECK(unresolved IN (0,1))); CREATE INDEX IF NOT EXISTS personality_memory_scope ON personality_memory(persona_id,lifecycle,id); CREATE TABLE IF NOT EXISTS personality_memory_revision(persona_id TEXT NOT NULL REFERENCES personality_persona(id),memory_id TEXT NOT NULL REFERENCES personality_memory(id),revision INTEGER NOT NULL,text TEXT NOT NULL,provenance TEXT NOT NULL,uncertainty TEXT NOT NULL,author TEXT NOT NULL,origin_session TEXT NOT NULL,event_id INTEGER NOT NULL REFERENCES personality_event(id),reason TEXT NOT NULL,lifecycle TEXT NOT NULL,importance INTEGER NOT NULL,tags TEXT NOT NULL,temporal_scope TEXT NOT NULL,unresolved INTEGER NOT NULL,PRIMARY KEY(persona_id,memory_id,revision)); CREATE TABLE IF NOT EXISTS personality_source(id TEXT PRIMARY KEY,persona_id TEXT NOT NULL REFERENCES personality_persona(id),session TEXT NOT NULL,first_seq INTEGER NOT NULL,last_seq INTEGER NOT NULL,digest TEXT NOT NULL,actors TEXT NOT NULL,origin TEXT NOT NULL,binding_revision INTEGER NOT NULL,pre_binding_through INTEGER NOT NULL,lcm_hint TEXT,availability TEXT NOT NULL DEFAULT 'available' CHECK(availability IN ('available','unavailable'))); CREATE INDEX IF NOT EXISTS personality_source_scope ON personality_source(persona_id,id); CREATE TABLE IF NOT EXISTS personality_memory_source(persona_id TEXT NOT NULL,memory_id TEXT NOT NULL,revision INTEGER NOT NULL,source_id TEXT NOT NULL REFERENCES personality_source(id),relation TEXT NOT NULL CHECK(relation IN ('supports','contradicts','corrects')),PRIMARY KEY(persona_id,memory_id,revision,source_id,relation),FOREIGN KEY(persona_id,memory_id,revision) REFERENCES personality_memory_revision(persona_id,memory_id,revision));",
    ))
    use _ <- result.try(
      store.add_columns(db, "personality_memory", [
        #("event_id", "INTEGER NOT NULL DEFAULT 0 CHECK(event_id>=0)"),
        #("search_text", "TEXT NOT NULL DEFAULT ''"),
      ]),
    )
    use _ <- result.try(store.exec(
      db,
      "CREATE INDEX IF NOT EXISTS personality_memory_source_pointer ON personality_memory_source(persona_id,source_id,memory_id,revision); CREATE INDEX IF NOT EXISTS personality_memory_unresolved ON personality_memory(persona_id,lifecycle,unresolved,event_id DESC,id); CREATE INDEX IF NOT EXISTS personality_memory_recent ON personality_memory(persona_id,lifecycle,event_id DESC,id); CREATE INDEX IF NOT EXISTS personality_memory_pinned ON personality_memory(persona_id,lifecycle,(CASE WHEN instr(lower(tags),'\"pinned\"')>0 THEN 1 ELSE 0 END),event_id DESC,id);",
    ))
    use _ <- result.try(
      store.add_columns(db, "personality_capacity", [
        #("memory_bytes", "INTEGER NOT NULL DEFAULT 0 CHECK(memory_bytes>=0)"),
        #(
          "record_limit",
          "INTEGER NOT NULL DEFAULT 10000 CHECK(record_limit>=0)",
        ),
      ]),
    )
    use _ <- result.try(read_tokens.initialise(db))
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
          #(
            "personality_memory",
            "id,persona_id,revision,lifecycle,importance,tags,temporal_scope,unresolved,event_id,search_text",
          ),
          #(
            "personality_memory_revision",
            "persona_id,memory_id,revision,text,provenance,uncertainty,author,origin_session,event_id,reason,lifecycle,importance,tags,temporal_scope,unresolved",
          ),
          #(
            "personality_source",
            "id,persona_id,session,first_seq,last_seq,digest,actors,origin,binding_revision,pre_binding_through,lcm_hint,availability",
          ),
          #(
            "personality_memory_source",
            "persona_id,memory_id,revision,source_id,relation",
          ),
          #("personality_operation", "operation_id,request,result,created_at"),
          #("personality_controls", "persona_id,field_locks"),
          #("personality_read_key", "singleton,secret,fingerprint"),
          #(
            "personality_capacity",
            "persona_id,ordinary_bytes,corrective_bytes,ordinary_limit,corrective_limit,memory_bytes,record_limit,read_token_version",
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
    use _ <- result.try(backfill_recall(db))
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
    "INSERT INTO personality_capacity(persona_id,ordinary_bytes) SELECT ?,COALESCE((SELECT SUM(length(CAST(self_description||values_text||communication||instructions||author||reason AS BLOB))) FROM personality_revision WHERE persona_id=? AND revision=1),0)+COALESCE((SELECT SUM(length(CAST(persona_id||operation_id||actor||COALESCE(origin_session,'')||event_type||base_revision||head_revision||reason||created_at AS BLOB))) FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited','memory_edited')),0)+COALESCE((SELECT SUM(length(CAST(request||result AS BLOB))) FROM personality_operation WHERE operation_id IN (SELECT operation_id FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited','memory_edited'))),0) ON CONFLICT(persona_id) DO NOTHING",
    [
      sqlight.text(persona),
      sqlight.text(persona),
      sqlight.text(persona),
      sqlight.text(persona),
    ],
  )
}

// This one-time additive migration reads only current heads, fifty at a time.
// Existing evidence, revision text, receipts, raw transcripts and LCM stay intact.
fn backfill_recall(db: sqlight.Connection) -> Result(Nil, String) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT m.id,m.persona_id,r.text,m.tags,m.temporal_scope,r.event_id FROM personality_memory m JOIN personality_memory_revision r ON r.persona_id=m.persona_id AND r.memory_id=m.id AND r.revision=m.revision WHERE m.search_text='' ORDER BY m.id LIMIT 50",
      [],
      {
        use id <- decode.field(0, decode.string)
        use persona <- decode.field(1, decode.string)
        use text <- decode.field(2, decode.string)
        use tags <- decode.field(3, decode.string)
        use scope <- decode.field(4, decode.string)
        use event <- decode.field(5, decode.int)
        decode.success(#(id, persona, text, tags, scope, event))
      },
    ),
  )
  use _ <- result.try(
    list.try_each(rows, fn(row) {
      use tags <- result.try(
        json.parse(row.3, decode.list(decode.string))
        |> result.replace_error(
          "current memory tags unreadable during recall migration",
        ),
      )
      let search =
        string.lowercase(row.2 <> " " <> string.join(tags, " ") <> " " <> row.4)
      use _ <- result.try(
        store.run(
          db,
          "UPDATE personality_memory SET search_text=?,event_id=? WHERE id=? AND persona_id=?",
          [
            sqlight.text(search),
            sqlight.int(row.5),
            sqlight.text(row.0),
            sqlight.text(row.1),
          ],
        ),
      )
      store.run(
        db,
        "UPDATE personality_capacity SET ordinary_bytes=ordinary_bytes+?,memory_bytes=memory_bytes+? WHERE persona_id=?",
        [
          sqlight.int(string.byte_size(search) + 32),
          sqlight.int(string.byte_size(search) + 32),
          sqlight.text(row.1),
        ],
      )
    }),
  )
  case rows {
    [] -> Ok(Nil)
    _ -> backfill_recall(db)
  }
}
