//// Shared identity mutation rules. Adapters supply authority; text never does.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/sources
import albedo/harness/extensions/personality/types as p
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub const fields = [
  "self_description",
  "values",
  "communication",
  "instructions",
]

pub const mutation_fields = [
  "operation_id", "expected_revision", "expected_identity_revision", "changes",
  "reason", "controls", "memories",
]

pub fn decoder(user: Bool) -> decode.Decoder(p.Mutation) {
  api.object(
    case user {
      True -> mutation_fields
      False -> list.filter(mutation_fields, fn(field) { field != "controls" })
    },
    {
      use operation <- decode.field("operation_id", decode.string)
      use expected <- decode.field("expected_revision", decode.int)
      use identity <- decode.field("expected_identity_revision", decode.int)
      use reason <- decode.field("reason", decode.string)
      use changes <- decode.optional_field(
        "changes",
        [],
        api.object(
          fields,
          decode.map(decode.dict(decode.string, decode.string), dict.to_list),
        ),
      )
      use controls <- decode.optional_field(
        "controls",
        None,
        decode.map(
          api.object(
            ["field_locks", "agent_identity_edits", "agent_memory_edits"],
            {
              use locks <- decode.optional_field(
                "field_locks",
                None,
                decode.map(decode.list(decode.string), Some),
              )
              use identity <- decode.optional_field(
                "agent_identity_edits",
                None,
                decode.map(decode.bool, Some),
              )
              use memory <- decode.optional_field(
                "agent_memory_edits",
                None,
                decode.map(decode.bool, Some),
              )
              decode.success(p.ControlChange(locks, identity, memory))
            },
          ),
          Some,
        ),
      )
      use memories <- decode.optional_field(
        "memories",
        [],
        decode.list(memory_decoder()),
      )
      decode.success(p.Mutation(
        operation,
        expected,
        identity,
        changes,
        reason,
        controls,
        memories,
      ))
    },
  )
}

pub fn actor_name(actor: p.Actor) -> String {
  case actor {
    p.User -> "user"
    p.OwnerAgent(_) -> "owner_agent"
  }
}

pub fn canonical(mutation: p.Mutation, actor: p.Actor) -> String {
  json.object([
    #(
      "kind",
      json.string(case mutation.memories {
        [] -> "identity_edit"
        _ -> "persona_edit"
      }),
    ),
    #("actor", json.string(actor_name(actor))),
    #("expected_revision", json.int(mutation.expected_revision)),
    #(
      "expected_identity_revision",
      json.int(mutation.expected_identity_revision),
    ),
    #("reason", json.string(mutation.reason)),
    #(
      "changes",
      json.object(
        list.filter_map(fields, fn(field) {
          list.key_find(mutation.changes, field)
          |> result.map(fn(value) { #(field, json.string(value)) })
        }),
      ),
    ),

    #(
      "controls",
      json.nullable(mutation.controls, fn(control) {
        json.object([
          #(
            "field_locks",
            json.nullable(control.field_locks, fn(locks) {
              json.array(
                list.filter(fields, list.contains(locks, _)),
                json.string,
              )
            }),
          ),
          #(
            "agent_identity_edits",
            json.nullable(control.agent_identity_edits, json.bool),
          ),
          #(
            "agent_memory_edits",
            json.nullable(control.agent_memory_edits, json.bool),
          ),
        ])
      }),
    ),
    ..case mutation.memories {
      [] -> []
      _ -> [#("memories", json.array(mutation.memories, memory_change_json))]
    }
  ])
  |> json.to_string
}

pub fn hash(content: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(content))
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn mutate(
  db: store.Store,
  session: String,
  actor: p.Actor,
  mutation: p.Mutation,
) -> Result(p.Receipt, p.DomainError) {
  use _ <- result.try(validate(mutation))
  let request = canonical(mutation, actor)
  use _ <- result.try(case string.byte_size(request) > 65_536 {
    True -> Error(p.Invalid("mutation exceeds 64 KiB"))
    False -> Ok(Nil)
  })
  ledger.edit(
    db,
    session,
    actor,
    mutation,
    request,
    hash(request),
    fn(persona, controls) { prepare(persona, controls, actor, mutation) },
  )
}

