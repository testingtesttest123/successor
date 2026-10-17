//// Optional direct lessons. Identity capture has no dependency on this store.

import albedo/clock
import albedo/daemon/store
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Lesson {
  Lesson(
    id: String,
    revision: Int,
    content: String,
    confidence: Float,
    tags: List(String),
    evidence: List(String),
    deprecated: Bool,
    deprecation_reason: Option(String),
    actor: String,
    origin_session: String,
    created: Int,
    updated: Int,
  )
}

pub type Page {
  Page(records: List(Lesson), next_offset: Option(Int))
}

pub fn initialise(db: store.Store) -> Result(Nil, String) {
  store.query(db, fn(db) {
    store.transaction(db, fn() {
      // A quarantined core must not gain new optional tables during startup.
      use _ <- result.try(schema.validate(db))
      use existing <- result.try(store.rows(
        db,
        "SELECT name FROM main.sqlite_master WHERE name LIKE 'personality_lesson%'",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      use _ <- result.try(case existing {
        [] ->
          store.exec(
            db,
            "CREATE TABLE IF NOT EXISTS personality_lesson(id TEXT PRIMARY KEY,persona_id TEXT NOT NULL,revision INTEGER NOT NULL,search_text TEXT NOT NULL,deprecated INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS personality_lesson_revision(id TEXT NOT NULL,revision INTEGER NOT NULL,persona_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(id,revision)); CREATE TABLE IF NOT EXISTS personality_lesson_receipt(session TEXT NOT NULL,call_id TEXT NOT NULL,persona_id TEXT NOT NULL,request TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(session,call_id));",
          )
        _ -> Ok(Nil)
      })
      list.try_each(
        [
          #(
            "personality_lesson",
            "id,persona_id,revision,search_text,deprecated",
          ),
          #("personality_lesson_revision", "id,revision,persona_id,payload"),
          #(
            "personality_lesson_receipt",
            "session,call_id,persona_id,request,result",
          ),
        ],
        fn(table) {
          use kind <- result.try(store.one(
            db,
            "SELECT type FROM sqlite_master WHERE name=?",
            [sqlight.text(table.0)],
            decode.field(0, decode.string, decode.success),
            "lesson table missing",
          ))
          use _ <- result.try(case kind {
            "table" -> Ok(Nil)
            _ -> Error("lesson state must be a real table")
          })
          store.run(
            db,
            "SELECT " <> table.1 <> " FROM " <> table.0 <> " LIMIT 0",
            [],
          )
        },
      )
    })
  })
}

pub fn decoder() -> decode.Decoder(Lesson) {
  use id <- decode.field("id", decode.string)
  use revision <- decode.field("revision", decode.int)
  use content <- decode.field("content", decode.string)
  use confidence <- decode.field("confidence", decode.float)
  use tags <- decode.field("tags", decode.list(decode.string))
  use evidence <- decode.field("evidence", decode.list(decode.string))
  use deprecated <- decode.field("deprecated", decode.bool)
  use reason <- decode.field(
    "deprecation_reason",
    decode.optional(decode.string),
  )
  use actor <- decode.field("actor", decode.string)
  use session <- decode.field("origin_session", decode.string)
  use created <- decode.field("created", decode.int)
  use updated <- decode.field("updated", decode.int)
  decode.success(Lesson(
    id,
    revision,
    content,
    confidence,
    tags,
    evidence,
    deprecated,
    reason,
    actor,
    session,
    created,
    updated,
  ))
}

pub fn to_json(lesson: Lesson) -> json.Json {
  json.object([
    #("id", json.string(lesson.id)),
    #("revision", json.int(lesson.revision)),
    #("content", json.string(lesson.content)),
    #("confidence", json.float(lesson.confidence)),
    #("tags", json.array(lesson.tags, json.string)),
    #("evidence", json.array(lesson.evidence, json.string)),
    #("deprecated", json.bool(lesson.deprecated)),
    #(
      "deprecation_reason",
      json.nullable(lesson.deprecation_reason, json.string),
    ),
    #("actor", json.string(lesson.actor)),
    #("origin_session", json.string(lesson.origin_session)),
    #("created", json.int(lesson.created)),
    #("updated", json.int(lesson.updated)),
  ])
}

