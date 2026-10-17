//// Authenticated human free-form setup and editing. The body cannot name actor.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/command
import albedo/harness/extension
import gleam/dynamic/decode
import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mist
import successor/personality/domain
import successor/personality/ledger
import successor/personality/types as p

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
    case error {
      "session_busy" | "history_changed" | "binding_changed" -> 409
      _ -> 503
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
          use expected <- decode.field(
            "expected_revision",
            decode.map(decode.int, Some),
          )
          use key <- decode.field("retry_key", api.bounded_string(128, True))
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
          [
            "old_string",
            "new_string",
            "replace_all",
            "retry_key",
            "expected_revision",
          ],
          {
            use old <- decode.field("old_string", decode.string)
            use new <- decode.field("new_string", decode.string)
            use all <- decode.optional_field("replace_all", False, decode.bool)
            use key <- decode.field("retry_key", api.bounded_string(128, True))
            use expected <- decode.field("expected_revision", decode.int)
            decode.success(#(old, new, all, key, expected))
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
          args.4,
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
    Post, ["sessions", session, "unbind"] -> {
      use expected <- result.try(api.body(
        req,
        ["expected_generation"],
        decode.field("expected_generation", decode.int, decode.success),
      ))
      use reply <- result.try(
        daemon.state(
          session,
          command.ApplyIdle(fn(db, id) {
            ledger.unbind(db, id, expected)
            |> result.map(fn(_) { json.object([#("unbound", json.bool(True))]) })
            |> result.map_error(ledger.message)
          }),
        )
        |> result.map_error(idle_failure),
      )
      changed(session)
      Ok(api.reply(200, reply))
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
  use key <- decode.field("retry_key", api.bounded_string(128, True))
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
    #("binding_generation", json.int(inspection.binding_generation)),
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
    #("session", json.string(session)),
  ])
}
