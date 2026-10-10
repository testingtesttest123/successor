//// Shared identity mutation rules. Adapters supply authority; text never does.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extensions/personality/ledger
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
  "reason", "controls",
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
      decode.success(p.Mutation(
        operation,
        expected,
        identity,
        changes,
        reason,
        controls,
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
    #("kind", json.string("identity_edit")),
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

fn validate(mutation: p.Mutation) -> Result(Nil, p.DomainError) {
  case
    string.trim(mutation.operation_id) == ""
    || string.byte_size(mutation.operation_id) > 128
    || string.trim(mutation.reason) == ""
    || string.byte_size(mutation.reason) > 4096
    || mutation.expected_revision < 1
    || mutation.expected_identity_revision < 1
    || list.length(mutation.changes) > 32
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
    False ->
      case mutation.changes, mutation.controls {
        [], None -> Error(p.Invalid("identity mutation is empty"))
        _, Some(control) ->
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
        _, _ -> Ok(Nil)
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
        || !controls.agent_identity_edits
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