pub fn validate(mutation: p.Mutation) -> Result(Nil, p.DomainError) {
  case
    string.trim(mutation.operation_id) == ""
    || string.byte_size(mutation.operation_id) > 128
    || string.trim(mutation.reason) == ""
    || string.byte_size(mutation.reason) > 4096
    || mutation.expected_revision < 1
    || mutation.expected_identity_revision < 1
    || list.length(mutation.changes) + list.length(mutation.memories) > 32
    || list.length(
      list.unique(list.map(mutation.changes, fn(change) { change.0 })),
    )
    != list.length(mutation.changes)
    || !list.all(mutation.changes, fn(change) {
      list.contains(fields, change.0) && string.byte_size(change.1) <= 4096
    })
  {
    True ->
      Error(p.Invalid("invalid operation, revisions, reason or identity fields"))
    False -> {
      use _ <- result.try(validate_memories(mutation.memories))
      case mutation.changes, mutation.controls, mutation.memories {
        [], None, [] -> Error(p.Invalid("persona mutation is empty"))
        _, Some(control), _ ->
          case control.field_locks {
            Some(locks) ->
              case
                list.length(locks) <= 4
                && list.all(locks, list.contains(fields, _))
                && list.length(list.unique(locks)) == list.length(locks)
              {
                True -> Ok(Nil)
                False -> Error(p.Invalid("invalid field locks"))
              }
            None -> Ok(Nil)
          }
        _, _, _ -> Ok(Nil)
      }
    }
  }
}

fn prepare(
  persona: p.Persona,
  controls: p.Controls,
  actor: p.Actor,
  mutation: p.Mutation,
) -> Result(p.Edit, p.DomainError) {
  use _ <- result.try(case actor {
    p.User -> Ok(Nil)
    p.OwnerAgent(call) ->
      case
        string.trim(call) == ""
        || string.byte_size(call) > 512
        || mutation.changes != []
        && !controls.agent_identity_edits
        || mutation.memories != []
        && !controls.agent_memory_edits
        || mutation.controls != None
        || list.any(mutation.changes, fn(change) {
          list.contains(controls.field_locks, change.0)
        })
      {
        True ->
          Error(p.Forbidden(
            "agent identity edits disabled, locked or user-only controls",
          ))
        False -> Ok(Nil)
      }
  })
  let value = fn(field, old) {
    list.key_find(mutation.changes, field) |> result.unwrap(old)
  }
  let identity =
    p.Identity(
      value("self_description", persona.identity.self_description),
      value("values", persona.identity.values),
      value("communication", persona.identity.communication),
      value("instructions", persona.identity.instructions),
    )
  let bytes =
    string.byte_size(identity.self_description)
    + string.byte_size(identity.values)
    + string.byte_size(identity.communication)
    + string.byte_size(identity.instructions)
  use _ <- result.try(case bytes > 12_288 {
    True -> Error(p.Invalid("current identity exceeds 12 KiB UTF-8"))
    False -> Ok(Nil)
  })
  let controls = case mutation.controls {
    None -> controls
    Some(change) ->
      p.Controls(
        option.unwrap(change.field_locks, controls.field_locks),
        option.unwrap(
          change.agent_identity_edits,
          controls.agent_identity_edits,
        ),
        option.unwrap(change.agent_memory_edits, controls.agent_memory_edits),
      )
  }
  Ok(p.Edit(identity, controls, mutation.changes != []))
}

