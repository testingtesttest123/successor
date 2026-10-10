//// One serialized, transactional owner for explicit human identity setup.

import albedo/clock
import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, schema.apply)
}

pub fn message(error: p.DomainError) -> String {
  case error {
    p.Invalid(detail) | p.Conflict(detail) | p.Storage(detail) -> detail
    p.RevisionConflict(_) -> "identity heads changed; inspect before retrying"
    p.Forbidden(detail) -> detail
    p.OperationIdReused -> "operation_id_reused"
    p.CapacityExceeded ->
      "corrective reserve exhausted; user must raise capacity or export and authorize maintenance"
    p.NotFound -> "persona or session not found"
    p.SetupRequired ->
      "personality setup required: explicitly bind an existing identity"
  }
}

fn domain(error: String) -> p.DomainError {
  case error {
    "not_found" -> p.NotFound
    "setup_required" -> p.SetupRequired
    "operation_conflict"
    | "binding_changed"
    | "history_changed"
    | "persona_changed"
    | "active_bindings" -> p.Conflict(error)
    "archived_persona" | "owner_only" | "default_not_configured" ->
      p.Invalid(error)
    _ -> p.Storage(error)
  }
}

fn valid_operation(id: String) -> Result(Nil, p.DomainError) {
  case string.trim(id) == "" || string.byte_size(id) > 128 {
    True -> Error(p.Invalid("operation_id must contain 1 to 128 UTF-8 bytes"))
    False -> Ok(Nil)
  }
}

fn persona_decoder() -> decode.Decoder(p.Persona) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use state <- decode.field("state", decode.string)
  use revision <- decode.field("revision", decode.int)
  use identity_revision <- decode.field("identity_revision", decode.int)
  use identity <- decode.field("identity", {
    use description <- decode.field("self_description", decode.string)
    use values <- decode.field("values", decode.string)
    use communication <- decode.field("communication", decode.string)
    use instructions <- decode.field("instructions", decode.string)
    decode.success(p.Identity(description, values, communication, instructions))
  })
  use identity_edits <- decode.field("agent_identity_edits", decode.bool)
  use memory_edits <- decode.field("agent_memory_edits", decode.bool)
  decode.success(p.Persona(
    id,
    name,
    state,
    revision,
    identity_revision,
    identity,
    identity_edits,
    memory_edits,
  ))
}

fn binding_decoder() -> decode.Decoder(p.Binding) {
  use session <- decode.field("session", decode.string)
  use persona <- decode.field("persona_id", decode.string)
  use mode <- decode.field("mode", decode.string)
  use revision <- decode.field("revision", decode.int)
  use boundary <- decode.field("pre_binding_through", decode.int)
  decode.success(p.Binding(session, persona, mode, revision, boundary))
}

pub fn persona_json(persona: p.Persona) -> json.Json {
  json.object([
    #("id", json.string(persona.id)),
    #("name", json.string(persona.name)),
    #("state", json.string(persona.state)),
    #("revision", json.int(persona.revision)),
    #("identity_revision", json.int(persona.identity_revision)),
    #(
      "identity",
      json.object([
        #("self_description", json.string(persona.identity.self_description)),
        #("values", json.string(persona.identity.values)),
        #("communication", json.string(persona.identity.communication)),
        #("instructions", json.string(persona.identity.instructions)),
      ]),
    ),
    #("agent_identity_edits", json.bool(persona.agent_identity_edits)),
    #("agent_memory_edits", json.bool(persona.agent_memory_edits)),
  ])
}

pub fn binding_json(binding: p.Binding) -> json.Json {
  json.object([
    #("session", json.string(binding.session)),
    #("persona_id", json.string(binding.persona_id)),
    #("mode", json.string(binding.mode)),
    #("revision", json.int(binding.revision)),
    #("pre_binding_through", json.int(binding.pre_binding_through)),
    #("authority", json.string("user")),
  ])
}

fn operation_in(
  db: sqlight.Connection,
  id: String,
  request: json.Json,
  decoder: decode.Decoder(a),
  encode: fn(a) -> json.Json,
  run: fn() -> Result(a, String),
) -> Result(a, String) {
  let content = json.to_string(request)
  use rows <- result.try(
    store.rows(
      db,
      "SELECT request,result FROM personality_operation WHERE operation_id=?",
      [sqlight.text(id)],
      {
        use request <- decode.field(0, decode.string)
        use value <- decode.field(1, decode.string)
        decode.success(#(request, value))
      },
    ),
  )
  case rows {
    [saved] if saved.0 != content -> Error("operation_conflict")
    [saved] ->
      json.parse(saved.1, decoder)
      |> result.replace_error("operation receipt unreadable")
    [] -> {
      use value <- result.try(run())
      use _ <- result.try(
        store.run(
          db,
          "INSERT INTO personality_operation(operation_id,request,result,created_at) VALUES(?,?,?,?)",
          [
            sqlight.text(id),
            sqlight.text(content),
            sqlight.text(json.to_string(encode(value))),
            sqlight.int(clock.system_ms()),
          ],
        ),
      )
      use _ <- result.try(refresh_ordinary_in(db, id))
      Ok(value)
    }
    _ -> Error("operation receipt is not unique")
  }
}

fn event_in(
  db: sqlight.Connection,
  persona: p.Persona,
  operation: String,
  session: String,
  kind: String,
  reason: String,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO personality_event(persona_id,operation_id,actor,origin_session,event_type,base_revision,head_revision,reason,created_at) VALUES(?,?,'user',?,?,?,?,?,?)",
    [
      sqlight.text(persona.id),
      sqlight.text(operation),
      sqlight.nullable(sqlight.text, case session {
        "" -> None
        _ -> Some(session)
      }),
      sqlight.text(kind),
      sqlight.int(persona.revision),
      sqlight.int(persona.revision + 1),
      sqlight.text(reason),
      sqlight.int(clock.system_ms()),
    ],
  )
}

