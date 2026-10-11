//// Store-owned living documents, binding boundaries and atomic native receipts.

import albedo/clock
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions/personality/bindings
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, schema.apply)
}

/// Trusted native lifecycle only. The caller owns the creation transaction.
/// Core callers use the acyclic primitive directly; no model route exposes it.
pub fn inherit_binding_in(
  db: sqlight.Connection,
  parent: String,
  child: String,
  kind: bindings.Kind,
) -> Result(Nil, String) {
  bindings.inherit_in(db, parent, child, kind)
}

@external(erlang, "albedo_native", "new_id")
pub fn new_id() -> String

fn persona_decoder() -> decode.Decoder(p.Persona) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use revision <- decode.field(2, decode.int)
  use document <- decode.field(3, decode.string)
  use writable <- decode.field(4, sqlight.decode_bool())
  decode.success(p.Persona(id, name, revision, document, writable))
}

fn persona_in(
  db: sqlight.Connection,
  id: String,
) -> Result(p.Persona, p.DomainError) {
  use persona <- result.try(
    store.one(
      db,
      "SELECT p.id,p.name,p.identity_revision,r.document,p.writable FROM personality_persona p JOIN personality_revision r ON r.persona_id=p.id AND r.revision=p.identity_revision WHERE p.id=?",
      [sqlight.text(id)],
      persona_decoder(),
      "not_found",
    )
    |> result.map_error(storage),
  )
  use _ <- result.map(domain.validate_document(persona.document))
  persona
}

fn storage(error: String) -> p.DomainError {
  case error {
    "not_found" -> p.NotFound
    _ -> p.Storage(error)
  }
}

fn binding_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Option(p.Binding), p.DomainError) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT persona_id,mode,generation,pre_binding_through FROM personality_session WHERE session=?",
      [sqlight.text(session)],
      {
        use persona <- decode.field(0, decode.string)
        use mode <- decode.field(1, decode.string)
        use generation <- decode.field(2, decode.int)
        use through <- decode.field(3, decode.int)
        decode.success(p.Binding(session, persona, mode, generation, through))
      },
    )
    |> result.map_error(p.Storage),
  )
  case rows {
    [] -> Ok(None)
    [binding] -> Ok(Some(binding))
    _ -> Error(p.Storage("duplicate binding"))
  }
}

pub fn capture_in(
  db: sqlight.Connection,
  session: String,
) -> Result(p.Captured, p.DomainError) {
  use _ <- result.try(schema.validate(db) |> result.map_error(p.Storage))
  use binding <- result.try(binding_in(db, session))
  use binding <- result.try(option.to_result(binding, p.SetupRequired))
  use persona <- result.map(persona_in(db, binding.persona_id))
  p.Captured(persona, binding)
}

/// Read-only, one store turn; optional lessons never participate.
pub fn capture(
  ledger: store.Store,
  session: String,
) -> Result(p.Captured, p.DomainError) {
  store.query(ledger, capture_in(_, session))
}

