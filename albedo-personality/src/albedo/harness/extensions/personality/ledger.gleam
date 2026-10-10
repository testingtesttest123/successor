//// One serialized, transactional owner for explicit human identity setup.

import albedo/clock
import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/sources
import albedo/harness/extensions/personality/types as p
import albedo/text_scalars
import gleam/dynamic/decode
import gleam/int
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
    p.RevisionConflict(_) -> "persona heads changed; inspect before retrying"
    p.RecordConflict(id, revision) ->
      "memory " <> id <> " head changed to " <> int.to_string(revision)
    p.SourceUnavailable(detail) -> detail
    p.Forbidden(detail) -> detail
    p.OperationIdReused -> "operation_id_reused"
    p.CapacityExceeded ->
      "persona capacity reached; user must raise capacity or export and authorize maintenance"
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
  use _ <- result.try(valid_query(query))
  store.query(ledger, fn(db) {
    use snapshot <- result.try(bound_in(db, session))
    use count <- result.try(
      store.one(
        db,
        "SELECT COUNT(*) FROM personality_memory WHERE persona_id=? AND lifecycle='active'",
        [sqlight.text(snapshot.persona.id)],
        decode.field(0, decode.int, decode.success),
        "memory count unavailable",
      )
      |> result.map_error(p.Storage),
    )
    use candidates <- result.try(candidates_in(db, snapshot.persona.id, query))
    Ok(p.Snapshot(..snapshot, candidates: candidates, eligible_count: count))
  })
}

pub fn valid_query(query: String) -> Result(Nil, p.DomainError) {
  case string.byte_size(query) <= 4096 {
    True -> Ok(Nil)
    False -> Error(p.Invalid("request query exceeds 4 KiB"))
  }
}

/// Bounded lexical terms, matching existing lowercase/literal facilities.
pub fn query_terms(query: String) -> List(String) {
  query
  |> string.lowercase
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(term) { term != "" })
  |> list.unique
  |> list.take(16)
}

fn matching(query: String) -> #(String, List(sqlight.Value)) {
  let terms = query_terms(query)
  case terms {
    [] -> #("0", [])
    _ -> #(
      "("
        <> string.join(
        list.map(terms, fn(_) { "instr(m.search_text,?)>0" }),
        " OR ",
      )
        <> ")",
      list.map(terms, sqlight.text),
    )
  }
}

