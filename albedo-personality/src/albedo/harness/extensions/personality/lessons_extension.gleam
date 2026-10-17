//// Disabled-by-default direct lesson tools/service. Never injects request context.

import albedo/daemon/http_api as api
import albedo/harness/extension
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/lessons
import albedo/harness/extensions/personality/tools as document_tools
import albedo/harness/extensions/personality/types as p
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mist

pub fn extension() -> extension.Extension {
  extension.Extension(
    "personality-lessons",
    "Optional direct lessons with revision history",
    ["personality"],
    [
      extension.ToolPlugin(
        "lesson_create(content, tags, confidence=0.5, evidence=[]) stores a simple lesson. Evidence may be external reference strings. lesson_read(id) reads it. lesson_query(text='', tags=[], include_deprecated=false, offset=0, limit=20) queries this identity's lessons. lesson_update(id, content?, tags?, confidence?, evidence?) updates directly, merging evidence. lesson_deprecate(id, reason) retains history. lesson_history(id, offset=0, limit=20) returns bounded revisions; follow next_offset. These tools never automatically inject lessons or adopt a delegated report. Native actor/session metadata and atomic call receipts are automatic; no exact transcript evidence or provenance taxonomy is required.",
        tools(),
        [],
        [],
      ),
      extension.ServicePlugin(extension.Service(
        fn(_, _) { extension.Admission(extension.DaemonToken, 65_536) },
        handle,
      )),
    ],
    lessons.initialise,
  )
}

fn fields() -> List(#(String, json.Json)) {
  [
    #("content", document_tools.scalar("string")),
    #(
      "tags",
      json.object([
        #("type", json.string("array")),
        #("items", document_tools.scalar("string")),
      ]),
    ),
    #("confidence", document_tools.scalar("number")),
    #(
      "evidence",
      json.object([
        #("type", json.string("array")),
        #("items", document_tools.scalar("string")),
      ]),
    ),
  ]
}