fn boundary_in(
  db: sqlight.Connection,
  session: String,
) -> Result(#(Int, Int), p.DomainError) {
  store.one(
    db,
    "SELECT COALESCE((SELECT MAX(seq) FROM transcript WHERE session=s.id),0),(SELECT COUNT(*) FROM transcript WHERE session=s.id) FROM sessions s WHERE id=?",
    [sqlight.text(session)],
    {
      use through <- decode.field(0, decode.int)
      use count <- decode.field(1, decode.int)
      decode.success(#(through, count))
    },
    "not_found",
  )
  |> result.map_error(storage)
}

fn owner_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, p.DomainError) {
  use children <- result.try(
    store.rows(
      db,
      "SELECT parent FROM session_family WHERE session=? AND parent IS NOT NULL",
      [sqlight.text(session)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map_error(p.Storage),
  )
  case children {
    [] -> Ok(Nil)
    _ ->
      Error(p.Forbidden(
        "permanent identity setup is human-only on an owner session",
      ))
  }
}

fn default_in(db: sqlight.Connection) -> Result(Option(String), p.DomainError) {
  store.rows(
    db,
    "SELECT persona_id FROM personality_default WHERE singleton=1",
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
  |> result.map_error(p.Storage)
}

fn bind_in(
  db: sqlight.Connection,
  session: String,
  persona: String,
  expected: Int,
  through: Int,
  declarations: List(extension.Extension),
) -> Result(p.Binding, p.DomainError) {
  use _ <- result.try(binding_selection_in(db, session, declarations))
  use _ <- result.try(owner_in(db, session))
  use boundary <- result.try(boundary_in(db, session))
  use _ <- result.try(case boundary.0 == through {
    True -> Ok(Nil)
    False -> Error(p.Conflict("history_changed"))
  })
  use current <- result.try(binding_in(db, session))
  let generation =
    option.map(current, fn(value) { value.generation }) |> option.unwrap(0)
  use _ <- result.try(case expected == generation {
    True -> Ok(Nil)
    False -> Error(p.Conflict("binding_changed"))
  })
  use _ <- result.try(persona_in(db, persona))
  let binding = p.Binding(session, persona, "owner", generation + 1, through)
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_session(session,persona_id,mode,generation,pre_binding_through) VALUES(?,?,'owner',?,?) ON CONFLICT(session) DO UPDATE SET persona_id=excluded.persona_id,mode=excluded.mode,generation=excluded.generation,pre_binding_through=excluded.pre_binding_through",
      [
        sqlight.text(session),
        sqlight.text(persona),
        sqlight.int(binding.generation),
        sqlight.int(through),
      ],
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_binding_revision(session,generation,persona_id,mode,pre_binding_through,created_at) VALUES(?,?,?,'owner',?,?)",
      [
        sqlight.text(session),
        sqlight.int(binding.generation),
        sqlight.text(persona),
        sqlight.int(through),
        sqlight.int(clock.system_ms()),
      ],
    )
    |> result.map_error(p.Storage),
  )
  // Pin the selected bundle so later global defaults cannot replace a bound self.
  // This is a native selection change, so invalidate its prepared CAS basis.
  use _ <- result.try(
    store.run(
      db,
      "UPDATE sessions SET config_revision=config_revision+1 WHERE id=? AND NOT EXISTS(SELECT 1 FROM session_extensions WHERE session=? AND name='personality' AND enabled=1)",
      [sqlight.text(session), sqlight.text(session)],
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.map(
    store.run(
      db,
      "INSERT INTO session_extensions(session,name,enabled) VALUES(?,'personality',1) ON CONFLICT(session,name) DO UPDATE SET enabled=1",
      [sqlight.text(session)],
    )
    |> result.map_error(p.Storage),
  )
  binding
}

fn binding_selection_in(
  db: sqlight.Connection,
  session: String,
  declarations: List(extension.Extension),
) -> Result(Nil, p.DomainError) {
  use explicit <- result.try(
    store.rows(
      db,
      "SELECT name FROM session_extensions WHERE session=? AND enabled=1",
      [sqlight.text(session)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map_error(p.Storage),
  )
  case
    list.any(declarations, fn(item) {
      item.name != "personality"
      && selection.is_compaction(item)
      && list.contains(explicit, item.name)
    })
  {
    True -> Error(p.Conflict("compaction_selection_conflict"))
    False -> Ok(Nil)
  }
}

/// Authenticated human adapter calls this inside its idle bridge.
pub fn bind(
  ledger: store.Store,
  session: String,
  persona_id: String,
  expected_generation: Int,
  acknowledge_history_through: Int,
  declarations: List(extension.Extension),
) -> Result(p.Binding, p.DomainError) {
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use persona <- result.try(case persona_id {
        "" -> {
          use chosen <- result.try(default_in(db))
          option.to_result(chosen, p.SetupRequired)
        }
        _ -> Ok(persona_id)
      })
      bind_in(
        db,
        session,
        persona,
        expected_generation,
        acknowledge_history_through,
        declarations,
      )
    })
  })
}

/// Called by managed preparation before the first transcript admission.
pub fn resolve_fresh_binding(
  ledger: store.Store,
  session: String,
) -> Result(p.Binding, p.DomainError) {
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use current <- result.try(binding_in(db, session))
      case current {
        Some(binding) -> Ok(binding)
        None -> {
          use _ <- result.try(owner_in(db, session))
          use boundary <- result.try(boundary_in(db, session))
          use _ <- result.try(case boundary.1 == 0 {
            True -> Ok(Nil)
            False ->
              Error(p.Conflict(
                "existing transcript requires explicit attachment",
              ))
          })
          use chosen <- result.try(default_in(db))
          use chosen <- result.try(option.to_result(chosen, p.SetupRequired))
          // Native managed preparation has already validated its selected strategy.
          bind_in(db, session, chosen, 0, 0, [])
        }
      }
    })
  })
}