fn find_in(db: sqlight.Connection, id: String) -> Result(p.Persona, String) {
  use persona <- result.try(store.one(
    db,
    "SELECT p.id,p.name,p.state,p.revision,p.identity_revision,r.self_description,r.values_text,r.communication,r.instructions,p.agent_identity_edits,p.agent_memory_edits FROM personality_persona p JOIN personality_revision r ON r.persona_id=p.id AND r.revision=p.identity_revision WHERE p.id=?",
    [sqlight.text(id)],
    {
      use id <- decode.field(0, decode.string)
      use name <- decode.field(1, decode.string)
      use state <- decode.field(2, decode.string)
      use revision <- decode.field(3, decode.int)
      use identity_revision <- decode.field(4, decode.int)
      use description <- decode.field(5, decode.string)
      use values <- decode.field(6, decode.string)
      use communication <- decode.field(7, decode.string)
      use instructions <- decode.field(8, decode.string)
      use identity_edits <- decode.field(9, sqlight.decode_bool())
      use memory_edits <- decode.field(10, sqlight.decode_bool())
      decode.success(p.Persona(
        id,
        name,
        state,
        revision,
        identity_revision,
        p.Identity(description, values, communication, instructions),
        identity_edits,
        memory_edits,
      ))
    },
    "not_found",
  ))
  let fields = [
    persona.identity.self_description,
    persona.identity.values,
    persona.identity.communication,
    persona.identity.instructions,
  ]
  case
    list.any(fields, fn(field) { string.byte_size(field) > 4096 })
    || list.fold(fields, 0, fn(total, field) { total + string.byte_size(field) })
    > 12_288
  {
    True -> Error("stored identity exceeds its UTF-8 limits")
    False -> Ok(persona)
  }
}

pub fn create(
  ledger: store.Store,
  config: p.Creation,
) -> Result(p.Persona, p.DomainError) {
  use _ <- result.try(valid_operation(config.operation_id))
  use _ <- result.try(
    case string.trim(config.name) == "" || string.byte_size(config.name) > 256 {
      True -> Error(p.Invalid("name must contain 1 to 256 UTF-8 bytes"))
      False -> Ok(Nil)
    },
  )
  let request =
    json.object([
      #("kind", json.string("persona_create")),
      #("name", json.string(config.name)),
      #("make_default", json.bool(config.make_default)),
      #("agent_identity_edits", json.bool(config.agent_identity_edits)),
      #("agent_memory_edits", json.bool(config.agent_memory_edits)),
    ])
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      operation_in(
        db,
        config.operation_id,
        request,
        persona_decoder(),
        persona_json,
        fn() {
          let id = new_id()
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_persona(id,name,state,revision,identity_revision,creation_operation,agent_identity_edits,agent_memory_edits) VALUES(?,?,'active',1,1,?,?,?)",
              [
                sqlight.text(id),
                sqlight.text(config.name),
                sqlight.text(config.operation_id),
                sqlight.bool(config.agent_identity_edits),
                sqlight.bool(config.agent_memory_edits),
              ],
            ),
          )
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_revision(persona_id,revision,self_description,values_text,communication,instructions,author,reason,created_at) VALUES(?,1,'','','','','user','explicit empty identity creation',?)",
              [sqlight.text(id), sqlight.int(clock.system_ms())],
            ),
          )
          use _ <- result.try(case config.make_default {
            False -> Ok(Nil)
            True ->
              store.run(
                db,
                "INSERT INTO personality_default(singleton,persona_id) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET persona_id=excluded.persona_id",
                [sqlight.text(id)],
              )
          })
          use _ <- result.try(schema.capacity(db, id))
          use persona <- result.try(find_in(db, id))
          use _ <- result.try(event_in(
            db,
            p.Persona(..persona, revision: 0),
            config.operation_id,
            "",
            "created",
            "explicit human creation; no copied state",
          ))
          Ok(persona)
        },
      )
    })
  })
  |> result.map_error(domain)
}

