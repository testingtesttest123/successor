//// Host-owned source actors from retained submission/mail metadata.
//// Caller prose never supplies identity; legacy user rows remain unknown.

import albedo/daemon/operations
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/protect
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Error {
  Storage(String)
  Unavailable(String)
}

pub type Row {
  Row(
    seq: Int,
    input: types.Input,
    display: Option(operations.Display),
    operation_id: Option(String),
  )
}

/// Shared by exact personality source validation and native LCM evidence.
pub fn actors_in(
  db: sqlight.Connection,
  session: String,
  rows: List(Row),
) -> Result(List(#(Int, String)), Error) {
  let mail_ids =
    list.filter_map(rows, fn(row) {
      case row.display, row.operation_id {
        Some(display), Some("host-note:" <> _) if display.operation_id == None ->
          Error(Nil)
        Some(display), Some(id)
          if display.source == "mail" || display.source == "webhook"
        -> Ok(id)
        _, _ -> Error(Nil)
      }
    })
  use retained <- result.try(case mail_ids {
    [] -> Ok([])
    _ ->
      store.rows(
        db,
        "SELECT seq,operation_id,CASE WHEN length(CAST(reporter AS BLOB))<=512 THEN reporter ELSE NULL END FROM submission_events WHERE session=? AND reporter IS NOT NULL AND operation_id IN ("
          <> string.join(list.map(mail_ids, fn(_) { "?" }), ",")
          <> ")",
        [sqlight.text(session), ..list.map(mail_ids, sqlight.text)],
        {
          use seq <- decode.field(0, decode.int)
          use id <- decode.field(1, decode.string)
          use reporter <- decode.field(2, decode.optional(decode.string))
          decode.success(#(seq, id, reporter))
        },
      )
      |> result.map_error(Storage)
  })
  let legacy_ids =
    list.filter(mail_ids, fn(id) {
      !list.any(retained, fn(record) { record.1 == id })
    })
  use senders <- result.try(case legacy_ids {
    [] -> Ok([])
    _ ->
      store.rows(
        db,
        // Host-owned submission_events retain a globally unique immutable mail
        // ID, including after native forks. Its original recipient need not be
        // this branch. Read only reporter metadata, never another inbox/body;
        // actual mail delivery/access retains its recipient checks.
        "SELECT id,sender,CASE WHEN length(CAST(reporter AS BLOB))<=512 THEN reporter ELSE NULL END,kind,reporter IS NOT NULL FROM mail WHERE id IN ("
          <> string.join(list.map(legacy_ids, fn(_) { "?" }), ",")
          <> ")",
        list.map(legacy_ids, sqlight.text),
        {
          use id <- decode.field(0, decode.string)
          use sender <- decode.field(1, decode.optional(decode.string))
          use reporter <- decode.field(2, decode.optional(decode.string))
          use kind <- decode.field(3, decode.string)
          use retained <- decode.field(4, sqlight.decode_bool())
          decode.success(#(id, sender, reporter, kind, retained))
        },
      )
      |> result.map_error(Storage)
  })
  list.try_map(rows, fn(row) {
    use actor <- result.try(case row.display {
      None ->
        Ok(case row.input {
          types.User(_) | types.UserImage(_, _) -> "unknown_origin"
          _ -> actor(row.input)
        })
      Some(display) ->
        case display.operation_id, row.operation_id {
          None, Some("host-note:" <> _) -> note_actor(display.source)
          _, _ ->
            case display.source {
              "chat" -> Ok(actor(row.input))
              "mail" | "webhook" ->
                case
                  list.find(retained, fn(record) {
                    record.0 == row.seq && Some(record.1) == row.operation_id
                  })
                {
                  Ok(#(_, _, reporter)) -> retained_reporter(reporter)
                  Error(_) -> legacy_reporter(row.operation_id, senders)
                }
              source -> note_actor(source)
            }
        }
    })
    Ok(#(row.seq, actor))
  })
}

fn retained_reporter(value: Option(String)) -> Result(String, Error) {
  case value {
    Some(label) ->
      case
        {
          string.starts_with(label, "agent_report:")
          || string.starts_with(label, "external_report:")
        }
        && list.any(
          ["task", "message", "result", "unreviewed", "webhook"],
          fn(kind) { string.ends_with(label, ":" <> kind) },
        )
      {
        True -> Ok(label)
        False -> Error(Unavailable("source reporter metadata unavailable"))
      }
    None -> Error(Unavailable("source reporter metadata unavailable"))
  }
}

fn legacy_reporter(
  id: Option(String),
  senders: List(#(String, Option(String), Option(String), String, Bool)),
) -> Result(String, Error) {
  case list.find(senders, fn(sender) { Some(sender.0) == id }) {
    Ok(#(_, _, reporter, _, True)) -> retained_reporter(reporter)
    Ok(#(_, Some(sender), _, kind, False)) ->
      Ok("agent_report:" <> sender <> ":" <> kind)
    _ -> Error(Unavailable("source reporter metadata unavailable"))
  }
}

fn note_actor(origin: String) -> Result(String, Error) {
  case string.byte_size(origin) <= 128 {
    True -> Ok("system_note:" <> origin)
    False ->
      Error(Unavailable(
        "source actor label exceeds its bounded metadata budget",
      ))
  }
}

fn actor(input: types.Input) -> String {
  case input {
    types.User(_) | types.UserImage(_, _) -> "user_assertion"
    types.Assistant(_) | types.Replay(_) -> "owner_agent"
    types.ToolOutput(_, _, _) -> "tool_report"
  }
}

/// Read bounded host metadata for the exact retained rows. Oversized or corrupt
/// metadata refuses classification; LCM may render unknown attribution instead.
pub fn sourced(
  ledger: store.Store,
  entries: List(transcript.SourcedEntry),
) -> Result(List(#(Int, String)), Error) {
  store.query(ledger, fn(db) {
    use groups <- result.try(
      list.try_map(list.sized_chunk(entries, 256), fn(chunk) {
        case chunk {
          [] -> Ok([])
          [first, ..] -> {
            use metadata <- result.try(
              store.rows(
                db,
                "SELECT seq,(SELECT operation_id FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),(SELECT CASE WHEN length(payload)<=8192 THEN payload ELSE NULL END FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1) FROM transcript WHERE session=? AND seq IN ("
                  <> string.join(list.map(chunk, fn(_) { "?" }), ",")
                  <> ")",
                [
                  sqlight.text(first.source.session),
                  ..list.map(chunk, fn(row) { sqlight.int(row.source.seq) })
                ],
                {
                  use seq <- decode.field(0, decode.int)
                  use id <- decode.field(1, decode.optional(decode.string))
                  use payload <- decode.field(
                    2,
                    decode.optional(decode.bit_array),
                  )
                  decode.success(#(seq, id, payload))
                },
              )
              |> result.map_error(Storage),
            )
            use rows <- result.try(
              list.try_map(chunk, fn(entry) {
                case
                  list.find(metadata, fn(row) { row.0 == entry.source.seq })
                {
                  Error(_) ->
                    Error(Unavailable("retained source row unavailable"))
                  Ok(#(_, id, Some(payload))) -> {
                    use display <- result.try(
                      protect.attempt(fn() {
                        operations.decode_display(payload)
                      })
                      |> result.replace_error(Unavailable(
                        "source submission metadata cannot be decoded",
                      )),
                    )
                    Ok(Row(
                      entry.source.seq,
                      entry.entry.input,
                      Some(display),
                      id,
                    ))
                  }
                  Ok(#(_, None, None)) ->
                    Ok(Row(entry.source.seq, entry.entry.input, None, None))
                  _ ->
                    Error(Unavailable(
                      "source submission metadata exceeds bounded classification budget",
                    ))
                }
              }),
            )
            actors_in(db, first.source.session, rows)
          }
        }
      }),
    )
    Ok(list.flatten(groups))
  })
}