fn create_in(
  db: sqlight.Connection,
  name: String,
  content: String,
  writable: Bool,
  make_default: Bool,
) -> Result(p.Persona, p.DomainError) {
  use _ <- result.try(domain.validate_document(content))
  use _ <- result.try(
    case string.trim(name) != "" && string.byte_size(name) <= 256 {
      True -> Ok(Nil)
      False ->
        Error(p.Invalid("name must be nonempty and at most 256 UTF-8 bytes"))
    },
  )
  let id = new_id()
  use _ <- result.try(
    store.run(db, "INSERT INTO personality_persona VALUES(?,?,1,?)", [
      sqlight.text(id),
      sqlight.text(name),
      sqlight.bool(writable),
    ])
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_revision VALUES(?,1,?,'user','',?,?)",
      [
        sqlight.text(id),
        sqlight.text(content),
        sqlight.text("creation:" <> id),
        sqlight.int(clock.system_ms()),
      ],
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(case make_default {
    True -> set_default_in(db, id)
    False -> Ok(Nil)
  })
  persona_in(db, id)
}

fn set_default_in(
  db: sqlight.Connection,
  id: String,
) -> Result(Nil, p.DomainError) {
  use _ <- result.try(persona_in(db, id))
  store.run(
    db,
    "INSERT INTO personality_default VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET persona_id=excluded.persona_id",
    [sqlight.text(id)],
  )
  |> result.map_error(p.Storage)
}

/// Deliberate permanent creation, never exposed to model tools.
pub fn create(
  ledger: store.Store,
  name: String,
  content: String,
  writable: Bool,
  make_default: Bool,
) -> Result(p.Persona, p.DomainError) {
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      create_in(db, name, content, writable, make_default)
    })
  })
}

pub fn select_default(
  ledger: store.Store,
  id: String,
) -> Result(Nil, p.DomainError) {
  store.query(ledger, set_default_in(_, id))
}