pub fn page_json(page: Page) -> json.Json {
  json.object([
    #("records", json.array(page.records, to_json)),
    #("next_offset", json.nullable(page.next_offset, json.int)),
  ])
}

fn validate(lesson: Lesson) -> Result(Nil, p.DomainError) {
  case
    string.trim(lesson.content) != ""
    && string.byte_size(lesson.content) <= 4096
    && lesson.confidence >=. 0.0
    && lesson.confidence <=. 1.0
    && list.length(lesson.tags) <= 16
    && list.all(lesson.tags, fn(tag) {
      string.trim(tag) != "" && string.byte_size(tag) <= 128
    })
    && list.length(lesson.evidence) <= 16
    && list.all(lesson.evidence, fn(item) { string.byte_size(item) <= 1024 })
    && string.byte_size(json.to_string(to_json(lesson))) <= 32_768
  {
    True -> Ok(Nil)
    False ->
      Error(p.Invalid(
        "lesson content, confidence, tags or evidence exceeds its per-record bound",
      ))
  }
}

fn read_in(
  db: sqlight.Connection,
  persona: String,
  id: String,
) -> Result(Lesson, p.DomainError) {
  use encoded <- result.try(
    store.one(
      db,
      "SELECT r.payload FROM personality_lesson l JOIN personality_lesson_revision r ON r.id=l.id AND r.revision=l.revision WHERE l.persona_id=? AND l.id=?",
      [sqlight.text(persona), sqlight.text(id)],
      decode.field(0, decode.string, decode.success),
      "not_found",
    )
    |> result.map_error(fn(error) {
      case error {
        "not_found" -> p.NotFound
        _ -> p.Storage(error)
      }
    }),
  )
  json.parse(encoded, decoder())
  |> result.replace_error(p.Storage("corrupt lesson revision"))
}

fn mutate(
  db: store.Store,
  session: String,
  actor: p.Actor,
  request: json.Json,
  change: fn(sqlight.Connection, String) -> Result(Lesson, p.DomainError),
) -> Result(Lesson, p.DomainError) {
  let hash = domain.hash(json.to_string(request))
  let call = domain.call_id(actor)
  use _ <- result.try(
    case call != "" && call != "human:" && string.byte_size(call) <= 512 {
      True -> Ok(Nil)
      False -> Error(p.Invalid("trusted lesson call identity missing"))
    },
  )
  store.query(db, fn(db) {
    ledger.transaction(db, fn() {
      use captured <- result.try(ledger.capture_in(db, session))
      let persona = captured.persona.id
      use receipts <- result.try(
        store.rows(
          db,
          "SELECT request,result FROM personality_lesson_receipt WHERE session=? AND call_id=?",
          [sqlight.text(session), sqlight.text(call)],
          {
            use request <- decode.field(0, decode.string)
            use result <- decode.field(1, decode.string)
            decode.success(#(request, result))
          },
        )
        |> result.map_error(p.Storage),
      )
      case receipts {
        [#(old, result)] if old == hash ->
          json.parse(result, decoder())
          |> result.replace_error(p.Storage("corrupt lesson receipt"))
        [_] -> Error(p.CallReused)
        [] -> {
          use lesson <- result.try(change(db, persona))
          let lesson =
            Lesson(
              ..lesson,
              actor: domain.actor_name(actor),
              origin_session: session,
              updated: clock.system_ms(),
            )
          use _ <- result.try(validate(lesson))
          let encoded = json.to_string(to_json(lesson))
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_lesson(id,persona_id,revision,search_text,deprecated) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,search_text=excluded.search_text,deprecated=excluded.deprecated",
              [
                sqlight.text(lesson.id),
                sqlight.text(persona),
                sqlight.int(lesson.revision),
                sqlight.text(string.lowercase(
                  lesson.content <> " " <> string.join(lesson.tags, " "),
                )),
                sqlight.bool(lesson.deprecated),
              ],
            )
            |> result.map_error(p.Storage),
          )
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_lesson_revision VALUES(?,?,?,?)",
              [
                sqlight.text(lesson.id),
                sqlight.int(lesson.revision),
                sqlight.text(persona),
                sqlight.text(encoded),
              ],
            )
            |> result.map_error(p.Storage),
          )
          use _ <- result.map(
            store.run(
              db,
              "INSERT INTO personality_lesson_receipt VALUES(?,?,?,?,?)",
              [
                sqlight.text(session),
                sqlight.text(call),
                sqlight.text(persona),
                sqlight.text(hash),
                sqlight.text(encoded),
              ],
            )
            |> result.map_error(p.Storage),
          )
          lesson
        }
        _ -> Error(p.Storage("duplicate lesson receipt"))
      }
    })
  })
}