fn inspect_in(
  db: sqlight.Connection,
  session: String,
) -> Result(p.Inspection, String) {
  use boundary <- result.try(store.one(
    db,
    "SELECT COALESCE((SELECT MAX(seq) FROM transcript WHERE session=s.id),0),(SELECT COUNT(*) FROM transcript WHERE session=s.id) FROM sessions s WHERE id=?",
    [sqlight.text(session)],
    {
      use through <- decode.field(0, decode.int)
      use count <- decode.field(1, decode.int)
      decode.success(#(through, count))
    },
    "not_found",
  ))
  use bindings <- result.try(
    store.rows(
      db,
      "SELECT persona_id,mode,binding_revision,pre_binding_through,authority FROM personality_session WHERE session=?",
      [sqlight.text(session)],
      {
        use persona <- decode.field(0, decode.optional(decode.string))
        use mode <- decode.field(1, decode.string)
        use revision <- decode.field(2, decode.int)
        use through <- decode.field(3, decode.int)
        use authority <- decode.field(4, decode.string)
        decode.success(#(persona, mode, revision, through, authority))
      },
    ),
  )
  use #(binding, revision) <- result.try(case bindings {
    [] -> Ok(#(None, 0))
    [row] if row.4 != "user" -> Error("binding authority unreadable")
    [#(Some(persona), "owner", revision, through, _)] ->
      Ok(#(
        Some(p.Binding(session, persona, "owner", revision, through)),
        revision,
      ))
    [#(None, "owner", revision, _, _)] -> Ok(#(None, revision))
    _ -> Error("binding mode unavailable")
  })
  use persona <- result.try(case binding {
    None -> Ok(None)
    Some(binding) -> find_in(db, binding.persona_id) |> result.map(Some)
  })
  use defaults <- result.try(store.rows(
    db,
    "SELECT persona_id FROM personality_default WHERE singleton=1",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  Ok(p.Inspection(
    binding,
    persona,
    revision,
    boundary.0,
    boundary.1,
    list.first(defaults) |> option.from_result,
  ))
}

/// The human page captures history, binding, identity, controls and usage on
/// one store turn, including the unbound setup state. No independent reread.
pub fn inspect(
  ledger: store.Store,
  session: String,
) -> Result(#(p.Inspection, option.Option(p.Editing)), p.DomainError) {
  store.query(ledger, fn(db) {
    use inspection <- result.try(
      inspect_in(db, session) |> result.map_error(domain),
    )
    use editing <- result.try(case inspection.binding {
      None -> Ok(None)
      Some(_) -> {
        use snapshot <- result.try(bound_snapshot_in(db, session, inspection))
        editing_in(db, snapshot.persona) |> result.map(Some)
      }
    })
    Ok(#(inspection, editing))
  })
}

pub fn capture(
  ledger: store.Store,
  session: String,
  query: String,
) -> Result(p.Snapshot, p.DomainError) {
  case string.byte_size(query) > 4096 {
    True -> Error(p.Invalid("request query exceeds 4 KiB"))
    False ->
      store.query(ledger, fn(db) {
        use inspection <- result.try(inspect_in(db, session))
        case inspection.binding, inspection.persona {
          Some(binding), Some(persona) if persona.state == "active" ->
            Ok(p.Snapshot(persona, binding))
          None, _ -> Error("setup_required")
          _, _ -> Error("archived_persona")
        }
      })
      |> result.map_error(domain)
  }
}

/// Called exclusively from the actor's ApplyIdle bridge, never model tools.
pub fn bind(
  ledger: store.Store,
  session: String,
  change: p.Bind,
) -> Result(p.Binding, p.DomainError) {
  use _ <- result.try(valid_operation(change.operation_id))
  let request =
    json.object([
      #("kind", json.string("bind")),
      #("session", json.string(session)),
      #("persona_id", json.string(change.persona_id)),
      #("expected_revision", json.int(change.expected_revision)),
      #("history_through", json.int(change.acknowledge_history_through)),
    ])
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      operation_in(
        db,
        change.operation_id,
        request,
        binding_decoder(),
        binding_json,
        fn() {
          use inspection <- result.try(inspect_in(db, session))
          use _ <- result.try(
            case inspection.binding_revision == change.expected_revision {
              True -> Ok(Nil)
              False -> Error("binding_changed")
            },
          )
          use _ <- result.try(
            case
              inspection.history_through == change.acknowledge_history_through
            {
              True -> Ok(Nil)
              False -> Error("history_changed")
            },
          )
          use children <- result.try(store.rows(
            db,
            "SELECT session FROM session_family WHERE session=?",
            [sqlight.text(session)],
            decode.field(0, decode.string, decode.success),
          ))
          use _ <- result.try(case children {
            [] -> Ok(Nil)
            _ -> Error("owner_only")
          })
          use id <- result.try(case change.persona_id {
            "" ->
              inspection.default_persona
              |> option.to_result("default_not_configured")
            id -> Ok(id)
          })
          use persona <- result.try(find_in(db, id))
          use _ <- result.try(case persona.state {
            "active" -> Ok(Nil)
            _ -> Error("archived_persona")
          })
          let bound =
            p.Binding(
              session,
              id,
              "owner",
              inspection.binding_revision + 1,
              inspection.history_through,
            )
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_session(session,persona_id,mode,binding_revision,pre_binding_through,authority) VALUES(?,?,'owner',?,?,'user') ON CONFLICT(session) DO UPDATE SET persona_id=excluded.persona_id,mode='owner',binding_revision=excluded.binding_revision,pre_binding_through=excluded.pre_binding_through,authority='user'",
              [
                sqlight.text(session),
                sqlight.text(id),
                sqlight.int(bound.revision),
                sqlight.int(bound.pre_binding_through),
              ],
            ),
          )
          use _ <- result.try(session_requirements.set_in(
            db,
            session,
            "personality",
            True,
          ))
          // A cross-persona rebind removes the old association as well as
          // adding the new one. Both heads and events share this receipt's
          // transaction; a same-persona rebind is one aggregate mutation.
          use _ <- result.try(case inspection.persona {
            Some(previous) if previous.id != id -> {
              use _ <- result.try(event_in(
                db,
                previous,
                change.operation_id,
                session,
                "unbound",
                "explicit human rebind to another persona",
              ))
              store.run(
                db,
                "UPDATE personality_persona SET revision=revision+1 WHERE id=?",
                [sqlight.text(previous.id)],
              )
            }
            _ -> Ok(Nil)
          })
          use _ <- result.try(event_in(
            db,
            persona,
            change.operation_id,
            session,
            "bound",
            "existing history is pre-binding evidence",
          ))
          use _ <- result.try(
            store.run(
              db,
              "UPDATE personality_persona SET revision=revision+1 WHERE id=?",
              [sqlight.text(id)],
            ),
          )
          Ok(bound)
        },
      )
    })
  })
  |> result.map_error(domain)
}