/// First setup creates and binds atomically. Transport replay never creates twice.
pub fn setup(
  ledger: store.Store,
  session: String,
  name: String,
  content: String,
  writable: Bool,
  retry_key: String,
  declarations: List(extension.Extension),
) -> Result(p.Captured, p.DomainError) {
  use _ <- result.try(domain.validate_document(content))
  let request =
    json.to_string(
      json.object([
        #("session", json.string(session)),
        #("name", json.string(name)),
        #("content", json.string(content)),
        #("writable", json.bool(writable)),
      ]),
    )
  let request_hash = domain.hash(request)
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use saved <- result.try(
        store.rows(
          db,
          "SELECT request,result FROM personality_setup_receipt WHERE retry_key=?",
          [sqlight.text(retry_key)],
          {
            use request <- decode.field(0, decode.string)
            use result <- decode.field(1, decode.string)
            decode.success(#(request, result))
          },
        )
        |> result.map_error(p.Storage),
      )
      case saved {
        [#(old, id)] if old == request_hash -> {
          use persona <- result.map(first_persona_in(db, id))
          p.Captured(persona, p.Binding(session, id, "owner", 1, 0))
        }
        [_] -> Error(p.CallReused)
        [] -> {
          use _ <- result.try(owner_in(db, session))
          use boundary <- result.try(boundary_in(db, session))
          use existing <- result.try(binding_in(db, session))
          use chosen <- result.try(default_in(db))
          use _ <- result.try(
            case boundary.1 == 0 && existing == None && chosen == None {
              True -> Ok(Nil)
              False ->
                Error(p.Conflict(
                  "setup requires a fresh unbound owner session and no configured default",
                ))
            },
          )
          use _ <- result.try(binding_selection_in(db, session, declarations))
          use persona <- result.try(create_in(db, name, content, writable, True))
          use binding <- result.try(bind_in(
            db,
            session,
            persona.id,
            0,
            0,
            declarations,
          ))
          use _ <- result.map(
            store.run(
              db,
              "INSERT INTO personality_setup_receipt VALUES(?,?,?,?)",
              [
                sqlight.text(retry_key),
                sqlight.text(domain.hash(request)),
                sqlight.text(persona.id),
                sqlight.int(clock.system_ms()),
              ],
            )
            |> result.map_error(p.Storage),
          )
          p.Captured(persona, binding)
        }
        _ -> Error(p.Storage("duplicate setup receipt"))
      }
    })
  })
}