fn memory_decoder() -> decode.Decoder(p.MemoryChange) {
  api.object(
    [
      "id",
      "expected_revision",
      "action",
      "text",
      "provenance",
      "uncertainty",
      "importance",
      "tags",
      "temporal_scope",
      "sources",
    ],
    {
      use id <- decode.optional_field("id", "", decode.string)
      use expected <- decode.optional_field("expected_revision", 0, decode.int)
      use action <- decode.optional_field("action", "remember", decode.string)
      use text <- decode.field("text", decode.string)
      use provenance <- decode.field("provenance", decode.string)
      use uncertainty <- decode.field("uncertainty", decode.string)
      use importance <- decode.optional_field("importance", 1, decode.int)
      use tags <- decode.optional_field("tags", [], decode.list(decode.string))
      use scope <- decode.optional_field("temporal_scope", "", decode.string)
      use sources <- decode.optional_field(
        "sources",
        [],
        decode.list(
          api.object(
            [
              "relation",
              "source_id",
              "first_seq",
              "last_seq",
              "digest",
              "lcm_hint",
            ],
            {
              use relation <- decode.field("relation", decode.string)
              // The source decoder sees only source fields, after relation is removed.
              use id <- decode.optional_field("source_id", "", decode.string)
              use first <- decode.optional_field("first_seq", 0, decode.int)
              use last <- decode.optional_field("last_seq", 0, decode.int)
              use digest <- decode.optional_field("digest", "", decode.string)
              use hint <- decode.optional_field(
                "lcm_hint",
                None,
                decode.optional(decode.string),
              )
              decode.success(p.Evidence(
                relation,
                p.SourceRef(id, "", first, last, digest, [], "", 0, 0, hint, ""),
              ))
            },
          ),
        ),
      )
      decode.success(p.MemoryChange(
        id,
        expected,
        action,
        text,
        provenance,
        uncertainty,
        importance,
        tags,
        scope,
        sources,
      ))
    },
  )
}

pub fn memory_change_json(change: p.MemoryChange) -> json.Json {
  json.object([
    #("id", json.string(change.id)),
    #("expected_revision", json.int(change.expected_revision)),
    #("action", json.string(change.action)),
    #("text", json.string(change.text)),
    #("provenance", json.string(change.provenance)),
    #("uncertainty", json.string(change.uncertainty)),
    #("importance", json.int(change.importance)),
    #("tags", json.array(list.sort(change.tags, string.compare), json.string)),
    #("temporal_scope", json.string(change.temporal_scope)),
    #(
      "sources",
      json.array(change.sources, fn(evidence) {
        json.object([
          #("relation", json.string(evidence.relation)),
          #("source", sources.input_json(evidence.source)),
        ])
      }),
    ),
  ])
}

fn validate_memories(
  memories: List(p.MemoryChange),
) -> Result(Nil, p.DomainError) {
  use _ <- result.try(
    case
      list.length(
        list.unique(
          list.filter_map(memories, fn(change) {
            case change.id {
              "" -> Error(Nil)
              id -> Ok(id)
            }
          }),
        ),
      )
      == list.length(list.filter(memories, fn(change) { change.id != "" }))
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("a memory may change only once per mutation"))
    },
  )
  list.try_each(memories, fn(change) {
    case
      string.byte_size(change.id) <= 128
      && list.contains(
        ["remember", "correct", "contradict", "retract"],
        change.action,
      )
      && case change.id {
        "" -> change.action == "remember" && change.expected_revision == 0
        _ -> change.action != "remember" && change.expected_revision > 0
      }
      && string.trim(change.text) != ""
      && string.byte_size(change.text) <= 4096
      && list.contains(
        ["experienced", "imported", "inferred", "reported", "inherited"],
        change.provenance,
      )
      && string.trim(change.uncertainty) != ""
      && string.byte_size(change.uncertainty) <= 128
      && change.importance >= 0
      && change.importance <= 3
      && list.length(change.tags) <= 16
      && list.length(list.unique(change.tags)) == list.length(change.tags)
      && list.all(change.tags, fn(tag) {
        string.trim(tag) != "" && string.byte_size(tag) <= 128
      })
      && string.byte_size(change.temporal_scope) <= 128
      && list.length(change.sources) <= 16
      && list.all(change.sources, fn(link) {
        list.contains(["supports", "contradicts", "corrects"], link.relation)
      })
      && case change.id {
        "" -> change.sources != []
        _ -> True
      }
    {
      True -> Ok(Nil)
      False ->
        Error(p.Invalid(
          "invalid memory head, action, text, provenance, uncertainty, tags or evidence",
        ))
    }
  })
}

pub fn inspect(
  db: store.Store,
  session: String,
  record_id: String,
  history: Bool,
  cursor: option.Option(String),
) -> Result(p.Page, p.DomainError) {
  ledger.memories(db, session, record_id, history, cursor)
}