pub fn unbind(
  ledger: store.Store,
  session: String,
  operation: String,
  expected: Int,
) -> Result(Int, p.DomainError) {
  use _ <- result.try(valid_operation(operation))
  let request =
    json.object([
      #("kind", json.string("unbind")),
      #("session", json.string(session)),
      #("expected_revision", json.int(expected)),
    ])
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      operation_in(db, operation, request, decode.int, json.int, fn() {
        use inspection <- result.try(inspect_in(db, session))
        use _ <- result.try(case inspection.binding_revision == expected {
          True -> Ok(Nil)
          False -> Error("binding_changed")
        })
        use persona <- result.try(
          inspection.persona |> option.to_result("setup_required"),
        )
        use _ <- result.try(
          store.run(
            db,
            "UPDATE personality_session SET persona_id=NULL,binding_revision=binding_revision+1 WHERE session=?",
            [sqlight.text(session)],
          ),
        )
        use _ <- result.try(session_requirements.set_in(
          db,
          session,
          "personality",
          False,
        ))
        use _ <- result.try(event_in(
          db,
          persona,
          operation,
          session,
          "unbound",
          "explicit human unbinding",
        ))
        use _ <- result.try(
          store.run(
            db,
            "UPDATE personality_persona SET revision=revision+1 WHERE id=?",
            [sqlight.text(persona.id)],
          ),
        )
        Ok(expected + 1)
      })
    })
  })
  |> result.map_error(domain)
}

pub fn archive(
  ledger: store.Store,
  id: String,
  operation: String,
  expected: Int,
) -> Result(p.Persona, p.DomainError) {
  use _ <- result.try(valid_operation(operation))
  let request =
    json.object([
      #("kind", json.string("archive")),
      #("id", json.string(id)),
      #("expected_revision", json.int(expected)),
    ])
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      operation_in(
        db,
        operation,
        request,
        persona_decoder(),
        persona_json,
        fn() {
          use persona <- result.try(find_in(db, id))
          use _ <- result.try(case persona.revision == expected {
            True -> Ok(Nil)
            False -> Error("persona_changed")
          })
          use active <- result.try(store.one(
            db,
            "SELECT COUNT(*) FROM personality_session WHERE persona_id=?",
            [sqlight.text(id)],
            decode.field(0, decode.int, decode.success),
            "binding count unavailable",
          ))
          use _ <- result.try(case active {
            0 -> Ok(Nil)
            _ -> Error("active_bindings")
          })
          use _ <- result.try(event_in(
            db,
            persona,
            operation,
            "",
            "archived",
            "explicit human archival",
          ))
          use _ <- result.try(
            store.run(
              db,
              "UPDATE personality_persona SET state='archived',revision=revision+1 WHERE id=?",
              [sqlight.text(id)],
            ),
          )
          use _ <- result.try(
            store.run(db, "DELETE FROM personality_default WHERE persona_id=?", [
              sqlight.text(id),
            ]),
          )
          find_in(db, id)
        },
      )
    })
  })
  |> result.map_error(domain)
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