pub fn create(
  db: store.Store,
  session: String,
  actor: p.Actor,
  content: String,
  tags: List(String),
  confidence: Option(Float),
  evidence: Option(List(String)),
) -> Result(Lesson, p.DomainError) {
  let confidence = option.unwrap(confidence, 0.5)
  let evidence = option.unwrap(evidence, [])
  let request =
    json.object([
      #("action", json.string("create")),
      #("content", json.string(content)),
      #("tags", json.array(tags, json.string)),
      #("confidence", json.float(confidence)),
      #("evidence", json.array(evidence, json.string)),
      #("actor", json.string(domain.actor_name(actor))),
    ])
  mutate(db, session, actor, request, fn(_, _) {
    Ok(Lesson(
      ledger.new_id(),
      1,
      content,
      confidence,
      tags,
      evidence,
      False,
      None,
      "",
      "",
      clock.system_ms(),
      clock.system_ms(),
    ))
  })
}

pub fn update(
  db: store.Store,
  session: String,
  actor: p.Actor,
  id: String,
  content: Option(String),
  tags: Option(List(String)),
  confidence: Option(Float),
  evidence: Option(List(String)),
) -> Result(Lesson, p.DomainError) {
  let request =
    json.object([
      #("action", json.string("update")),
      #("id", json.string(id)),
      #("content", json.nullable(content, json.string)),
      #(
        "tags",
        json.nullable(tags, fn(items) { json.array(items, json.string) }),
      ),
      #("confidence", json.nullable(confidence, json.float)),
      #(
        "evidence",
        json.nullable(evidence, fn(items) { json.array(items, json.string) }),
      ),
      #("actor", json.string(domain.actor_name(actor))),
    ])
  mutate(db, session, actor, request, fn(db, persona) {
    use old <- result.map(read_in(db, persona, id))
    Lesson(
      ..old,
      revision: old.revision + 1,
      content: option.unwrap(content, old.content),
      tags: option.unwrap(tags, old.tags),
      confidence: option.unwrap(confidence, old.confidence),
      evidence: list.unique(list.append(
        old.evidence,
        option.unwrap(evidence, []),
      )),
    )
  })
}

pub fn deprecate(
  db: store.Store,
  session: String,
  actor: p.Actor,
  id: String,
  reason: String,
) -> Result(Lesson, p.DomainError) {
  use _ <- result.try(
    case string.trim(reason) != "" && string.byte_size(reason) <= 4096 {
      True -> Ok(Nil)
      False ->
        Error(p.Invalid("deprecation reason must be nonempty and bounded"))
    },
  )
  mutate(
    db,
    session,
    actor,
    json.object([
      #("action", json.string("deprecate")),
      #("id", json.string(id)),
      #("reason", json.string(reason)),
      #("actor", json.string(domain.actor_name(actor))),
    ]),
    fn(db, persona) {
      use old <- result.map(read_in(db, persona, id))
      Lesson(
        ..old,
        revision: old.revision + 1,
        deprecated: True,
        deprecation_reason: Some(reason),
      )
    },
  )
}

