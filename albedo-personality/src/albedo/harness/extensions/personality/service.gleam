//// Authenticated human-only setup. The request body cannot choose its author.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api as client
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/recall
import albedo/harness/extensions/personality/sources
import albedo/harness/extensions/personality/types as p
import gleam/dynamic/decode
import gleam/http.{type Method, Delete, Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mist

pub fn admission(_path: List(String), _method: Method) -> extension.Admission {
  extension.Admission(extension.DaemonToken, 65_536)
}

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon, path, req) {
    Ok(reply) -> reply
    Error(error) -> api.fail(error)
  }
}

fn failure(error: p.DomainError) -> api.Failure {
  case error {
    p.Invalid(detail) -> api.invalid(detail)
    p.Conflict(detail) -> api.Failure(409, "personality_conflict", detail)
    p.RecordConflict(_, _) ->
      api.Failure(409, "conflict", ledger.message(error))
    p.SourceUnavailable(detail) ->
      api.Failure(409, "source_unavailable", detail)
    p.RevisionConflict(_) -> api.Failure(409, "conflict", ledger.message(error))
    p.Forbidden(detail) -> api.Failure(403, "forbidden", detail)
    p.OperationIdReused ->
      api.Failure(409, "operation_id_reused", ledger.message(error))
    p.CapacityExceeded ->
      api.Failure(409, "capacity_exceeded", ledger.message(error))
    p.NotFound -> api.Failure(404, "not_found", ledger.message(error))
    p.SetupRequired -> api.Failure(409, "setup_required", ledger.message(error))
    p.Storage(detail) -> api.Failure(503, "personality_unavailable", detail)
  }
}