/// Human configuration only: selecting a default never creates or clones it.
pub fn select_default(
  ledger: store.Store,
  id: String,
  operation: String,
  expected: Int,
) -> Result(p.Persona, p.DomainError) {
  use _ <- result.try(valid_operation(operation))
  let request =
    json.object([
      #("kind", json.string("select_default")),
      #("id", json.string(id)),
      #("expected_revision", json.int(expected)),
    ])
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      operation_in(
        db,
        operation,
        request,
        persona_decoder(),
        persona_json,
        fn() {
          use persona <- result.try(find_in(db, id))
          use _ <- result.try(case persona.revision == expected {
            True -> Ok(Nil)
            False -> Error("persona_changed")
          })
          use _ <- result.try(case persona.state {
            "active" -> Ok(Nil)
            _ -> Error("archived_persona")
          })
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_default(singleton,persona_id) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET persona_id=excluded.persona_id",
              [sqlight.text(id)],
            ),
          )
          use _ <- result.try(event_in(
            db,
            persona,
            operation,
            "",
            "default_selected",
            "explicit human default selection",
          ))
          use _ <- result.try(
            store.run(
              db,
              "UPDATE personality_persona SET revision=revision+1 WHERE id=?",
              [sqlight.text(id)],
            ),
          )
          find_in(db, id)
        },
      )
    })
  })
  |> result.map_error(domain)
}

/// Stable structured domain failures, used by both human and native adapters.
pub fn error_json(error: p.DomainError) -> json.Json {
  let code = case error {
    p.Invalid(_) -> "invalid_request"
    p.Conflict(_) | p.RevisionConflict(_) -> "conflict"
    p.Forbidden(_) -> "forbidden"
    p.OperationIdReused -> "operation_id_reused"
    p.CapacityExceeded -> "capacity_exceeded"
    p.NotFound -> "not_found"
    p.SetupRequired -> "setup_required"
    p.Storage(_) -> "personality_unavailable"
  }
  json.object([
    #("code", json.string(code)),
    #("detail", json.string(message(error))),
    ..case error {
      p.RevisionConflict(heads) -> [
        #(
          "current_heads",
          json.object([
            #("revision", json.int(heads.revision)),
            #("identity_revision", json.int(heads.identity_revision)),
          ]),
        ),
      ]
      _ -> []
    }
  ])
}

fn read_error(encoded: String) -> p.DomainError {
  let parsed =
    json.parse(encoded, {
      use code <- decode.field("code", decode.string)
      use detail <- decode.field("detail", decode.string)
      case code {
        "conflict" -> {
          use heads <- decode.field("current_heads", {
            use revision <- decode.field("revision", decode.int)
            use identity <- decode.field("identity_revision", decode.int)
            decode.success(p.Heads(revision, identity))
          })
          decode.success(p.RevisionConflict(heads))
        }
        "invalid_request" -> decode.success(p.Invalid(detail))
        "forbidden" -> decode.success(p.Forbidden(detail))
        "operation_id_reused" -> decode.success(p.OperationIdReused)
        "capacity_exceeded" -> decode.success(p.CapacityExceeded)
        "not_found" -> decode.success(p.NotFound)
        "setup_required" -> decode.success(p.SetupRequired)
        _ -> decode.success(p.Storage(detail))
      }
    })
  result.unwrap(parsed, p.Storage(encoded))
}

fn transaction(
  db: sqlight.Connection,
  run: fn() -> Result(a, p.DomainError),
) -> Result(a, p.DomainError) {
  store.transaction(db, fn() {
    run() |> result.map_error(fn(error) { json.to_string(error_json(error)) })
  })
  |> result.map_error(read_error)
}

pub fn receipt_json(receipt: p.Receipt) -> json.Json {
  json.object([
    #("operation_id", json.string(receipt.operation_id)),
    #("persona_id", json.string(receipt.persona_id)),
    #("actor", json.string(receipt.actor)),
    #("origin_session", json.string(receipt.origin_session)),
    #("origin_call_id", json.nullable(receipt.origin_call_id, json.string)),
    #("event_id", json.int(receipt.event_id)),
    #("revision", json.int(receipt.revision)),
    #("identity_revision", json.int(receipt.identity_revision)),
    #("payload_hash", json.string(receipt.payload_hash)),
  ])
}

fn receipt_decoder() -> decode.Decoder(p.Receipt) {
  use operation <- decode.field("operation_id", decode.string)
  use persona <- decode.field("persona_id", decode.string)
  use actor <- decode.field("actor", decode.string)
  use session <- decode.field("origin_session", decode.string)
  use call <- decode.field("origin_call_id", decode.optional(decode.string))
  use event <- decode.field("event_id", decode.int)
  use revision <- decode.field("revision", decode.int)
  use identity <- decode.field("identity_revision", decode.int)
  use hash <- decode.field("payload_hash", decode.string)
  decode.success(p.Receipt(
    operation,
    persona,
    actor,
    session,
    call,
    event,
    revision,
    identity,
    hash,
  ))
}

fn receipt_key(persona: String, session: String, operation: String) -> String {
  // JSON tuple encoding is injective even when user IDs contain separators.
  "identity:"
  <> json.to_string(json.array([persona, session, operation], json.string))
}

fn bound_in(
  db: sqlight.Connection,
  session: String,
) -> Result(p.Snapshot, p.DomainError) {
  use inspection <- result.try(
    inspect_in(db, session) |> result.map_error(domain),
  )
  bound_snapshot_in(db, session, inspection)
}