pub fn read(
  db: store.Store,
  session: String,
  id: String,
) -> Result(Lesson, p.DomainError) {
  store.query(db, fn(db) {
    use captured <- result.try(ledger.capture_in(db, session))
    read_in(db, captured.persona.id, id)
  })
}

pub fn query(
  db: store.Store,
  session: String,
  text: String,
  tags: List(String),
  include_deprecated: Bool,
  offset: Int,
  limit: Int,
) -> Result(Page, p.DomainError) {
  use _ <- result.try(valid_page(offset, limit))
  use _ <- result.try(
    case
      string.byte_size(text) <= 4096
      && list.length(tags) <= 16
      && list.all(tags, fn(tag) { string.byte_size(tag) <= 128 })
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("lesson query exceeds input bound"))
    },
  )
  store.query(db, fn(db) {
    use captured <- result.try(ledger.capture_in(db, session))
    let conditions =
      string.concat(
        list.map(tags, fn(_) {
          " AND EXISTS(SELECT 1 FROM json_each(json_extract(r.payload,'$.tags')) WHERE value=?)"
        }),
      )
    use rows <- result.try(
      store.rows(
        db,
        "SELECT r.payload FROM personality_lesson l JOIN personality_lesson_revision r ON r.id=l.id AND r.revision=l.revision WHERE l.persona_id=? AND (? OR l.deprecated=0) AND instr(l.search_text,?)>0"
          <> conditions
          <> " ORDER BY l.id LIMIT ? OFFSET ?",
        [
          sqlight.text(captured.persona.id),
          sqlight.bool(include_deprecated),
          sqlight.text(string.lowercase(text)),
          ..list.append(list.map(tags, sqlight.text), [
            sqlight.int(limit + 1),
            sqlight.int(offset),
          ])
        ],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map_error(p.Storage),
    )
    page(rows, offset, limit)
  })
}

pub fn history(
  db: store.Store,
  session: String,
  id: String,
  offset: Int,
  limit: Int,
) -> Result(Page, p.DomainError) {
  use _ <- result.try(valid_page(offset, limit))
  store.query(db, fn(db) {
    use captured <- result.try(ledger.capture_in(db, session))
    use _ <- result.try(read_in(db, captured.persona.id, id))
    use rows <- result.try(
      store.rows(
        db,
        "SELECT payload FROM personality_lesson_revision WHERE persona_id=? AND id=? ORDER BY revision LIMIT ? OFFSET ?",
        [
          sqlight.text(captured.persona.id),
          sqlight.text(id),
          sqlight.int(limit + 1),
          sqlight.int(offset),
        ],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map_error(p.Storage),
    )
    page(rows, offset, limit)
  })
}

fn valid_page(offset: Int, limit: Int) -> Result(Nil, p.DomainError) {
  case offset >= 0 && limit > 0 && limit <= 20 {
    True -> Ok(Nil)
    False ->
      Error(p.Invalid("lesson page limit must be 1..20 and offset nonnegative"))
  }
}

fn page(
  rows: List(String),
  offset: Int,
  limit: Int,
) -> Result(Page, p.DomainError) {
  use records <- result.map(
    list.try_map(list.take(rows, limit), fn(row) {
      json.parse(row, decoder())
      |> result.replace_error(p.Storage("corrupt lesson revision"))
    }),
  )
  Page(records, case list.length(rows) > limit {
    True -> Some(offset + limit)
    False -> None
  })
}

pub fn recover(
  db: store.Store,
  session: String,
  call: String,
) -> Result(Option(String), p.DomainError) {
  store.query(db, fn(db) {
    store.rows(
      db,
      "SELECT result FROM personality_lesson_receipt WHERE session=? AND call_id=?",
      [sqlight.text(session), sqlight.text(call)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map(fn(rows) { list.first(rows) |> option.from_result })
    |> result.map_error(p.Storage)
  })
}