fn candidate_ids_in(
  db: sqlight.Connection,
  persona: String,
  predicate: String,
  arguments: List(sqlight.Value),
  limit: Int,
) -> Result(List(String), p.DomainError) {
  store.rows(
    db,
    "SELECT m.id FROM personality_memory m WHERE m.persona_id=? AND m.lifecycle='active' AND "
      <> predicate
      <> " ORDER BY m.event_id DESC,m.id LIMIT ?",
    [sqlight.text(persona), ..list.append(arguments, [sqlight.int(limit)])],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map_error(p.Storage)
}

fn candidates_in(
  db: sqlight.Connection,
  persona: String,
  query: String,
) -> Result(List(p.Record), p.DomainError) {
  // Only current heads are probed. Pin and recency indexes are extension-owned;
  // literal query matching uses the current persona/lifecycle index, not history.
  use pins <- result.try(candidate_ids_in(
    db,
    persona,
    "CASE WHEN instr(lower(m.tags),'\"pinned\"')>0 THEN 1 ELSE 0 END=1",
    [],
    64,
  ))
  let #(predicate, arguments) = matching(query)
  use matches <- result.try(candidate_ids_in(
    db,
    persona,
    predicate
      <> case pins {
      [] -> ""
      _ ->
        " AND m.id NOT IN ("
        <> string.join(list.map(pins, fn(_) { "?" }), ",")
        <> ")"
    },
    list.append(arguments, list.map(pins, sqlight.text)),
    64,
  ))
  let anchors = list.unique(list.append(pins, matches))
  let companion_filter = case anchors {
    [] -> "m.unresolved=1"
    _ ->
      "m.unresolved=1 AND EXISTS(SELECT 1 FROM personality_memory_source own JOIN personality_memory_source anchor ON anchor.persona_id=own.persona_id AND anchor.source_id=own.source_id JOIN personality_memory current ON current.persona_id=anchor.persona_id AND current.id=anchor.memory_id AND current.revision=anchor.revision AND current.lifecycle='active' WHERE own.persona_id=m.persona_id AND own.memory_id=m.id AND own.revision=m.revision AND current.id IN ("
      <> string.join(list.map(anchors, fn(_) { "?" }), ",")
      <> "))"
  }
  use companions <- result.try(candidate_ids_in(
    db,
    persona,
    companion_filter
      <> case anchors {
      [] -> ""
      _ ->
        " AND m.id NOT IN ("
        <> string.join(list.map(anchors, fn(_) { "?" }), ",")
        <> ")"
    },
    list.append(
      list.map(anchors, sqlight.text),
      list.map(anchors, sqlight.text),
    ),
    64,
  ))
  let priority = list.unique(list.append(anchors, companions))
  // Commitment candidates are supplied by the typed domain in its later slice.
  let exclusion = case priority {
    [] -> "1"
    _ ->
      "m.id NOT IN ("
      <> string.join(list.map(priority, fn(_) { "?" }), ",")
      <> ")"
  }
  use recent <- result.try(candidate_ids_in(
    db,
    persona,
    exclusion,
    list.map(priority, sqlight.text),
    256 - list.length(priority),
  ))
  let ids = list.unique(list.append(priority, recent)) |> list.take(256)
  list.try_map(ids, fn(id) {
    use memory <- result.try(
      store.one(
        db,
        "SELECT r.memory_id,r.revision,r.lifecycle,r.text,r.provenance,r.uncertainty,r.importance,r.tags,r.temporal_scope,r.author,r.origin_session,r.event_id,r.reason,r.unresolved FROM personality_memory_revision r JOIN personality_memory m ON m.persona_id=r.persona_id AND m.id=r.memory_id AND m.revision=r.revision WHERE m.persona_id=? AND m.id=? AND m.lifecycle='active'",
        [sqlight.text(persona), sqlight.text(id)],
        memory_decoder(),
        "current recall head unavailable",
      )
      |> result.map_error(p.Storage),
    )
    use evidence <- result.try(evidence_in(db, persona, id, memory.revision))
    use related <- result.try(
      store.rows(
        db,
        "SELECT DISTINCT m.id FROM personality_memory m JOIN personality_memory_source own ON own.persona_id=m.persona_id AND own.memory_id=m.id AND own.revision=m.revision JOIN personality_memory_source anchor ON anchor.persona_id=own.persona_id AND anchor.source_id=own.source_id WHERE m.persona_id=? AND m.lifecycle='active' AND m.unresolved=1 AND anchor.memory_id=? AND anchor.revision=? ORDER BY m.id LIMIT 17",
        [sqlight.text(persona), sqlight.text(id), sqlight.int(memory.revision)],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map_error(p.Storage),
    )
    Ok(p.Record(
      with_evidence(memory, evidence),
      list.any(memory.tags, fn(tag) { string.lowercase(tag) == "pinned" }),
      False,
      False,
      related,
    ))
  })
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
    p.Conflict(_) | p.RevisionConflict(_) | p.RecordConflict(_, _) -> "conflict"
    p.SourceUnavailable(_) -> "source_unavailable"
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
      p.RecordConflict(id, revision) -> [
        #(
          "current_heads",
          json.object([
            #(
              "records",
              json.array([#(id, revision)], fn(record) {
                json.object([
                  #("id", json.string(record.0)),
                  #("revision", json.int(record.1)),
                ])
              }),
            ),
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
          use record <- decode.optional_field("current_heads", None, {
            use records <- decode.optional_field(
              "records",
              [],
              decode.list({
                use id <- decode.field("id", decode.string)
                use revision <- decode.field("revision", decode.int)
                decode.success(#(id, revision))
              }),
            )
            decode.success(list.first(records) |> option.from_result)
          })
          case record {
            Some(record) -> decode.success(p.RecordConflict(record.0, record.1))
            None -> {
              use heads <- decode.field("current_heads", {
                use revision <- decode.field("revision", decode.int)
                use identity <- decode.field("identity_revision", decode.int)
                decode.success(p.Heads(revision, identity))
              })
              decode.success(p.RevisionConflict(heads))
            }
          }
        }
        "invalid_request" -> decode.success(p.Invalid(detail))
        "source_unavailable" -> decode.success(p.SourceUnavailable(detail))
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
    ..case receipt.records {
      [] -> []
      _ -> [
        #(
          "records",
          json.array(receipt.records, fn(record) {
            json.object([
              #("id", json.string(record.0)),
              #("revision", json.int(record.1)),
            ])
          }),
        ),
      ]
    }
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
  use records <- decode.optional_field(
    "records",
    [],
    decode.list({
      use id <- decode.field("id", decode.string)
      use revision <- decode.field("revision", decode.int)
      decode.success(#(id, revision))
    }),
  )
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
    records,
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
    -> Ok(p.Snapshot(persona, binding, [], 0))
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
  use memory_capacity <- result.try(
    store.one(
      db,
      "SELECT (SELECT COUNT(*) FROM personality_memory WHERE persona_id=?),record_limit FROM personality_capacity WHERE persona_id=?",
      [sqlight.text(persona.id), sqlight.text(persona.id)],
      {
        use count <- decode.field(0, decode.int)
        use limit <- decode.field(1, decode.int)
        decode.success(#(count, limit))
      },
      "memory capacity unavailable",
    )
    |> result.map_error(p.Storage),
  )
  Ok(p.Editing(
    p.Controls(locks, persona.agent_identity_edits, persona.agent_memory_edits),
    bytes.0,
    bytes.1,
    bytes.2,
    bytes.3,
    memory_capacity.0,
    memory_capacity.1,
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
    #(
      "ordinary_headroom",
      json.int(editing.ordinary_limit - editing.ordinary_bytes),
    ),
    #("current_records", json.int(editing.current_records)),
    #("record_limit", json.int(editing.record_limit)),
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
  // Replay needs no available source, and prevalidation never holds a write lock.
  use captured <- result.try(
    store.query(ledger, fn(db) {
      use snapshot <- result.try(bound_in(db, session))
      use saved <- result.try(saved_in(
        db,
        receipt_key(snapshot.persona.id, session, mutation.operation_id),
      ))
      Ok(#(snapshot.binding, saved))
    }),
  )
  let refs =
    list.flat_map(mutation.memories, fn(change) {
      list.map(change.sources, fn(link) { link.source })
    })
  use resolved <- result.try(case captured.1 {
    Some(_) -> Ok([])
    None -> sources.resolve(ledger, captured.0, refs)
  })
  store.query(ledger, fn(db) {
    transaction(db, fn() {
      use snapshot <- result.try(bound_in(db, session))
      use _ <- result.try(case snapshot.binding == captured.0 {
        True -> Ok(Nil)
        False -> Error(p.Conflict("binding changed during memory validation"))
      })
      let persona = snapshot.persona
      let key = receipt_key(persona.id, session, mutation.operation_id)
      use saved <- result.try(saved_in(db, key))
      case saved {
        Some(#(previous, _)) if previous != request -> Error(p.OperationIdReused)
        Some(#(_, receipt)) -> {
          // A replay is already known committed. Reserve exhaustion may prevent
          // a new call alias, but must never turn a receipt read into a failure.
          case
            map_call_budget_in(
              db,
              actor,
              key,
              receipt,
              !list.any(mutation.memories, fn(change) { change.id == "" }),
            )
          {
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
          use checked <- result.try(sources.resolve_in(
            db,
            snapshot.binding,
            refs,
          ))
          use _ <- result.try(case checked == resolved {
            True -> Ok(Nil)
            False ->
              Error(p.SourceUnavailable(
                "source changed during memory validation",
              ))
          })
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
          use records <- result.try(commit_memories_in(
            db,
            persona,
            session,
            actor,
            mutation,
            resolved,
            receipt.event_id,
          ))
          let receipt = p.Receipt(..receipt, records: records)
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
          use memory_payload <- result.try(memory_payload_in(
            db,
            persona.id,
            records,
          ))
          use _ <- result.try(charge_payload_in(
            db,
            persona.id,
            !list.any(mutation.memories, fn(change) { change.id == "" }),
            string.byte_size(request)
              + string.byte_size(encoded)
              + string.byte_size(payload)
              + string.byte_size(memory_payload)
              + string.byte_size(
              json.to_string(json.array(resolved, sources.json)),
            ),
          ))
          use _ <- result.try(map_call_budget_in(
            db,
            actor,
            key,
            receipt,
            !list.any(mutation.memories, fn(change) { change.id == "" }),
          ))
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

fn map_call_budget_in(
  db: sqlight.Connection,
  actor: p.Actor,
  key: String,
  receipt: p.Receipt,
  corrective: Bool,
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
          use _ <- result.try(charge_payload_in(
            db,
            receipt.persona_id,
            corrective,
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
          False ->
            case mutation.memories {
              [] -> "controls_edited"
              _ -> "memory_edited"
            }
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
  Ok(
    p.Receipt(
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
      [],
    ),
  )
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
      "UPDATE personality_capacity SET ordinary_bytes=memory_bytes+COALESCE((SELECT SUM(length(CAST(self_description||values_text||communication||instructions||author||reason AS BLOB))) FROM personality_revision WHERE persona_id=? AND revision=1),0)+COALESCE((SELECT SUM(length(CAST(persona_id||operation_id||actor||COALESCE(origin_session,'')||event_type||base_revision||head_revision||reason||created_at AS BLOB))) FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited','memory_edited')),0)+COALESCE((SELECT SUM(length(CAST(request||result AS BLOB))) FROM personality_operation WHERE operation_id IN (SELECT operation_id FROM personality_event WHERE persona_id=? AND event_type NOT IN ('identity_edited','controls_edited','memory_edited'))),0) WHERE persona_id=?",
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

fn charge_payload_in(
  db: sqlight.Connection,
  persona: String,
  corrective: Bool,
  bytes: Int,
) -> Result(Nil, p.DomainError) {
  case corrective {
    True -> charge_in(db, persona, bytes)
    False -> {
      use changed <- result.try(
        store.rows(
          db,
          "UPDATE personality_capacity SET ordinary_bytes=ordinary_bytes+?,memory_bytes=memory_bytes+? WHERE persona_id=? AND ordinary_bytes+?<=ordinary_limit RETURNING persona_id",
          [
            sqlight.int(bytes),
            sqlight.int(bytes),
            sqlight.text(persona),
            sqlight.int(bytes),
          ],
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
  }
}

fn evidence_in(
  db: sqlight.Connection,
  persona: String,
  id: String,
  revision: Int,
) -> Result(List(p.Evidence), p.DomainError) {
  use links <- result.try(
    store.rows(
      db,
      "SELECT source_id,relation FROM personality_memory_source WHERE persona_id=? AND memory_id=? AND revision=? ORDER BY source_id,relation",
      [sqlight.text(persona), sqlight.text(id), sqlight.int(revision)],
      {
        use source <- decode.field(0, decode.string)
        use relation <- decode.field(1, decode.string)
        decode.success(#(source, relation))
      },
    )
    |> result.map_error(p.Storage),
  )
  list.try_map(links, fn(link) {
    sources.find_in(db, persona, link.0)
    |> result.map(fn(source) { p.Evidence(link.1, source) })
  })
}

fn ceiling(requested: String, links: List(p.Evidence)) -> String {
  let origins = list.map(links, fn(link) { link.source.origin })
  case list.contains(origins, "imported") {
    True -> "imported"
    False ->
      case list.contains(origins, "reported") {
        True -> "reported"
        False ->
          case requested {
            "inferred" | "reported" | "imported" | "inherited" -> requested
            _ -> "experienced"
          }
      }
  }
}

fn commit_memories_in(
  db: sqlight.Connection,
  persona: p.Persona,
  session: String,
  actor: p.Actor,
  mutation: p.Mutation,
  resolved: List(p.SourceRef),
  event: Int,
) -> Result(List(#(String, Int)), p.DomainError) {
  let #(_, changes) =
    list.map_fold(mutation.memories, resolved, fn(refs, change) {
      let count = list.length(change.sources)
      let links =
        list.map2(change.sources, list.take(refs, count), fn(link, source) {
          p.Evidence(link.relation, source)
        })
      #(list.drop(refs, count), p.MemoryChange(..change, sources: links))
    })
  use capacity <- result.try(
    store.one(
      db,
      "SELECT (SELECT COUNT(*) FROM personality_memory WHERE persona_id=?),record_limit FROM personality_capacity WHERE persona_id=?",
      [sqlight.text(persona.id), sqlight.text(persona.id)],
      {
        use count <- decode.field(0, decode.int)
        use limit <- decode.field(1, decode.int)
        decode.success(#(count, limit))
      },
      "memory capacity unavailable",
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(
    case
      list.all(changes, fn(change) { change.id != "" })
      || capacity.0
      + list.length(list.filter(changes, fn(change) { change.id == "" }))
      <= capacity.1
    {
      True -> Ok(Nil)
      False -> Error(p.CapacityExceeded)
    },
  )
  list.try_map(changes, fn(change) {
    let id = case change.id {
      "" -> new_id()
      id -> id
    }
    use previous <- result.try(case change.id {
      "" -> Ok([])
      _ -> {
        use head <- result.try(
          store.one(
            db,
            "SELECT revision FROM personality_memory WHERE persona_id=? AND id=?",
            [sqlight.text(persona.id), sqlight.text(id)],
            decode.field(0, decode.int, decode.success),
            "memory_not_found",
          )
          |> result.map_error(fn(error) {
            case error {
              "memory_not_found" -> p.NotFound
              _ -> p.Storage(error)
            }
          }),
        )
        use _ <- result.try(case head == change.expected_revision {
          True -> Ok(Nil)
          False -> Error(p.RecordConflict(id, head))
        })
        evidence_in(db, persona.id, id, head)
      }
    })
    let old =
      list.map(previous, fn(link) {
        p.Evidence(
          case change.action {
            "contradict" -> link.relation
            _ -> "corrects"
          },
          link.source,
        )
      })
    let links = list.unique(list.append(change.sources, old))
    use _ <- result.try(case list.length(links) <= 16 {
      True -> Ok(Nil)
      False -> Error(p.Invalid("revision exceeds 16 retained evidence links"))
    })
    let revision = change.expected_revision + 1
    let state = case change.action {
      "retract" -> "retracted"
      _ -> "active"
    }
    let unresolved =
      change.action == "contradict"
      || list.any(links, fn(link) { link.relation == "contradicts" })
    let author = case actor {
      p.User -> "user"
      p.OwnerAgent(_) -> "owner_agent"
    }
    let tags = json.to_string(json.array(change.tags, json.string))
    use _ <- result.try(
      store.run(
        db,
        "INSERT INTO personality_memory(id,persona_id,revision,lifecycle,importance,tags,temporal_scope,unresolved,event_id,search_text) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,lifecycle=excluded.lifecycle,importance=excluded.importance,tags=excluded.tags,temporal_scope=excluded.temporal_scope,unresolved=excluded.unresolved,event_id=excluded.event_id,search_text=excluded.search_text",
        [
          sqlight.text(id),
          sqlight.text(persona.id),
          sqlight.int(revision),
          sqlight.text(state),
          sqlight.int(change.importance),
          sqlight.text(tags),
          sqlight.text(change.temporal_scope),
          sqlight.bool(unresolved),
          sqlight.int(event),
          sqlight.text(string.lowercase(
            change.text
            <> " "
            <> string.join(change.tags, " ")
            <> " "
            <> change.temporal_scope,
          )),
        ],
      )
      |> result.map_error(p.Storage),
    )
    use _ <- result.try(
      store.run(
        db,
        "INSERT INTO personality_memory_revision(persona_id,memory_id,revision,text,provenance,uncertainty,author,origin_session,event_id,reason,lifecycle,importance,tags,temporal_scope,unresolved) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [
          sqlight.text(persona.id),
          sqlight.text(id),
          sqlight.int(revision),
          sqlight.text(change.text),
          sqlight.text(ceiling(change.provenance, links)),
          sqlight.text(change.uncertainty),
          sqlight.text(author),
          sqlight.text(session),
          sqlight.int(event),
          sqlight.text(mutation.reason),
          sqlight.text(state),
          sqlight.int(change.importance),
          sqlight.text(tags),
          sqlight.text(change.temporal_scope),
          sqlight.bool(unresolved),
        ],
      )
      |> result.map_error(p.Storage),
    )
    use _ <- result.try(
      list.try_each(links, fn(link) {
        use _ <- result.try(sources.persist_in(db, persona.id, link.source))
        store.run(
          db,
          "INSERT INTO personality_memory_source(persona_id,memory_id,revision,source_id,relation) VALUES(?,?,?,?,?)",
          [
            sqlight.text(persona.id),
            sqlight.text(id),
            sqlight.int(revision),
            sqlight.text(link.source.id),
            sqlight.text(link.relation),
          ],
        )
        |> result.map_error(p.Storage)
      }),
    )
    Ok(#(id, revision))
  })
}

fn memory_decoder() -> decode.Decoder(p.Memory) {
  use id <- decode.field(0, decode.string)
  use revision <- decode.field(1, decode.int)
  use state <- decode.field(2, decode.string)
  use text <- decode.field(3, decode.string)
  use provenance <- decode.field(4, decode.string)
  use uncertainty <- decode.field(5, decode.string)
  use importance <- decode.field(6, decode.int)
  use tags <- decode.field(7, decode.string)
  use scope <- decode.field(8, decode.string)
  use author <- decode.field(9, decode.string)
  use session <- decode.field(10, decode.string)
  use event <- decode.field(11, decode.int)
  use reason <- decode.field(12, decode.string)
  use unresolved <- decode.field(13, sqlight.decode_bool())
  case json.parse(tags, decode.list(decode.string)) {
    Ok(tags) ->
      decode.success(p.Memory(
        id,
        revision,
        state,
        text,
        provenance,
        uncertainty,
        importance,
        tags,
        scope,
        author,
        session,
        event,
        reason,
        unresolved,
        [],
        p.ClaimAttribution([], [], []),
      ))
    Error(_) ->
      decode.failure(
        p.Memory(
          "",
          0,
          "",
          "",
          "",
          "",
          0,
          [],
          "",
          "",
          "",
          0,
          "",
          False,
          [],
          p.ClaimAttribution([], [], []),
        ),
        "memory tags",
      )
  }
}

pub fn memory_json(memory: p.Memory) -> json.Json {
  json.object([
    #("id", json.string(memory.id)),
    #("revision", json.int(memory.revision)),
    #("lifecycle", json.string(memory.lifecycle)),
    #("text", json.string(memory.text)),
    #("provenance", json.string(memory.provenance)),
    #("uncertainty", json.string(memory.uncertainty)),
    #("truth_status", json.string("unverified_claim")),
    #(
      "attribution",
      json.string(
        case list.contains(memory.claim.actor_kinds, "user_assertion") {
          True -> "being_told"
          False -> "source_backed_claim"
        },
      ),
    ),
    #("source_origins", json.array(memory.claim.origins, json.string)),
    #("source_actor_kinds", json.array(memory.claim.actor_kinds, json.string)),
    #("evidence_source_ids", json.array(memory.claim.source_ids, json.string)),
    #("evidence_details", json.string("separately_paged_exact_labels")),
    #("importance", json.int(memory.importance)),
    #("tags", json.array(memory.tags, json.string)),
    #("temporal_scope", json.string(memory.temporal_scope)),
    #("author", json.string(memory.author)),
    #("origin_session", json.string(memory.origin_session)),
    #("event_id", json.int(memory.event_id)),
    #("reason", json.string(memory.reason)),
    #("unresolved", json.bool(memory.unresolved)),
    #(
      "sources",
      json.array(memory.sources, fn(link) {
        json.object([
          #("relation", json.string(link.relation)),
          #("source", sources.json(link.source)),
        ])
      }),
    ),
  ])
}

fn actor_kind(actor: String) -> String {
  case actor {
    "system_note:" <> _ -> "system_note"
    "agent_report:" <> _ -> "agent_report"
    "external_report:" <> _ -> "external_report"
    "user_assertion" | "owner_agent" | "tool_report" -> actor
    _ -> "unknown_origin"
  }
}

fn with_evidence(memory: p.Memory, evidence: List(p.Evidence)) -> p.Memory {
  p.Memory(
    ..memory,
    sources: evidence,
    claim: p.ClaimAttribution(
      list.map(evidence, fn(link) { link.source.origin }) |> list.unique,
      list.flat_map(evidence, fn(link) {
        list.map(link.source.actors, actor_kind)
      })
        |> list.unique,
      list.map(evidence, fn(link) { link.source.id }) |> list.unique,
    ),
  )
}

pub fn page_json(page: p.Page) -> json.Json {
  json.object([
    #("records", json.array(page.records, memory_json)),
    #("fragment", json.int(page.fragment)),
    #("next_cursor", json.nullable(page.next, json.string)),
    #("bytes", json.int(page.bytes)),
  ])
}

fn fragments(memory: p.Memory) -> List(p.Memory) {
  // One evidence link and tag per fragment keeps their complete labels bounded.
  let text_parts = int.max(1, { text_scalars.length(memory.text) + 127 } / 128)
  let reason_parts =
    int.max(1, { text_scalars.length(memory.reason) + 127 } / 128)
  let count =
    int.max(
      int.max(text_parts, reason_parts),
      int.max(list.length(memory.sources), list.length(memory.tags)),
    )
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    p.Memory(
      ..memory,
      text: text_scalars.drop(memory.text, index * 128)
        |> text_scalars.take(128),
      reason: text_scalars.drop(memory.reason, index * 128)
        |> text_scalars.take(128),
      sources: list.drop(memory.sources, index) |> list.take(1),
      tags: list.drop(memory.tags, index) |> list.take(1),
    )
  })
}

pub fn memories(
  db: store.Store,
  session: String,
  record_id: String,
  history: Bool,
  cursor: option.Option(String),
) -> Result(p.Page, p.DomainError) {
  memory_page(db, session, record_id, history, "", cursor)
}

pub fn search(
  db: store.Store,
  session: String,
  query: String,
  cursor: option.Option(String),
) -> Result(p.Page, p.DomainError) {
  use _ <- result.try(valid_query(query))
  memory_page(db, session, "", False, query, cursor)
}

fn memory_page(
  db: store.Store,
  session: String,
  record_id: String,
  history: Bool,
  query: String,
  cursor: option.Option(String),
) -> Result(p.Page, p.DomainError) {
  use _ <- result.try(
    case
      string.byte_size(record_id) <= 128
      && string.byte_size(option.unwrap(cursor, "")) <= 2048
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("memory ID or cursor exceeds its limit"))
    },
  )
  use captured <- result.try(
    store.query(db, fn(connection) {
      use snapshot <- result.try(bound_in(connection, session))
      let scope =
        json.to_string(json.array(
          [
            snapshot.persona.id,
            session,
            int.to_string(snapshot.binding.revision),
            int.to_string(snapshot.persona.revision),
            record_id,
            sources.hash(query),
            case history {
              True -> "history"
              False -> "current"
            },
          ],
          json.string,
        ))
      use position <- result.try(case cursor {
        None -> Ok(#("", 0, 0))
        Some(cursor) -> {
          use parts <- result.try(
            json.parse(cursor, decode.list(decode.string))
            |> result.replace_error(p.Invalid("invalid memory cursor")),
          )
          case parts {
            [binding, id, revision, fragment] if binding == scope -> {
              use revision <- result.try(
                int.parse(revision)
                |> result.replace_error(p.Invalid(
                  "invalid memory cursor revision",
                )),
              )
              use fragment <- result.try(
                int.parse(fragment)
                |> result.replace_error(p.Invalid(
                  "invalid memory cursor fragment",
                )),
              )
              case revision >= 0 && fragment >= 0 {
                True -> Ok(#(id, revision, fragment))
                False -> Error(p.Invalid("invalid memory cursor"))
              }
            }
            _ -> Error(p.Conflict("memory cursor scope or head changed"))
          }
        }
      })
      let #(after_id, after_revision, fragment) = position
      let #(match_filter, match_args) = case string.trim(query) {
        "" -> #("1", [])
        _ -> matching(query)
      }
      let predicate = case history {
        True -> ""
        False -> " AND r.revision=m.revision AND m.lifecycle='active'"
      }
      use rows <- result.try(
        store.rows(
          connection,
          "SELECT r.memory_id,r.revision,CASE WHEN r.revision<m.revision AND r.lifecycle='active' THEN 'superseded' ELSE r.lifecycle END,r.text,r.provenance,r.uncertainty,r.importance,r.tags,r.temporal_scope,r.author,r.origin_session,r.event_id,r.reason,r.unresolved FROM personality_memory_revision r JOIN personality_memory m ON m.id=r.memory_id AND m.persona_id=r.persona_id WHERE r.persona_id=? AND (?='' OR r.memory_id=?) AND (r.memory_id>? OR (r.memory_id=? AND r.revision>=?))"
            <> predicate
            <> " AND "
            <> match_filter
            <> " ORDER BY r.memory_id,r.revision LIMIT 2",
          [
            sqlight.text(snapshot.persona.id),
            sqlight.text(record_id),
            sqlight.text(record_id),
            sqlight.text(after_id),
            sqlight.text(after_id),
            sqlight.int(after_revision),
            ..match_args
          ],
          memory_decoder(),
        )
        |> result.map_error(p.Storage),
      )
      use rows <- result.try(
        list.try_map(rows, fn(memory) {
          use evidence <- result.try(evidence_in(
            connection,
            snapshot.persona.id,
            memory.id,
            memory.revision,
          ))
          Ok(with_evidence(memory, evidence))
        }),
      )
      Ok(#(scope, rows, fragment))
    }),
  )
  let #(scope, rows, fragment) = captured
  case rows {
    [] ->
      case cursor {
        None -> {
          let page = p.Page([], 0, None, 0)
          let bytes = page_json(page) |> json.to_string |> string.byte_size
          Ok(
            p.Page(
              ..page,
              bytes: bytes + string.byte_size(int.to_string(bytes)) - 1,
            ),
          )
        }
        Some(_) -> Error(p.Invalid("memory cursor outside current records"))
      }
    [memory, ..rest] -> {
      let parts = fragments(memory)
      use part <- result.try(
        list.drop(parts, fragment)
        |> list.first
        |> result.replace_error(p.Invalid("memory fragment outside revision")),
      )
      let next = case fragment + 1 < list.length(parts), rest {
        True, _ ->
          Some(
            json.to_string(json.array(
              [
                scope,
                memory.id,
                int.to_string(memory.revision),
                int.to_string(fragment + 1),
              ],
              json.string,
            )),
          )
        False, [following, ..] ->
          Some(
            json.to_string(json.array(
              [scope, following.id, int.to_string(following.revision), "0"],
              json.string,
            )),
          )
        False, [] -> None
      }
      let page = p.Page([part], fragment, next, 0)
      let bytes = page_json(page) |> json.to_string |> string.byte_size
      let page =
        p.Page(
          ..page,
          bytes: bytes + string.byte_size(int.to_string(bytes)) - 1,
        )
      case page_json(page) |> json.to_string |> string.byte_size <= 8192 {
        True -> Ok(page)
        False -> Error(p.Invalid("memory page exceeds 8 KiB rendered bytes"))
      }
    }
  }
}

fn memory_payload_in(
  db: sqlight.Connection,
  persona: String,
  records: List(#(String, Int)),
) -> Result(String, p.DomainError) {
  use payloads <- result.try(
    list.try_map(records, fn(record) {
      use memory <- result.try(
        store.one(
          db,
          "SELECT memory_id,revision,lifecycle,text,provenance,uncertainty,importance,tags,temporal_scope,author,origin_session,event_id,reason,unresolved FROM personality_memory_revision WHERE persona_id=? AND memory_id=? AND revision=?",
          [sqlight.text(persona), sqlight.text(record.0), sqlight.int(record.1)],
          memory_decoder(),
          "committed memory payload missing",
        )
        |> result.map_error(p.Storage),
      )
      use evidence <- result.try(evidence_in(db, persona, record.0, record.1))
      let memory = with_evidence(memory, evidence)
      Ok(
        json.object([
          #("revision", memory_json(memory)),
          #(
            "current",
            json.object([
              #("persona_id", json.string(persona)),
              #("id", json.string(memory.id)),
              #("revision", json.int(memory.revision)),
              #("lifecycle", json.string(memory.lifecycle)),
              #("importance", json.int(memory.importance)),
              #("tags", json.array(memory.tags, json.string)),
              #("temporal_scope", json.string(memory.temporal_scope)),
              #("unresolved", json.bool(memory.unresolved)),
              #("recall_event_id", json.int(memory.event_id)),
              #(
                "recall_search_text",
                json.string(string.lowercase(
                  memory.text
                  <> " "
                  <> string.join(memory.tags, " ")
                  <> " "
                  <> memory.temporal_scope,
                )),
              ),
            ]),
          ),
          #(
            "links",
            json.array(evidence, fn(link) {
              json.array(
                [
                  persona,
                  memory.id,
                  int.to_string(memory.revision),
                  link.source.id,
                  link.relation,
                ],
                json.string,
              )
            }),
          ),
        ]),
      )
    }),
  )
  Ok(json.to_string(json.array(payloads, fn(value) { value })))
}