pub fn inspect(
  ledger: store.Store,
  session: String,
) -> Result(p.Inspection, p.DomainError) {
  store.query(ledger, fn(db) {
    use boundary <- result.try(boundary_in(db, session))
    use binding <- result.try(binding_in(db, session))
    use persona <- result.try(case binding {
      None -> Ok(None)
      Some(binding) -> persona_in(db, binding.persona_id) |> result.map(Some)
    })
    use chosen <- result.try(default_in(db))
    use owners <- result.try(case persona {
      None -> Ok([])
      Some(persona) ->
        store.rows(
          db,
          "SELECT session FROM personality_session WHERE persona_id=? AND mode='owner' ORDER BY session LIMIT 32",
          [sqlight.text(persona.id)],
          decode.field(0, decode.string, decode.success),
        )
        |> result.map_error(p.Storage)
    })
    use choices <- result.map(
      store.rows(
        db,
        "SELECT id,name FROM personality_persona ORDER BY name,id LIMIT 32",
        [],
        {
          use id <- decode.field(0, decode.string)
          use name <- decode.field(1, decode.string)
          decode.success(#(id, name))
        },
      )
      |> result.map_error(p.Storage),
    )
    p.Inspection(
      binding,
      persona,
      boundary.0,
      boundary.1,
      chosen,
      owners,
      choices,
    )
  })
}

pub fn read_document(
  ledger: store.Store,
  session: String,
  revision: Option(Int),
  offset: Int,
  limit: Int,
) -> Result(p.DocumentPage, p.DomainError) {
  store.query(ledger, fn(db) {
    use captured <- result.try(capture_in(db, session))
    let revision = option.unwrap(revision, captured.persona.identity_revision)
    use document <- result.try(
      store.one(
        db,
        "SELECT document FROM personality_revision WHERE persona_id=? AND revision=?",
        [sqlight.text(captured.persona.id), sqlight.int(revision)],
        decode.field(0, decode.string, decode.success),
        "not_found",
      )
      |> result.map_error(storage),
    )
    domain.page(document, revision, offset, limit)
  })
}

fn receipt_decoder() -> decode.Decoder(p.Receipt) {
  use persona <- decode.field("persona_id", decode.string)
  use revision <- decode.field("identity_revision", decode.int)
  use actor <- decode.field("actor", decode.string)
  use session <- decode.field("origin_session", decode.string)
  use call <- decode.field("call_id", decode.string)
  decode.success(p.Receipt(persona, revision, actor, session, call))
}

fn mutate(
  ledger: store.Store,
  session: String,
  actor: p.Actor,
  payload: String,
  change: fn(p.Persona) -> Result(String, p.DomainError),
) -> Result(p.Receipt, p.DomainError) {
  let call = domain.call_id(actor)
  use _ <- result.try(
    case
      string.trim(call) != ""
      && string.byte_size(call) <= 512
      && call != "human:"
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("trusted call identity missing or too long"))
    },
  )
  let request_hash = domain.hash(payload)
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use captured <- result.try(capture_in(db, session))
      use saved <- result.try(
        store.rows(
          db,
          "SELECT request,result FROM personality_tool_receipt WHERE session=? AND call_id=?",
          [sqlight.text(session), sqlight.text(call)],
          {
            use request <- decode.field(0, decode.string)
            use result <- decode.field(1, decode.string)
            decode.success(#(request, result))
          },
        )
        |> result.map_error(p.Storage),
      )
      case saved {
        [#(request, encoded)] if request == request_hash ->
          json.parse(encoded, receipt_decoder())
          |> result.replace_error(p.Storage("corrupt tool receipt"))
        [_] -> Error(p.CallReused)
        [] -> {
          use _ <- result.try(case actor {
            p.OwnerAgent(_) if !captured.persona.writable ->
              Error(p.Forbidden("identity document is read-only"))
            _ -> Ok(Nil)
          })
          use content <- result.try(change(captured.persona))
          use _ <- result.try(domain.validate_document(content))
          let revision = captured.persona.identity_revision + 1
          let receipt =
            p.Receipt(
              captured.persona.id,
              revision,
              domain.actor_name(actor),
              session,
              call,
            )
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_revision VALUES(?,?,?,?,?,?,?)",
              [
                sqlight.text(receipt.persona_id),
                sqlight.int(revision),
                sqlight.text(content),
                sqlight.text(receipt.actor),
                sqlight.text(session),
                sqlight.text(call),
                sqlight.int(clock.system_ms()),
              ],
            )
            |> result.map_error(p.Storage),
          )
          use _ <- result.try(
            store.run(
              db,
              "UPDATE personality_persona SET identity_revision=? WHERE id=?",
              [sqlight.int(revision), sqlight.text(receipt.persona_id)],
            )
            |> result.map_error(p.Storage),
          )
          use _ <- result.map(
            store.run(
              db,
              "INSERT INTO personality_tool_receipt VALUES(?,?,?,?,?,?)",
              [
                sqlight.text(session),
                sqlight.text(call),
                sqlight.text(receipt.persona_id),
                sqlight.text(domain.hash(payload)),
                sqlight.text(json.to_string(receipt_json(receipt))),
                sqlight.int(clock.system_ms()),
              ],
            )
            |> result.map_error(p.Storage),
          )
          receipt
        }
        _ -> Error(p.Storage("duplicate tool receipt"))
      }
    })
  })
}

pub fn write_document(
  ledger: store.Store,
  session: String,
  actor: p.Actor,
  content: String,
  expected_revision: Option(Int),
) -> Result(p.Receipt, p.DomainError) {
  use _ <- result.try(domain.validate_document(content))
  let payload =
    json.to_string(
      json.object([
        #("kind", json.string("write")),
        #("content", json.string(content)),
        #("expected_revision", json.nullable(expected_revision, json.int)),
        #("actor", json.string(domain.actor_name(actor))),
      ]),
    )
  mutate(ledger, session, actor, payload, fn(persona) {
    use _ <- result.try(case expected_revision {
      Some(revision) if revision != persona.identity_revision ->
        Error(p.RevisionConflict(persona.identity_revision))
      _ -> Ok(Nil)
    })
    Ok(content)
  })
}