fn idle_failure(error: String) -> api.Failure {
  case error {
    "session_busy" ->
      api.Failure(
        409,
        "session_busy",
        "binding changes require an idle session",
      )
    "binding_changed" | "history_changed" | "operation_conflict" ->
      api.Failure(409, "personality_conflict", error)
    "owner_only" | "archived_persona" | "default_not_configured" ->
      api.invalid(error)
    "not_found" -> api.Failure(404, "not_found", error)
    _ -> api.Failure(503, "personality_unavailable", error)
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(api.accepts_json(req))
  use parameters <- result.try(
    api.parameters(req, case path {
      ["sessions", _, "memories"] | ["sessions", _, "memories", _] -> [
        "history",
        "cursor",
      ]
      ["sessions", _, "sources", _] -> ["cursor"]
      ["sessions", _, "recall"] -> ["query", "cursor", "view"]
      _ -> []
    }),
  )
  case req.method, path {
    Post, ["sessions", id, "identity"] | Post, ["sessions", id, "memories"] -> {
      use mutation <- result.try(api.body(
        req,
        domain.mutation_fields,
        domain.decoder(True),
      ))
      case domain.mutate(daemon.ledger, id, p.User, mutation) {
        Ok(receipt) -> {
          changed(id)
          Ok(api.reply(200, ledger.receipt_json(receipt)))
        }
        Error(error) -> {
          let problem = failure(error)
          let extra = case error {
            p.RevisionConflict(heads) -> [
              #(
                "current_heads",
                json.object([
                  #("revision", json.int(heads.revision)),
                  #("identity_revision", json.int(heads.identity_revision)),
                ]),
              ),
            ]
            p.RecordConflict(record, revision) -> [
              #(
                "current_heads",
                json.object([
                  #(
                    "records",
                    json.array([#(record, revision)], fn(head) {
                      json.object([
                        #("id", json.string(head.0)),
                        #("revision", json.int(head.1)),
                      ])
                    }),
                  ),
                ]),
              ),
            ]
            _ -> []
          }
          Ok(
            api.reply(
              problem.status,
              json.object(list.append(api.problem_fields(problem), extra)),
            )
            |> response.set_header("content-type", "application/problem+json"),
          )
        }
      }
    }
    Get, ["sessions", id, "memories"] | Get, ["sessions", id, "memories", _] -> {
      use _ <- result.try(api.empty_body(req))
      let record = case path {
        ["sessions", _, "memories", record] -> record
        _ -> ""
      }
      use history <- result.try(api.boolean_parameter(parameters, "history"))
      let cursor = list.key_find(parameters, "cursor") |> option.from_result
      use page <- result.try(
        domain.inspect(
          daemon.ledger,
          id,
          record,
          option.unwrap(history, False),
          cursor,
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, ledger.page_json(page)))
    }
    Get, ["sessions", id, "recall"] -> {
      use _ <- result.try(api.empty_body(req))
      let query = list.key_find(parameters, "query") |> result.unwrap("")
      let cursor = list.key_find(parameters, "cursor") |> option.from_result
      let view = list.key_find(parameters, "view") |> result.unwrap("curated")
      use page <- result.try(
        case view {
          "curated" ->
            recall.search(daemon.ledger, id, query, cursor)
            |> result.map(ledger.page_json)
          "episodes" ->
            recall.episodes(daemon.ledger, id, query, cursor)
            |> result.map(recall.episode_page_json)
          _ -> Error(p.Invalid("recall view must be curated or episodes"))
        }
        |> result.map_error(failure),
      )
      Ok(api.reply(200, page))
    }
    Get, ["sessions", id, "sources", source] -> {
      use _ <- result.try(api.empty_body(req))
      let cursor = list.key_find(parameters, "cursor") |> option.from_result
      use page <- result.try(
        sources.expand(daemon.ledger, id, source, cursor)
        |> result.map_error(failure),
      )
      Ok(api.reply(200, sources.page_json(page)))
    }
    Get, ["sessions", id, "receipts", operation] -> {
      use _ <- result.try(api.empty_body(req))
      use receipt <- result.try(
        ledger.receipt(daemon.ledger, id, operation)
        |> result.map_error(failure),
      )
      case receipt {
        Some(receipt) -> Ok(api.reply(200, ledger.receipt_json(receipt)))
        None ->
          Error(api.Failure(
            404,
            "not_found",
            "identity operation not found in this binding and origin session",
          ))
      }
    }
    Post, ["personas"] -> {
      use config <- result.try(
        api.body(
          req,
          [
            "operation_id",
            "name",
            "make_default",
            "agent_identity_edits",
            "agent_memory_edits",
          ],
          {
            use operation <- decode.field(
              "operation_id",
              api.bounded_string(128, True),
            )
            use name <- decode.field("name", api.bounded_string(256, True))
            use default <- decode.optional_field(
              "make_default",
              False,
              decode.bool,
            )
            use identity_edits <- decode.optional_field(
              "agent_identity_edits",
              True,
              decode.bool,
            )
            use memory_edits <- decode.optional_field(
              "agent_memory_edits",
              True,
              decode.bool,
            )
            decode.success(p.Creation(
              operation,
              name,
              default,
              identity_edits,
              memory_edits,
            ))
          },
        ),
      )
      use persona <- result.try(
        ledger.create(daemon.ledger, config) |> result.map_error(failure),
      )
      changed("")
      Ok(api.reply(201, ledger.persona_json(persona)))
    }
    Post, ["default"] -> {
      use fields <- result.try(
        api.body(req, ["operation_id", "persona_id", "expected_revision"], {
          use operation <- decode.field(
            "operation_id",
            api.bounded_string(128, True),
          )
          use persona <- decode.field(
            "persona_id",
            api.bounded_string(128, True),
          )
          use expected <- decode.field("expected_revision", decode.int)
          decode.success(#(operation, persona, expected))
        }),
      )
      use persona <- result.try(
        ledger.select_default(daemon.ledger, fields.1, fields.0, fields.2)
        |> result.map_error(failure),
      )
      changed("")
      Ok(api.reply(200, ledger.persona_json(persona)))
    }
    Get, ["sessions", id] -> {
      use _ <- result.try(api.empty_body(req))
      use #(inspection, editing) <- result.try(
        ledger.inspect(daemon.ledger, id) |> result.map_error(failure),
      )
      Ok(api.reply(200, inspection_json(id, inspection, editing)))
    }
    Post, ["sessions", id, "binding"] -> {
      use change <- result.try(
        api.body(
          req,
          [
            "operation_id",
            "persona_id",
            "use_default",
            "expected_binding_revision",
            "acknowledge_history_through",
          ],
          {
            use operation <- decode.field(
              "operation_id",
              api.bounded_string(128, True),
            )
            use persona <- decode.optional_field(
              "persona_id",
              None,
              decode.optional(api.bounded_string(128, True)),
            )
            use default <- decode.optional_field(
              "use_default",
              False,
              decode.bool,
            )
            use expected <- decode.field(
              "expected_binding_revision",
              decode.int,
            )
            use through <- decode.field(
              "acknowledge_history_through",
              decode.int,
            )
            use chosen <- decode.then(case persona, default {
              Some(id), False -> decode.success(id)
              None, True -> decode.success("")
              _, _ ->
                decode.failure(
                  "",
                  "select exactly one existing persona_id or use_default",
                )
            })
            decode.success(p.Bind(operation, chosen, expected, through))
          },
        ),
      )
      use bound <- result.try(
        daemon.state(
          id,
          command.ApplyIdle(fn(db, session) {
            ledger.bind(db, session, change)
            |> result.map(ledger.binding_json)
            |> result.map_error(ledger.message)
          }),
        )
        |> result.map_error(idle_failure),
      )
      changed(id)
      Ok(api.reply(200, json.object([#("binding", bound)])))
    }
    Delete, ["sessions", id, "binding"] -> {
      use fields <- result.try(
        api.body(req, ["operation_id", "expected_binding_revision"], {
          use operation <- decode.field(
            "operation_id",
            api.bounded_string(128, True),
          )
          use expected <- decode.field("expected_binding_revision", decode.int)
          decode.success(#(operation, expected))
        }),
      )
      use revision <- result.try(
        daemon.state(
          id,
          command.ApplyIdle(fn(db, session) {
            ledger.unbind(db, session, fields.0, fields.1)
            |> result.map(json.int)
            |> result.map_error(ledger.message)
          }),
        )
        |> result.map_error(idle_failure),
      )
      changed(id)
      Ok(api.reply(
        200,
        json.object([#("binding", json.null()), #("binding_revision", revision)]),
      ))
    }
    Post, ["personas", id, "archive"] -> {
      use fields <- result.try(
        api.body(req, ["operation_id", "expected_revision"], {
          use operation <- decode.field(
            "operation_id",
            api.bounded_string(128, True),
          )
          use expected <- decode.field("expected_revision", decode.int)
          decode.success(#(operation, expected))
        }),
      )
      use persona <- result.try(
        ledger.archive(daemon.ledger, id, fields.0, fields.1)
        |> result.map_error(failure),
      )
      changed("")
      Ok(api.reply(200, ledger.persona_json(persona)))
    }
    _, _ ->
      Error(api.Failure(404, "not_found", "personality operation not found"))
  }
}

fn changed(session: String) -> Nil {
  bus.invalidate(
    ["/extensions/personality/sessions/" <> session],
    case session {
      "" -> []
      _ -> [session]
    },
    False,
  )
}

fn inspection_json(
  session: String,
  inspection: p.Inspection,
  editing: option.Option(p.Editing),
) -> json.Json {
  json.object([
    #(
      "state",
      json.string(case inspection.binding {
        None -> "setup_required"
        Some(_) -> "bound"
      }),
    ),
    #("binding", json.nullable(inspection.binding, ledger.binding_json)),
    #("binding_revision", json.int(inspection.binding_revision)),
    #("persona", json.nullable(inspection.persona, ledger.persona_json)),
    #(
      "default_persona_id",
      json.nullable(inspection.default_persona, json.string),
    ),
    #(
      "pre_binding_history",
      json.object([
        #("through", json.int(inspection.history_through)),
        #("records", json.int(inspection.history_count)),
        #("provenance", json.string("pre_binding")),
        #(
          "disclosure",
          json.string(
            "Binding makes this session's existing history visible to the identity. These rows remain pre-binding evidence; they are not retroactively its direct experiences.",
          ),
        ),
      ]),
    ),
    #("editing", json.nullable(editing, ledger.editing_json)),
    #("page", descriptor(session, inspection)),
  ])
}

fn operation(
  id: String,
  method: Method,
  path: String,
  body: List(#(String, client.Binding)),
) -> client.Operation {
  client.Operation(id, method, path, [], [], [], body, json.object([]), None)
}

fn text_field(
  name: String,
  label: String,
  required: Bool,
  default: json.Json,
) -> client.Field {
  client.Field(name, label, "text", required, default, [], "", None)
}

fn descriptor(session: String, inspection: p.Inspection) -> json.Json {
  let path = "/extensions/personality/sessions/" <> session <> "/binding"
  let common = [
    #("/operation_id", client.Literal(json.string(new_id()))),
    #(
      "/expected_binding_revision",
      client.Literal(json.int(inspection.binding_revision)),
    ),
  ]
  let bind =
    client.Action(
      "bind",
      "Bind existing identity",
      "",
      Some(
        "Existing session history becomes visible as pre-binding evidence. Confirm this explicit identity binding.",
      ),
      [text_field("persona_id", "Existing identity ID", True, json.null())],
      operation("persona_bind", Post, path, [
        #("/persona_id", client.Form("/persona_id")),
        #(
          "/acknowledge_history_through",
          client.Literal(json.int(inspection.history_through)),
        ),
        ..common
      ]),
    )
  let use_default =
    client.Action(
      "bind_default",
      "Bind configured default",
      "",
      Some(
        "Bind the configured default identity to this session and disclose its existing history as pre-binding evidence.",
      ),
      [],
      operation("persona_bind", Post, path, [
        #("/use_default", client.Literal(json.bool(True))),
        #(
          "/acknowledge_history_through",
          client.Literal(json.int(inspection.history_through)),
        ),
        ..common
      ]),
    )
  let create =
    client.Action(
      "persona_create",
      case inspection.default_persona {
        None -> "Create default empty identity"
        Some(_) -> "Create additional empty identity"
      },
      "",
      Some(
        "Create a new permanent empty identity. Nothing will be copied or bound automatically.",
      ),
      [text_field("name", "Identity name", True, json.null())],
      operation("persona_create", Post, "/extensions/personality/personas", [
        #("/operation_id", client.Literal(json.string(new_id()))),
        #("/name", client.Form("/name")),
        #(
          "/make_default",
          client.Literal(json.bool(inspection.default_persona == None)),
        ),
      ]),
    )
  let select_default =
    client.Action(
      "select_default",
      "Select existing default identity",
      "",
      Some(
        "Choose the default identity used only by explicit default-binding operations.",
      ),
      [
        text_field("persona_id", "Existing identity ID", True, json.null()),
        client.Field(
          "expected_revision",
          "Current persona revision",
          "integer",
          True,
          json.null(),
          [],
          "Read the current revision before changing default configuration",
          None,
        ),
      ],
      operation("persona_default", Post, "/extensions/personality/default", [
        #("/operation_id", client.Literal(json.string(new_id()))),
        #("/persona_id", client.Form("/persona_id")),
        #("/expected_revision", client.Form("/expected_revision")),
      ]),
    )
  let unbind =
    client.Action(
      "unbind",
      "Unbind identity",
      "",
      Some(
        "Unbind this idle session. Personality remains selected and will need setup before another request.",
      ),
      [],
      operation("persona_unbind", Delete, path, common),
    )
  client.page(
    client.Page(
      "personality",
      "Human-only identity setup",
      "Choose an existing identity or deliberately create an empty one",
      None,
      [
        bind,
        use_default,
        create,
        select_default,
        ..case inspection.binding {
          None -> []
          Some(_) -> [unbind]
        }
      ],
      [
        client.PageRow(
          session,
          case inspection.persona {
            None -> "Setup required"
            Some(persona) -> persona.name
          },
          Some(case inspection.binding {
            None -> "unbound"
            Some(_) -> "owner"
          }),
          "plain",
          Some(
            "History through "
            <> int.to_string(inspection.history_through)
            <> " remains pre-binding evidence. Persona text never grants tool permissions.",
          ),
          json.null(),
        ),
      ],
    ),
  )
}

pub fn clients() -> List(client.Command) {
  [
    client.Command(
      "/personality",
      client.Read,
      [],
      client.Operation(
        "personality_inspect",
        Get,
        "/extensions/personality/sessions/{id}",
        [#("id", client.Session("/id"))],
        [],
        [],
        [],
        json.object([]),
        None,
      ),
    ),
  ]
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String
