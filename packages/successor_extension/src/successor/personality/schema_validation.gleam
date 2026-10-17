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