pub fn edit_document(
  ledger: store.Store,
  session: String,
  actor: p.Actor,
  old_string: String,
  new_string: String,
  replace_all: Bool,
) -> Result(p.Receipt, p.DomainError) {
  use _ <- result.try(
    case
      string.byte_size(old_string) <= domain.document_limit
      && string.byte_size(new_string) <= domain.document_limit
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("edit strings exceed document write limit"))
    },
  )
  let payload =
    json.to_string(
      json.object([
        #("kind", json.string("edit")),
        #("old_string", json.string(old_string)),
        #("new_string", json.string(new_string)),
        #("replace_all", json.bool(replace_all)),
        #("actor", json.string(domain.actor_name(actor))),
      ]),
    )
  mutate(ledger, session, actor, payload, fn(persona) {
    domain.edit(persona.document, old_string, new_string, replace_all)
  })
}

/// Unknown calls never replay a write. The authenticated origin session and
/// trusted call retain the exact receipt even after a deliberate rebind.
pub fn recover(
  ledger: store.Store,
  session: String,
  call_id: String,
) -> Result(Option(String), p.DomainError) {
  store.query(ledger, fn(db) {
    store.rows(
      db,
      "SELECT result FROM personality_tool_receipt WHERE session=? AND call_id=?",
      [sqlight.text(session), sqlight.text(call_id)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map(fn(rows) { list.first(rows) |> option.from_result })
    |> result.map_error(p.Storage)
  })
}

pub fn persona_json(persona: p.Persona) -> json.Json {
  json.object([
    #("id", json.string(persona.id)),
    #("name", json.string(persona.name)),
    #("identity_revision", json.int(persona.identity_revision)),
    #("writable", json.bool(persona.writable)),
    #("document_bytes", json.int(string.byte_size(persona.document))),
  ])
}

pub fn binding_json(binding: p.Binding) -> json.Json {
  json.object([
    #("session", json.string(binding.session)),
    #("persona_id", json.string(binding.persona_id)),
    #("mode", json.string(binding.mode)),
    #("generation", json.int(binding.generation)),
    #("pre_binding_through", json.int(binding.pre_binding_through)),
  ])
}

pub fn receipt_json(receipt: p.Receipt) -> json.Json {
  json.object([
    #("persona_id", json.string(receipt.persona_id)),
    #("identity_revision", json.int(receipt.identity_revision)),
    #("actor", json.string(receipt.actor)),
    #("origin_session", json.string(receipt.origin_session)),
    #("call_id", json.string(receipt.call_id)),
  ])
}

pub fn page_json(page: p.DocumentPage) -> json.Json {
  json.object([
    #("revision", json.int(page.revision)),
    #("text", json.string(page.text)),
    #("next_offset", json.nullable(page.next_offset, json.int)),
  ])
}

pub fn message(error: p.DomainError) -> String {
  case error {
    p.Conflict("compaction_selection_conflict") ->
      "compaction_selection_conflict: select personality through the native /extensions action before binding; another compaction strategy is explicitly selected"
    p.Invalid(detail)
    | p.Conflict(detail)
    | p.Forbidden(detail)
    | p.Storage(detail) -> detail
    p.RevisionConflict(revision) ->
      "document revision conflict; current revision " <> int.to_string(revision)
    p.CallReused -> "trusted call reused with different content"
    p.NotFound -> "identity or revision not found"
    p.SetupRequired ->
      "personality setup required: create a default or explicitly attach existing history"
  }
}

pub fn error_json(error: p.DomainError) -> json.Json {
  json.object([
    #(
      "error",
      json.string(case error {
        p.Invalid(_) -> "invalid"
        p.Conflict(_) | p.RevisionConflict(_) -> "conflict"
        p.Forbidden(_) -> "forbidden"
        p.CallReused -> "call_reused"
        p.NotFound -> "not_found"
        p.SetupRequired -> "setup_required"
        p.Storage(_) -> "personality_unavailable"
      }),
    ),
    #("detail", json.string(message(error))),
  ])
}

/// Keep typed domain errors while using the native transaction/commit rollback.
pub fn transaction(
  db: sqlight.Connection,
  run: fn() -> Result(a, p.DomainError),
) -> Result(a, p.DomainError) {
  store.transaction(db, fn() {
    run()
    |> result.map_error(fn(error) {
      json.to_string(
        json.object([
          #(
            "kind",
            json.string(case error {
              p.Invalid(_) -> "invalid"
              p.Conflict(_) -> "conflict"
              p.RevisionConflict(_) -> "revision"
              p.Forbidden(_) -> "forbidden"
              p.CallReused -> "call_reused"
              p.NotFound -> "not_found"
              p.SetupRequired -> "setup_required"
              p.Storage(_) -> "storage"
            }),
          ),
          #(
            "detail",
            json.string(case error {
              p.Invalid(detail)
              | p.Conflict(detail)
              | p.Forbidden(detail)
              | p.Storage(detail) -> detail
              _ -> message(error)
            }),
          ),
          #(
            "revision",
            json.int(case error {
              p.RevisionConflict(revision) -> revision
              _ -> 0
            }),
          ),
        ]),
      )
    })
  })
  |> result.map_error(fn(raw) {
    json.parse(raw, {
      use kind <- decode.field("kind", decode.string)
      use detail <- decode.field("detail", decode.string)
      use revision <- decode.field("revision", decode.int)
      decode.success(case kind {
        "invalid" -> p.Invalid(detail)
        "conflict" -> p.Conflict(detail)
        "revision" -> p.RevisionConflict(revision)
        "forbidden" -> p.Forbidden(detail)
        "call_reused" -> p.CallReused
        "not_found" -> p.NotFound
        "setup_required" -> p.SetupRequired
        _ -> p.Storage(detail)
      })
    })
    |> result.unwrap(p.Storage(raw))
  })
}