pub fn tools() -> List(extension.Tool) {
  [
    tool(
      "lesson_create",
      "Create a simple lesson",
      fields(),
      ["content", "tags"],
      True,
    ),
    tool(
      "lesson_read",
      "Read one lesson",
      [#("id", document_tools.scalar("string"))],
      ["id"],
      False,
    ),
    tool(
      "lesson_update",
      "Update a lesson directly",
      [#("id", document_tools.scalar("string")), ..fields()],
      ["id"],
      True,
    ),
    tool(
      "lesson_deprecate",
      "Deprecate a lesson while retaining revisions",
      [
        #("id", document_tools.scalar("string")),
        #("reason", document_tools.scalar("string")),
      ],
      ["id", "reason"],
      True,
    ),
    tool(
      "lesson_query",
      "Query lessons without automatic injection",
      [
        #("text", document_tools.scalar("string")),
        #(
          "tags",
          json.object([
            #("type", json.string("array")),
            #("items", document_tools.scalar("string")),
          ]),
        ),
        #("include_deprecated", document_tools.scalar("boolean")),
        #("offset", document_tools.scalar("integer")),
        #("limit", document_tools.scalar("integer")),
      ],
      [],
      False,
    ),
    tool(
      "lesson_history",
      "Read bounded lesson revision history",
      [
        #("id", document_tools.scalar("string")),
        #("offset", document_tools.scalar("integer")),
        #("limit", document_tools.scalar("integer")),
      ],
      ["id"],
      False,
    ),
  ]
}

fn tool(
  name: String,
  description: String,
  properties: List(#(String, json.Json)),
  required: List(String),
  mutating: Bool,
) -> extension.Tool {
  extension.Tool(
    types.Tool(
      name,
      description,
      document_tools.object(properties, required),
      True,
    ),
    fn(context, args) {
      document_tools.answer(invoke(
        context.store,
        context.session,
        p.OwnerAgent(context.call_id),
        name,
        args,
      ))
    },
    fn(context) {
      case mutating {
        False -> None
        True ->
          lessons.recover(context.store, context.session, context.call_id)
          |> result.unwrap(None)
          |> option.map(extension.text)
      }
    },
  )
}

fn invoke(
  db: store.Store,
  session: String,
  actor: p.Actor,
  name: String,
  args: String,
) -> Result(json.Json, p.DomainError) {
  case name {
    "lesson_create" -> {
      use input <- result.try(
        parse(args, name, ["content", "tags", "confidence", "evidence"], {
          use content <- decode.field("content", decode.string)
          use tags <- decode.field("tags", decode.list(decode.string))
          use confidence <- decode.optional_field(
            "confidence",
            None,
            decode.map(decode.float, Some),
          )
          use evidence <- decode.optional_field(
            "evidence",
            None,
            decode.map(decode.list(decode.string), Some),
          )
          decode.success(#(content, tags, confidence, evidence))
        }),
      )
      lessons.create(db, session, actor, input.0, input.1, input.2, input.3)
      |> result.map(lessons.to_json)
    }
    "lesson_update" -> {
      use input <- result.try(
        parse(args, name, ["id", "content", "tags", "confidence", "evidence"], {
          use id <- decode.field("id", decode.string)
          use content <- decode.optional_field(
            "content",
            None,
            decode.map(decode.string, Some),
          )
          use tags <- decode.optional_field(
            "tags",
            None,
            decode.map(decode.list(decode.string), Some),
          )
          use confidence <- decode.optional_field(
            "confidence",
            None,
            decode.map(decode.float, Some),
          )
          use evidence <- decode.optional_field(
            "evidence",
            None,
            decode.map(decode.list(decode.string), Some),
          )
          decode.success(#(id, content, tags, confidence, evidence))
        }),
      )
      lessons.update(
        db,
        session,
        actor,
        input.0,
        input.1,
        input.2,
        input.3,
        input.4,
      )
      |> result.map(lessons.to_json)
    }
    "lesson_deprecate" -> {
      use input <- result.try(
        parse(args, name, ["id", "reason"], {
          use id <- decode.field("id", decode.string)
          use reason <- decode.field("reason", decode.string)
          decode.success(#(id, reason))
        }),
      )
      lessons.deprecate(db, session, actor, input.0, input.1)
      |> result.map(lessons.to_json)
    }
    "lesson_read" -> {
      use id <- result.try(parse(
        args,
        name,
        ["id"],
        decode.field("id", decode.string, decode.success),
      ))
      lessons.read(db, session, id) |> result.map(lessons.to_json)
    }
    "lesson_history" -> {
      use input <- result.try(
        parse(args, name, ["id", "offset", "limit"], {
          use id <- decode.field("id", decode.string)
          use offset <- decode.optional_field("offset", 0, decode.int)
          use limit <- decode.optional_field("limit", 20, decode.int)
          decode.success(#(id, offset, limit))
        }),
      )
      lessons.history(db, session, input.0, input.1, input.2)
      |> result.map(lessons.page_json)
    }
    "lesson_query" -> {
      use input <- result.try(
        parse(
          args,
          name,
          ["text", "tags", "include_deprecated", "offset", "limit"],
          {
            use text <- decode.optional_field("text", "", decode.string)
            use tags <- decode.optional_field(
              "tags",
              [],
              decode.list(decode.string),
            )
            use deprecated <- decode.optional_field(
              "include_deprecated",
              False,
              decode.bool,
            )
            use offset <- decode.optional_field("offset", 0, decode.int)
            use limit <- decode.optional_field("limit", 20, decode.int)
            decode.success(#(text, tags, deprecated, offset, limit))
          },
        ),
      )
      lessons.query(db, session, input.0, input.1, input.2, input.3, input.4)
      |> result.map(lessons.page_json)
    }
    _ -> Error(p.Invalid("unknown lesson operation"))
  }
}

import albedo/daemon/store

fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(api.accepts_json(req))
    use params <- result.try(api.parameters(req, ["offset", "limit", "text"]))
    let offset =
      list.key_find(params, "offset")
      |> result.unwrap("0")
      |> int.parse
      |> result.unwrap(-1)
    let limit =
      list.key_find(params, "limit")
      |> result.unwrap("20")
      |> int.parse
      |> result.unwrap(-1)
    case req.method, path {
      Get, ["sessions", session, "lessons"] ->
        lessons.query(
          daemon.ledger,
          session,
          list.key_find(params, "text") |> result.unwrap(""),
          [],
          False,
          offset,
          limit,
        )
        |> result.map(lessons.page_json)
        |> result.map_error(failure)
      Get, ["sessions", session, "lessons", id] ->
        lessons.read(daemon.ledger, session, id)
        |> result.map(lessons.to_json)
        |> result.map_error(failure)
      Get, ["sessions", session, "lessons", id, "history"] ->
        lessons.history(daemon.ledger, session, id, offset, limit)
        |> result.map(lessons.page_json)
        |> result.map_error(failure)
      Post, ["sessions", session, "lessons"]
      | Post, ["sessions", session, "lessons", _]
      | Post, ["sessions", session, "lessons", _, "deprecate"]
      -> {
        use body <- result.try(api.body(
          req,
          ["content", "tags", "confidence", "evidence", "reason", "retry_key"],
          decode.dict(decode.string, decode.dynamic),
        ))
        use key <- result.try(case dict.get(body, "retry_key") {
          Error(_) -> Ok(ledger.new_id())
          Ok(value) ->
            decode.run(value, api.bounded_string(128, True))
            |> result.replace_error(api.invalid("invalid retry_key"))
        })
        let fields =
          dict.delete(body, "retry_key")
          |> dict.to_list
          |> list.map(fn(item) { #(item.0, api.dynamic_json(item.1)) })
        let #(name, fields) = case path {
          ["sessions", _, "lessons"] -> #("lesson_create", fields)
          ["sessions", _, "lessons", id] -> #("lesson_update", [
            #("id", json.string(id)),
            ..fields
          ])
          ["sessions", _, "lessons", id, "deprecate"] -> #("lesson_deprecate", [
            #("id", json.string(id)),
            ..fields
          ])
          _ -> #("", [])
        }
        invoke(
          daemon.ledger,
          session,
          p.User(key),
          name,
          json.to_string(json.object(fields)),
        )
        |> result.map_error(failure)
      }
      _, _ -> Error(api.Failure(404, "not_found", "lesson operation not found"))
    }
  }
  case outcome {
    Ok(value) -> api.reply(200, value)
    Error(error) -> api.fail(error)
  }
}

import gleam/dict

fn failure(error: p.DomainError) -> api.Failure {
  api.Failure(
    case error {
      p.Invalid(_) -> 400
      p.NotFound -> 404
      p.Forbidden(_) -> 403
      p.Storage(_) -> 503
      _ -> 409
    },
    "lesson_error",
    ledger.message(error),
  )
}

fn parse(
  args: String,
  name: String,
  fields: List(String),
  decoder: decode.Decoder(a),
) -> Result(a, p.DomainError) {
  json.parse(args, api.object(fields, decoder))
  |> result.replace_error(p.Invalid("invalid " <> name <> " arguments"))
}