fn bound_snapshot_in(
  db: sqlight.Connection,
  session: String,
  inspection: p.Inspection,
) -> Result(p.Snapshot, p.DomainError) {
  use snapshot <- result.try(case inspection.binding, inspection.persona {
    Some(binding), Some(persona)
      if persona.state == "active" && binding.mode == "owner"
    -> Ok(p.Snapshot(persona, binding))
    None, _ -> Error(p.SetupRequired)
    _, _ -> Error(p.Forbidden("active owner binding required"))
  })
  use children <- result.try(
    store.rows(
      db,
      "SELECT session FROM session_family WHERE session=?",
      [sqlight.text(session)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map_error(p.Storage),
  )
  case children {
    [] -> Ok(snapshot)
    _ -> Error(p.Forbidden("temporary child cannot edit an owner identity"))
  }
}

fn editing_in(
  db: sqlight.Connection,
  persona: p.Persona,
) -> Result(p.Editing, p.DomainError) {
  use locks <- result.try(
    store.rows(
      db,
      "SELECT field_locks FROM personality_controls WHERE persona_id=?",
      [sqlight.text(persona.id)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map_error(p.Storage),
  )
  use locks <- result.try(case locks {
    [] -> Ok([])
    [text] ->
      json.parse(text, decode.list(decode.string))
      |> result.replace_error(p.Storage("field locks unreadable"))
    _ -> Error(p.Storage("field locks not unique"))
  })
  use _ <- result.try(
    case
      list.all(locks, fn(lock) {
        list.contains(
          ["self_description", "values", "communication", "instructions"],
          lock,
        )
      })
      && list.length(list.unique(locks)) == list.length(locks)
    {
      True -> Ok(Nil)
      False -> Error(p.Storage("invalid stored field locks"))
    },
  )
  use bytes <- result.try(
    store.one(
      db,
      "SELECT ordinary_bytes,corrective_bytes,ordinary_limit,corrective_limit FROM personality_capacity WHERE persona_id=?",
      [sqlight.text(persona.id)],
      {
        use ordinary <- decode.field(0, decode.int)
        use corrective <- decode.field(1, decode.int)
        use ordinary_limit <- decode.field(2, decode.int)
        use corrective_limit <- decode.field(3, decode.int)
        decode.success(#(ordinary, corrective, ordinary_limit, corrective_limit))
      },
      "capacity unavailable",
    )
    |> result.map_error(p.Storage),
  )
  Ok(p.Editing(
    p.Controls(locks, persona.agent_identity_edits, persona.agent_memory_edits),
    bytes.0,
    bytes.1,
    bytes.2,
    bytes.3,
  ))
}

pub fn editing(
  db: store.Store,
  session: String,
) -> Result(p.Editing, p.DomainError) {
  store.query(db, fn(connection) {
    use snapshot <- result.try(bound_in(connection, session))
    editing_in(connection, snapshot.persona)
  })
}

pub fn editing_json(editing: p.Editing) -> json.Json {
  json.object([
    #("field_locks", json.array(editing.controls.field_locks, json.string)),
    #("ordinary_bytes", json.int(editing.ordinary_bytes)),
    #("corrective_bytes", json.int(editing.corrective_bytes)),
    #("ordinary_limit", json.int(editing.ordinary_limit)),
    #("corrective_limit", json.int(editing.corrective_limit)),
    #(
      "corrective_headroom",
      json.int(editing.corrective_limit - editing.corrective_bytes),
    ),
  ])
}

pub fn receipt(
  db: store.Store,
  session: String,
  operation_id: String,
) -> Result(option.Option(p.Receipt), p.DomainError) {
  store.query(db, fn(connection) {
    use snapshot <- result.try(bound_in(connection, session))
    saved_in(
      connection,
      receipt_key(snapshot.persona.id, session, operation_id),
    )
    |> result.map(fn(saved) { option.map(saved, fn(value) { value.1 }) })
  })
}

fn saved_in(
  db: sqlight.Connection,
  key: String,
) -> Result(option.Option(#(String, p.Receipt)), p.DomainError) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT request,result FROM personality_operation WHERE operation_id=?",
      [sqlight.text(key)],
      {
        use request <- decode.field(0, decode.string)
        use result <- decode.field(1, decode.string)
        decode.success(#(request, result))
      },
    )
    |> result.map_error(p.Storage),
  )
  case rows {
    [] -> Ok(None)
    [row] ->
      json.parse(row.1, receipt_decoder())
      |> result.map(fn(receipt) { Some(#(row.0, receipt)) })
      |> result.replace_error(p.Storage("identity operation receipt unreadable"))
    _ -> Error(p.Storage("identity operation receipt not unique"))
  }
}

/// Recovery only reads a committed trusted call mapping. It never invokes a write.
pub fn recover(
  db: store.Store,
  session: String,
  call: String,
) -> Result(option.Option(String), p.DomainError) {
  store.query(db, fn(connection) {
    use snapshot <- result.try(bound_in(connection, session))
    use rows <- result.try(
      store.rows(
        connection,
        "SELECT result FROM personality_tool_receipt WHERE persona_id=? AND session=? AND call_id=?",
        [
          sqlight.text(snapshot.persona.id),
          sqlight.text(session),
          sqlight.text(call),
        ],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map_error(p.Storage),
    )
    Ok(list.first(rows) |> option.from_result)
  })
}

pub fn edit(
  ledger: store.Store,
  session: String,
  actor: p.Actor,
  mutation: p.Mutation,
  request: String,
  payload_hash: String,
  prepare: fn(p.Persona, p.Controls) -> Result(p.Edit, p.DomainError),
) -> Result(p.Receipt, p.DomainError) {
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use snapshot <- result.try(bound_in(db, session))
      let persona = snapshot.persona
      let key = receipt_key(persona.id, session, mutation.operation_id)
      use saved <- result.try(saved_in(db, key))
      case saved {
        Some(#(previous, _)) if previous != request -> Error(p.OperationIdReused)
        Some(#(_, receipt)) -> {
          // A replay is already known committed. Reserve exhaustion may prevent
          // a new call alias, but must never turn a receipt read into a failure.
          case map_call_in(db, actor, key, receipt) {
            Ok(_) | Error(p.CapacityExceeded) -> Ok(receipt)
            Error(error) -> Error(error)
          }
        }
        None -> {
          use _ <- result.try(
            case
              persona.revision == mutation.expected_revision
              && persona.identity_revision
              == mutation.expected_identity_revision
            {
              True -> Ok(Nil)
              False ->
                Error(
                  p.RevisionConflict(p.Heads(
                    persona.revision,
                    persona.identity_revision,
                  )),
                )
            },
          )
          use editing <- result.try(editing_in(db, persona))
          use edit <- result.try(prepare(persona, editing.controls))
          use receipt <- result.try(commit_in(
            db,
            persona,
            session,
            actor,
            mutation,
            edit,
            payload_hash,
          ))
          let encoded = json.to_string(receipt_json(receipt))
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO personality_operation(operation_id,request,result,created_at) VALUES(?,?,?,?)",
              [
                sqlight.text(key),
                sqlight.text(request),
                sqlight.text(encoded),
                sqlight.int(clock.system_ms()),
              ],
            )
            |> result.map_error(p.Storage),
          )
          // Canonical persisted payloads include revision/control metadata and
          // the complete audit/receipt, not just the edited field's bytes.
          let payload =
            json.to_string(
              json.object([
                #(
                  "persona",
                  persona_json(
                    p.Persona(
                      ..persona,
                      identity: edit.identity,
                      revision: receipt.revision,
                      identity_revision: receipt.identity_revision,
                    ),
                  ),
                ),
                #("locks", json.array(edit.controls.field_locks, json.string)),
                #("reason", json.string(mutation.reason)),
                #("receipt", receipt_json(receipt)),
              ]),
            )
          use _ <- result.try(charge_in(
            db,
            persona.id,
            string.byte_size(request)
              + string.byte_size(encoded)
              + string.byte_size(payload),
          ))
          use _ <- result.try(map_call_in(db, actor, key, receipt))
          Ok(receipt)
        }
      }
    })
  })
}

fn charge_in(
  db: sqlight.Connection,
  persona: String,
  bytes: Int,
) -> Result(Nil, p.DomainError) {
  use changed <- result.try(
    store.rows(
      db,
      "UPDATE personality_capacity SET corrective_bytes=corrective_bytes+? WHERE persona_id=? AND corrective_bytes+?<=corrective_limit RETURNING persona_id",
      [sqlight.int(bytes), sqlight.text(persona), sqlight.int(bytes)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map_error(p.Storage),
  )
  case changed {
    [_] -> Ok(Nil)
    [] -> Error(p.CapacityExceeded)
    _ -> Error(p.Storage("capacity row not unique"))
  }
}

fn map_call_in(
  db: sqlight.Connection,
  actor: p.Actor,
  key: String,
  receipt: p.Receipt,
) -> Result(Nil, p.DomainError) {
  case actor {
    p.User -> Ok(Nil)
    p.OwnerAgent(call) -> {
      use rows <- result.try(
        store.rows(
          db,
          "SELECT operation_key FROM personality_tool_receipt WHERE persona_id=? AND session=? AND call_id=?",
          [
            sqlight.text(receipt.persona_id),
            sqlight.text(receipt.origin_session),
            sqlight.text(call),
          ],
          decode.field(0, decode.string, decode.success),
        )
        |> result.map_error(p.Storage),
      )
      case rows {
        [saved] if saved == key -> Ok(Nil)
        [_] -> Error(p.OperationIdReused)
        [] -> {
          let encoded = json.to_string(receipt_json(receipt))
          let mapping =
            json.to_string(json.array(
              [receipt.persona_id, receipt.origin_session, call, key, encoded],
              json.string,
            ))
          use _ <- result.try(charge_in(
            db,
            receipt.persona_id,
            string.byte_size(mapping),
          ))
          store.run(
            db,
            "INSERT INTO personality_tool_receipt(persona_id,session,call_id,operation_key,result) VALUES(?,?,?,?,?)",
            [
              sqlight.text(receipt.persona_id),
              sqlight.text(receipt.origin_session),
              sqlight.text(call),
              sqlight.text(key),
              sqlight.text(encoded),
            ],
          )
          |> result.map_error(p.Storage)
        }
        _ -> Error(p.Storage("tool receipt not unique"))
      }
    }
  }
}

fn commit_in(
  db: sqlight.Connection,
  persona: p.Persona,
  session: String,
  actor: p.Actor,
  mutation: p.Mutation,
  edit: p.Edit,
  payload_hash: String,
) -> Result(p.Receipt, p.DomainError) {
  let author = case actor {
    p.User -> "user"
    p.OwnerAgent(_) -> "owner_agent"
  }
  let identity_revision =
    persona.identity_revision
    + case edit.identity_changed {
      True -> 1
      False -> 0
    }
  use _ <- result.try(case edit.identity_changed {
    False -> Ok(Nil)
    True ->
      store.run(
        db,
        "INSERT INTO personality_revision(persona_id,revision,self_description,values_text,communication,instructions,author,origin_session,reason,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        [
          sqlight.text(persona.id),
          sqlight.int(identity_revision),
          sqlight.text(edit.identity.self_description),
          sqlight.text(edit.identity.values),
          sqlight.text(edit.identity.communication),
          sqlight.text(edit.identity.instructions),
          sqlight.text(author),
          sqlight.text(session),
          sqlight.text(mutation.reason),
          sqlight.int(clock.system_ms()),
        ],
      )
      |> result.map_error(p.Storage)
  })
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_controls(persona_id,field_locks) VALUES(?,?) ON CONFLICT(persona_id) DO UPDATE SET field_locks=excluded.field_locks",
      [
        sqlight.text(persona.id),
        sqlight.text(
          json.to_string(json.array(edit.controls.field_locks, json.string)),
        ),
      ],
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(
    store.run(
      db,
      "UPDATE personality_persona SET revision=revision+1,identity_revision=?,agent_identity_edits=?,agent_memory_edits=? WHERE id=?",
      [
        sqlight.int(identity_revision),
        sqlight.bool(edit.controls.agent_identity_edits),
        sqlight.bool(edit.controls.agent_memory_edits),
        sqlight.text(persona.id),
      ],
    )
    |> result.map_error(p.Storage),
  )
  use event <- result.try(
    store.one(
      db,
      "INSERT INTO personality_event(persona_id,operation_id,actor,origin_session,event_type,base_revision,head_revision,reason,created_at) VALUES(?,?,?,?,?,?,?,?,?) RETURNING id",
      [
        sqlight.text(persona.id),
        sqlight.text(mutation.operation_id),
        sqlight.text(author),
        sqlight.text(session),
        sqlight.text(case edit.identity_changed {
          True -> "identity_edited"
          False -> "controls_edited"
        }),
        sqlight.int(persona.revision),
        sqlight.int(persona.revision + 1),
        sqlight.text(mutation.reason),
        sqlight.int(clock.system_ms()),
      ],
      decode.field(0, decode.int, decode.success),
      "identity event missing",
    )
    |> result.map_error(p.Storage),
  )
  Ok(p.Receipt(
    mutation.operation_id,
    persona.id,
    author,
    session,
    case actor {
      p.User -> None
      p.OwnerAgent(call) -> Some(call)
    },
    event,
    persona.revision + 1,
    identity_revision,
    payload_hash,
  ))
}

fn refresh_ordinary_in(
  db: sqlight.Connection,
  operation: String,
) -> Result(Nil, String) {
  use personas <- result.try(store.rows(
    db,
    "SELECT DISTINCT persona_id FROM personality_event WHERE operation_id=?",
    [sqlight.text(operation)],
    decode.field(0, decode.string, decode.success),
  ))
  list.try_each(personas, fn(persona) {
    use _ <- result.try(schema.capacity(db, persona))
    store.run(
      db,
      "UPDATE personality_capacity SET ordinary_bytes=COALESCE((SELECT SUM(length(CAST(self_description||values_text||communication||instructions||author||reason AS BLOB))) FROM personality_revision WHERE persona_id=? AND revision=1),0)+COALESCE((SELECT SUM(length(CAST(persona_id||operation_id||actor||COALESCE(origin_session,'')||event_type||base_revision||head_revision||reason||created_at AS BLOB))) FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited')),0)+COALESCE((SELECT SUM(length(CAST(request||result AS BLOB))) FROM personality_operation WHERE operation_id IN (SELECT operation_id FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited'))),0) WHERE persona_id=?",
      [
        sqlight.text(persona),
        sqlight.text(persona),
        sqlight.text(persona),
        sqlight.text(persona),
      ],
    )
  })
}

/// One store turn captures the identity, controls and usage for inspection.
pub fn identity(
  db: store.Store,
  session: String,
) -> Result(#(p.Snapshot, p.Editing), p.DomainError) {
  store.query(db, fn(connection) {
    use snapshot <- result.try(bound_in(connection, session))
    use editing <- result.try(editing_in(connection, snapshot.persona))
    Ok(#(snapshot, editing))
  })
}
