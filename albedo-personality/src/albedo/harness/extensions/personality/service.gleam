//// Authenticated human free-form setup and editing. The body cannot name actor.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api as client
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/types as p
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mist

pub fn admission(_path: List(String), _method: Method) -> extension.Admission {
  extension.Admission(extension.DaemonToken, domain.body_limit)
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
  api.Failure(
    case error {
      p.Invalid(_) -> 400
      p.Forbidden(_) -> 403
      p.NotFound -> 404
      p.Storage(_) -> 503
      _ -> 409
    },
    case error {
      p.Invalid(_) -> "invalid"
      p.Forbidden(_) -> "forbidden"
      p.NotFound -> "not_found"
      p.Storage(_) -> "personality_unavailable"
      p.SetupRequired -> "setup_required"
      p.CallReused -> "call_reused"
      _ -> "conflict"
    },
    ledger.message(error),
  )
}

fn idle_failure(error: String) -> api.Failure {
  api.Failure(
    case string.starts_with(error, "compaction_selection_conflict:") {
      True -> 409
      False ->
        case error {
          "session_busy" | "history_changed" | "binding_changed" -> 409
          _ -> 503
        }
    },
    "personality_unavailable",
    error,
  )
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(api.accepts_json(req))
  use params <- result.try(
    api.parameters(req, case path {
      ["sessions", _, "document"] -> ["revision", "offset", "limit"]
      _ -> []
    }),
  )
  case req.method, path {
    Get, ["sessions", session, "document"] -> {
      use _ <- result.try(api.empty_body(req))
      use revision <- result.try(parameter(params, "revision", None))
      use offset <- result.try(parameter(params, "offset", Some(0)))
      use limit <- result.try(parameter(
        params,
        "limit",
        Some(domain.read_limit),
      ))
      use page <- result.try(
        ledger.read_document(
          daemon.ledger,
          session,
          revision,
          option.unwrap(offset, 0),
          option.unwrap(limit, domain.read_limit),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, ledger.page_json(page)))
    }
    Post, ["sessions", session, "document"] -> {
      use args <- result.try(
        api.body(req, ["content", "expected_revision", "retry_key"], {
          use content <- decode.field("content", decode.string)
          use expected <- decode.optional_field(
            "expected_revision",
            None,
            decode.map(decode.int, Some),
          )
          use key <- decode.optional_field(
            "retry_key",
            ledger.new_id(),
            api.bounded_string(128, True),
          )
          decode.success(#(content, expected, key))
        }),
      )
      use receipt <- result.try(
        ledger.write_document(
          daemon.ledger,
          session,
          p.User(args.2),
          args.0,
          args.1,
        )
        |> result.map_error(failure),
      )
      changed(session)
      Ok(api.reply(200, ledger.receipt_json(receipt)))
    }
    Post, ["sessions", session, "edit"] -> {
      use args <- result.try(
        api.body(
          req,
          ["old_string", "new_string", "replace_all", "retry_key"],
          {
            use old <- decode.field("old_string", decode.string)
            use new <- decode.field("new_string", decode.string)
            use all <- decode.optional_field("replace_all", False, decode.bool)
            use key <- decode.optional_field(
              "retry_key",
              ledger.new_id(),
              api.bounded_string(128, True),
            )
            decode.success(#(old, new, all, key))
          },
        ),
      )
      use receipt <- result.try(
        ledger.edit_document(
          daemon.ledger,
          session,
          p.User(args.3),
          args.0,
          args.1,
          args.2,
        )
        |> result.map_error(failure),
      )
      changed(session)
      Ok(api.reply(200, ledger.receipt_json(receipt)))
    }
    Post, ["sessions", session, "setup"] -> {
      use args <- result.try(api.body(
        req,
        ["name", "content", "writable", "retry_key"],
        creation_decoder(),
      ))
      use captured <- result.try(
        daemon.state(
          session,
          command.ApplyIdle(fn(db, id) {
            ledger.setup(
              db,
              id,
              args.0,
              args.1,
              args.2,
              args.3,
              daemon.declarations(),
            )
            |> result.map(fn(captured) {
              json.object([
                #("persona", ledger.persona_json(captured.persona)),
                #("binding", ledger.binding_json(captured.binding)),
              ])
            })
            |> result.map_error(ledger.message)
          }),
        )
        |> result.map_error(idle_failure),
      )
      changed(session)
      Ok(api.reply(201, captured))
    }
    Post, ["personas"] -> {
      use args <- result.try(api.body(
        req,
        ["name", "content", "writable", "retry_key"],
        creation_decoder(),
      ))
      use persona <- result.try(
        ledger.create_with_key(daemon.ledger, args.0, args.1, args.2, args.3)
        |> result.map_error(failure),
      )
      changed("")
      Ok(api.reply(201, ledger.persona_json(persona)))
    }
    Post, ["default"] -> {
      use persona <- result.try(api.body(
        req,
        ["persona_id"],
        decode.field(
          "persona_id",
          api.bounded_string(128, True),
          decode.success,
        ),
      ))
      use _ <- result.try(
        ledger.select_default(daemon.ledger, persona)
        |> result.map_error(failure),
      )
      changed("")
      Ok(api.reply(
        200,
        json.object([#("default_persona_id", json.string(persona))]),
      ))
    }
    Post, ["sessions", session, "binding"] -> {
      use args <- result.try(
        api.body(
          req,
          ["persona_id", "expected_generation", "acknowledge_history_through"],
          {
            use persona <- decode.optional_field(
              "persona_id",
              "",
              decode.string,
            )
            use generation <- decode.field("expected_generation", decode.int)
            use through <- decode.field(
              "acknowledge_history_through",
              decode.int,
            )
            decode.success(#(persona, generation, through))
          },
        ),
      )
      use bound <- result.try(
        daemon.state(
          session,
          command.ApplyIdle(fn(db, id) {
            ledger.bind(db, id, args.0, args.1, args.2, daemon.declarations())
            |> result.map(ledger.binding_json)
            |> result.map_error(ledger.message)
          }),
        )
        |> result.map_error(idle_failure),
      )
      changed(session)
      Ok(api.reply(200, json.object([#("binding", bound)])))
    }
    Get, ["sessions", session] -> {
      use _ <- result.try(api.empty_body(req))
      use inspection <- result.try(
        ledger.inspect(daemon.ledger, session) |> result.map_error(failure),
      )
      Ok(api.reply(200, inspection_json(session, inspection)))
    }
    _, _ ->
      Error(api.Failure(404, "not_found", "personality operation not found"))
  }
}

fn creation_decoder() -> decode.Decoder(#(String, String, Bool, String)) {
  use name <- decode.field("name", api.bounded_string(256, True))
  use content <- decode.field("content", decode.string)
  use writable <- decode.optional_field("writable", True, decode.bool)
  use key <- decode.optional_field(
    "retry_key",
    ledger.new_id(),
    api.bounded_string(128, True),
  )
  decode.success(#(name, content, writable, key))
}

fn parameter(
  params: List(#(String, String)),
  name: String,
  default: option.Option(Int),
) -> Result(option.Option(Int), api.Failure) {
  case list.key_find(params, name) {
    Error(_) -> Ok(default)
    Ok(value) ->
      int.parse(value)
      |> result.map(Some)
      |> result.replace_error(api.invalid("invalid integer parameter: " <> name))
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

fn inspection_json(session: String, inspection: p.Inspection) -> json.Json {
  json.object([
    #("binding", json.nullable(inspection.binding, ledger.binding_json)),
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
        #("perspective", json.string("witnessed")),
      ]),
    ),
    #("owner_sessions", json.array(inspection.owner_sessions, json.string)),
    #("page", descriptor(session, inspection)),
  ])
}

fn action(
  id: String,
  label: String,
  path: String,
  fields: List(client.Field),
  body: List(#(String, client.Binding)),
) -> client.Action {
  client.Action(
    id,
    label,
    "",
    None,
    fields,
    client.Operation(
      ..client.operation_defaults(id, Post, path, case id {
        "setup" | "create" -> 201
        _ -> 200
      }),
      body: body,
    ),
  )
}

fn descriptor(session: String, inspection: p.Inspection) -> json.Json {
  let root = "/extensions/personality/sessions/" <> session
  let key = #("/retry_key", client.Literal(json.string(ledger.new_id())))
  let create_fields = [
    client.text_field("name", True),
    client.Field(
      ..client.text_field("content", True),
      label: "Initial identity document",
    ),
  ]
  let choice =
    client.Field(
      ..client.choice_field("persona_id", True, []),
      label: "Identity",
      choices: list.map(inspection.identity_choices, fn(item) {
        #(json.string(item.0), item.1)
      }),
    )
  let binding =
    action(
      "select",
      "Attach existing identity",
      root <> "/binding",
      [choice],
      list.append(client.form_body(["persona_id"]), [
        #(
          "/expected_generation",
          client.Literal(json.int(
            option.map(inspection.binding, fn(value) { value.generation })
            |> option.unwrap(0),
          )),
        ),
        #(
          "/acknowledge_history_through",
          client.Literal(json.int(inspection.history_through)),
        ),
      ]),
    )
  let setup =
    action("setup", "Create default identity", root <> "/setup", create_fields, [
      key,
      ..client.form_body(["name", "content"])
    ])
  let create =
    client.Action(
      ..action(
        "create",
        "Create additional permanent identity",
        "/extensions/personality/personas",
        create_fields,
        [key, ..client.form_body(["name", "content"])],
      ),
      confirmation: Some("Create a separate permanent identity?"),
    )
  let default =
    action(
      "default",
      "Choose default identity",
      "/extensions/personality/default",
      [choice],
      client.form_body(["persona_id"]),
    )
  let editing = case inspection.persona {
    None -> []
    Some(persona) -> [
      action(
        "edit",
        "Edit identity paragraph",
        root <> "/edit",
        [
          client.text_field("old_string", True),
          client.text_field("new_string", True),
        ],
        [key, ..client.form_body(["old_string", "new_string"])],
      ),
      action(
        "write",
        "Replace identity document",
        root <> "/document",
        [
          client.Field(
            ..client.text_field("content", True),
            description: "Intentional whole-document replacement",
          ),
        ],
        [
          key,
          #(
            "/expected_revision",
            client.Literal(json.int(persona.identity_revision)),
          ),
          ..client.form_body(["content"])
        ],
      ),
    ]
  }
  client.page(
    client.Page(
      "Personality",
      "Living identity; history stays attributed",
      "Set up the default or attach an existing identity",
      None,
      list.flatten([
        case inspection.default_persona {
          None -> [setup]
          Some(_) -> [binding, default, create]
        },
        editing,
      ]),
      case inspection.persona {
        None -> [
          client.PageRow(
            "identity",
            "Setup required",
            None,
            "plain",
            Some(
              "Existing history through "
              <> int.to_string(inspection.history_through)
              <> " remains witnessed history",
            ),
            json.null(),
          ),
        ]
        Some(persona) ->
          document_rows(
            persona,
            domain.prefix(persona.document, domain.read_limit),
            0,
          )
      },
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
        ..client.operation_defaults(
          "personality_inspect",
          Get,
          "/extensions/personality/sessions/{id}",
          200,
        ),
        path: [#("id", client.Session("/id"))],
      ),
    ),
  ]
}

/// The ordinary page's detail panes expose the bounded document directly.
/// Chunk rows fit the shared terminal pane; full revisions remain paged by API.
fn document_rows(
  persona: p.Persona,
  text: String,
  offset: Int,
) -> List(client.PageRow) {
  let chunk = domain.prefix(text, 1024)
  let size = string.byte_size(chunk)
  let assert <<_:bytes-size(size), bytes:bytes>> = <<text:utf8>>
  let assert Ok(rest) = bit_array.to_string(bytes)
  let end = offset + size
  let omitted = string.byte_size(persona.document) - end
  let detail =
    chunk
    <> case rest == "" && omitted > 0 {
      True ->
        "\n\n["
        <> int.to_string(omitted)
        <> " bytes omitted; persona_read revision "
        <> int.to_string(persona.identity_revision)
        <> " offset "
        <> int.to_string(end)
        <> "]"
      False -> ""
    }
  let row =
    client.PageRow(
      "document-" <> int.to_string(offset),
      persona.name
        <> " · document bytes "
        <> int.to_string(offset)
        <> "–"
        <> int.to_string(end),
      Some("revision " <> int.to_string(persona.identity_revision)),
      "plain",
      Some(detail),
      ledger.page_json(
        p.DocumentPage(persona.identity_revision, chunk, case omitted > 0 {
          True -> Some(end)
          False -> None
        }),
      ),
    )
  case rest {
    "" -> [row]
    _ -> [row, ..document_rows(persona, rest, end)]
  }
}