fn first_persona_in(
  db: sqlight.Connection,
  id: String,
) -> Result(p.Persona, p.DomainError) {
  store.one(
    db,
    "SELECT p.id,p.name,1,r.document,p.writable FROM personality_persona p JOIN personality_revision r ON r.persona_id=p.id AND r.revision=1 WHERE p.id=?",
    [sqlight.text(id)],
    persona_decoder(),
    "not_found",
  )
  |> result.map_error(storage)
}

/// Human transport retries retain exactly one deliberate additional identity.
pub fn create_with_key(
  ledger: store.Store,
  name: String,
  content: String,
  writable: Bool,
  key: String,
) -> Result(p.Persona, p.DomainError) {
  use _ <- result.try(domain.validate_document(content))
  let hash =
    domain.hash(
      json.to_string(
        json.object([
          #("kind", json.string("create")),
          #("name", json.string(name)),
          #("content", json.string(content)),
          #("writable", json.bool(writable)),
        ]),
      ),
    )
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use saved <- result.try(
        store.rows(
          db,
          "SELECT request,result FROM personality_setup_receipt WHERE retry_key=?",
          [sqlight.text(key)],
          {
            use request <- decode.field(0, decode.string)
            use id <- decode.field(1, decode.string)
            decode.success(#(request, id))
          },
        )
        |> result.map_error(p.Storage),
      )
      case saved {
        [#(old, id)] if old == hash -> first_persona_in(db, id)
        [_] -> Error(p.CallReused)
        [] -> {
          use persona <- result.try(create_in(
            db,
            name,
            content,
            writable,
            False,
          ))
          use _ <- result.map(
            store.run(
              db,
              "INSERT INTO personality_setup_receipt VALUES(?,?,?,?)",
              [
                sqlight.text(key),
                sqlight.text(hash),
                sqlight.text(persona.id),
                sqlight.int(clock.system_ms()),
              ],
            )
            |> result.map_error(p.Storage),
          )
          persona
        }
        _ -> Error(p.Storage("duplicate creation receipt"))
      }
    })
  })
}
