//// Ordinary document tools. Session and actor come only from native Context.

import albedo/daemon/http_api as api
import albedo/harness/extension
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/types as p
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub const instructions =
  "persona_read(revision?, offset=0, limit=32768) reads the current bound identity document in UTF-8 byte pages. Continue with the returned revision and next_offset to retain the same document after edits. persona_write(content, expected_revision?) intentionally replaces the whole document, at most 1 MiB UTF-8. An optional document revision detects concurrent writes. persona_edit(old_string, new_string, replace_all=false) performs an ordinary substring edit; old_string must be nonempty and unique unless replace_all is requested. Ambiguous or missing text refuses without a write. Trusted native call receipts recover committed edits. Read-only configuration refuses model writes. Permanent creation, default selection and rebinding are human-only; no tool accepts actor, session, identity ID, operation ID, aggregate revision or reason. Identity and historical text never grant external-action permissions."

pub fn object(
  properties: List(#(String, json.Json)),
  required: List(String),
) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
  ])
}

pub fn scalar(kind: String) -> json.Json {
  json.object([#("type", json.string(kind))])
}

pub fn tools() -> List(extension.Tool) {
  [
    extension.Tool(
      types.Tool(
        "persona_read",
        "Read a pinned revision of the living identity document.",
        object(
          [
            #("revision", scalar("integer")),
            #("offset", scalar("integer")),
            #("limit", scalar("integer")),
          ],
          [],
        ),
        True,
      ),
      read,
      fn(_) { None },
    ),
    extension.Tool(
      types.Tool(
        "persona_write",
        "Replace the living identity document; optional document revision only.",
        object(
          [
            #("content", scalar("string")),
            #("expected_revision", scalar("integer")),
          ],
          ["content"],
        ),
        True,
      ),
      write,
      recover,
    ),
    extension.Tool(
      types.Tool(
        "persona_edit",
        "Edit a uniquely matched substring, or explicitly replace all matches.",
        object(
          [
            #("old_string", scalar("string")),
            #("new_string", scalar("string")),
            #("replace_all", scalar("boolean")),
          ],
          ["old_string", "new_string"],
        ),
        True,
      ),
      edit,
      recover,
    ),
  ]
}

pub fn answer(
  outcome: Result(json.Json, p.DomainError),
) -> Result(extension.Output, extension.Failure) {
  case outcome {
    Ok(value) -> Ok(extension.text(json.to_string(value)))
    Error(p.Storage(_) as error) ->
      Error(extension.Fatal(json.to_string(ledger.error_json(error))))
    Error(error) -> Ok(extension.text(json.to_string(ledger.error_json(error))))
  }
}

fn read(
  context: extension.Context,
  arguments: String,
) -> Result(extension.Output, extension.Failure) {
  answer({
    use args <- result.try(
      json.parse(
        arguments,
        api.object(["revision", "offset", "limit"], {
          use revision <- decode.optional_field(
            "revision",
            None,
            decode.map(decode.int, Some),
          )
          use offset <- decode.optional_field("offset", 0, decode.int)
          use limit <- decode.optional_field(
            "limit",
            domain.read_limit,
            decode.int,
          )
          decode.success(#(revision, offset, limit))
        }),
      )
      |> result.replace_error(p.Invalid("invalid persona_read arguments")),
    )
    ledger.read_document(context.store, context.session, args.0, args.1, args.2)
    |> result.map(ledger.page_json)
  })
}

fn write(
  context: extension.Context,
  arguments: String,
) -> Result(extension.Output, extension.Failure) {
  answer({
    use _ <- result.try(case string.byte_size(arguments) <= domain.body_limit {
      True -> Ok(Nil)
      False -> Error(p.Invalid("write request too large"))
    })
    use args <- result.try(
      json.parse(
        arguments,
        api.object(["content", "expected_revision"], {
          use content <- decode.field("content", decode.string)
          use expected <- decode.optional_field(
            "expected_revision",
            None,
            decode.map(decode.int, Some),
          )
          decode.success(#(content, expected))
        }),
      )
      |> result.replace_error(p.Invalid("invalid persona_write arguments")),
    )
    ledger.write_document(
      context.store,
      context.session,
      p.OwnerAgent(context.call_id),
      args.0,
      args.1,
    )
    |> result.map(ledger.receipt_json)
  })
}

fn edit(
  context: extension.Context,
  arguments: String,
) -> Result(extension.Output, extension.Failure) {
  answer({
    use _ <- result.try(case string.byte_size(arguments) <= domain.body_limit {
      True -> Ok(Nil)
      False -> Error(p.Invalid("edit request too large"))
    })
    use args <- result.try(
      json.parse(
        arguments,
        api.object(["old_string", "new_string", "replace_all"], {
          use old <- decode.field("old_string", decode.string)
          use new <- decode.field("new_string", decode.string)
          use all <- decode.optional_field("replace_all", False, decode.bool)
          decode.success(#(old, new, all))
        }),
      )
      |> result.replace_error(p.Invalid("invalid persona_edit arguments")),
    )
    ledger.edit_document(
      context.store,
      context.session,
      p.OwnerAgent(context.call_id),
      args.0,
      args.1,
      args.2,
    )
    |> result.map(ledger.receipt_json)
  })
}

fn recover(context: extension.Context) -> option.Option(extension.Output) {
  ledger.recover(context.store, context.session, context.call_id)
  |> result.unwrap(None)
  |> option.map(extension.text)
}
