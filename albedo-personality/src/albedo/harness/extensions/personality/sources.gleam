//// Exact, bounded transcript evidence. Stored digests are not retained text.
//// Neither caller-provided provenance nor actor strings confer authority.

import albedo/daemon/http_api as api
import albedo/daemon/operations
import albedo/daemon/store
import albedo/harness/extensions/personality/types as p
import albedo/harness/protect
import albedo/openai_api/types
import albedo/text_scalars
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight

pub fn hash(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn decoder() -> decode.Decoder(p.SourceRef) {
  api.object(["source_id", "first_seq", "last_seq", "digest", "lcm_hint"], {
    use id <- decode.optional_field("source_id", "", decode.string)
    use first <- decode.optional_field("first_seq", 0, decode.int)
    use last <- decode.optional_field("last_seq", 0, decode.int)
    use digest <- decode.optional_field("digest", "", decode.string)
    use hint <- decode.optional_field(
      "lcm_hint",
      None,
      decode.optional(decode.string),
    )
    decode.success(p.SourceRef(
      id,
      "",
      first,
      last,
      digest,
      [],
      "",
      0,
      0,
      hint,
      "",
    ))
  })
}

pub fn json(source: p.SourceRef) -> json.Json {
  json.object([
    #("id", json.string(source.id)),
    #("availability", json.string(source.availability)),
    #("session", json.string(source.session)),
    #("first_seq", json.int(source.first_seq)),
    #("last_seq", json.int(source.last_seq)),
    #("digest", json.string(source.digest)),
    #("actors", json.array(source.actors, json.string)),
    #("origin", json.string(source.origin)),
    #("binding_revision", json.int(source.binding_revision)),
    #("pre_binding_through", json.int(source.pre_binding_through)),
    #("lcm_hint", json.nullable(source.lcm_hint, json.string)),
  ])
}

pub fn input_json(source: p.SourceRef) -> json.Json {
  json.object([
    #("source_id", json.string(source.id)),
    #("first_seq", json.int(source.first_seq)),
    #("last_seq", json.int(source.last_seq)),
    #("digest", json.string(source.digest)),
    #("lcm_hint", json.nullable(source.lcm_hint, json.string)),
  ])
}

pub fn stored_decoder() -> decode.Decoder(p.SourceRef) {
  use id <- decode.field(0, decode.string)
  use session <- decode.field(1, decode.string)
  use first <- decode.field(2, decode.int)
  use last <- decode.field(3, decode.int)
  use digest <- decode.field(4, decode.string)
  use actors <- decode.field(5, decode.string)
  use origin <- decode.field(6, decode.string)
  use revision <- decode.field(7, decode.int)
  use boundary <- decode.field(8, decode.int)
  use hint <- decode.field(9, decode.optional(decode.string))
  use availability <- decode.field(10, decode.string)
  case json.parse(actors, decode.list(decode.string)) {
    Ok(actors) ->
      decode.success(p.SourceRef(
        id,
        session,
        first,
        last,
        digest,
        actors,
        origin,
        revision,
        boundary,
        hint,
        availability,
      ))
    Error(_) ->
      decode.failure(
        p.SourceRef("", "", 0, 0, "", [], "", 0, 0, None, ""),
        "source actors",
      )
  }
}

/// Shared read authority. No caller may choose a persona or foreign session.
pub fn binding_in(
  db: sqlight.Connection,
  session: String,
) -> Result(p.Binding, p.DomainError) {
  store.one(
    db,
    "SELECT s.session,s.persona_id,s.mode,s.binding_revision,s.pre_binding_through FROM personality_session s JOIN personality_persona p ON p.id=s.persona_id WHERE s.session=? AND s.mode='owner' AND s.authority='user' AND p.state='active' AND NOT EXISTS(SELECT 1 FROM session_family f WHERE f.session=s.session)",
    [sqlight.text(session)],
    {
      use session <- decode.field(0, decode.string)
      use persona <- decode.field(1, decode.string)
      use mode <- decode.field(2, decode.string)
      use revision <- decode.field(3, decode.int)
      use boundary <- decode.field(4, decode.int)
      decode.success(p.Binding(session, persona, mode, revision, boundary))
    },
    "active owner binding required",
  )
  |> result.map_error(fn(error) {
    case error {
      "active owner binding required" -> p.Forbidden(error)
      _ -> p.Storage(error)
    }
  })
}

pub fn find_in(
  db: sqlight.Connection,
  persona: String,
  id: String,
) -> Result(p.SourceRef, p.DomainError) {
  store.one(
    db,
    "SELECT id,session,first_seq,last_seq,digest,actors,origin,binding_revision,pre_binding_through,lcm_hint,availability FROM personality_source WHERE persona_id=? AND id=?",
    [sqlight.text(persona), sqlight.text(id)],
    stored_decoder(),
    "source_not_found",
  )
  |> result.map_error(fn(error) {
    case error {
      "source_not_found" -> p.NotFound
      _ -> p.Storage(error)
    }
  })
}

type Row {
  Row(seq: Int, payload: BitArray, input: types.Input, actor: String)
}

fn rows_in(
  db: sqlight.Connection,
  session: String,
  first: Int,
  last: Int,
) -> Result(List(Row), p.DomainError) {
  use _ <- result.try(case first > 0 && last >= first {
    True -> Ok(Nil)
    False -> Error(p.Invalid("invalid exact source range"))
  })
  use sizes <- result.try(
    store.rows(
      db,
      "SELECT seq,length(payload)+COALESCE((SELECT length(payload) FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),0) FROM transcript WHERE session=? AND seq>=? AND seq<=? ORDER BY seq LIMIT 257",
      [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
      {
        use seq <- decode.field(0, decode.int)
        use bytes <- decode.field(1, decode.int)
        decode.success(#(seq, bytes))
      },
    )
    |> result.map_error(p.Storage),
  )
  use _ <- result.try(case sizes {
    [] -> Error(p.SourceUnavailable("source rows unavailable"))
    [head, ..] -> {
      let tail = list.last(sizes) |> result.unwrap(head)
      case
        head.0 == first
        && tail.0 == last
        && list.length(sizes) <= 256
        && list.fold(sizes, 0, fn(total, row) { total + row.1 }) <= 262_144
      {
        True -> Ok(Nil)
        False ->
          Error(p.SourceUnavailable(
            "source boundaries unavailable or range exceeds 256 rows/256 KiB",
          ))
      }
    }
  })
  use rows <- result.try(
    store.rows(
      db,
      "SELECT seq,payload,(SELECT payload FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),(SELECT operation_id FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1) FROM transcript WHERE session=? AND seq>=? AND seq<=? ORDER BY seq LIMIT 256",
      [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
      {
        use seq <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.bit_array)
        use display <- decode.field(2, decode.optional(decode.bit_array))
        use input_id <- decode.field(3, decode.optional(decode.string))
        decode.success(#(seq, payload, display, input_id))
      },
    )
    |> result.map_error(p.Storage),
  )
  use decoded <- result.try(
    list.try_map(rows, fn(row) {
      use input <- result.try(
        unpack(row.1, fn(_) { Error(Nil) })
        |> result.replace_error(p.SourceUnavailable(
          "source row cannot be decoded",
        )),
      )
      use display <- result.try(case row.2 {
        None -> Ok(None)
        Some(payload) ->
          protect.attempt(fn() { operations.decode_display(payload) })
          |> result.map(Some)
          |> result.replace_error(p.SourceUnavailable(
            "source submission metadata cannot be decoded",
          ))
      })
      Ok(#(row.0, row.1, input, display, row.3))
    }),
  )
  let mail_ids =
    list.filter_map(decoded, fn(row) {
      case row.3, row.4 {
        Some(display), Some(id)
          if display.source == "mail" || display.source == "webhook"
        -> Ok(id)
        _, _ -> Error(Nil)
      }
    })
  use senders <- result.try(case mail_ids {
    [] -> Ok([])
    _ ->
      store.rows(
        db,
        "SELECT id,sender,CASE WHEN length(CAST(sender_name AS BLOB))<=128 THEN sender_name ELSE NULL END,kind FROM mail WHERE recipient=? AND id IN ("
          <> string.join(list.map(mail_ids, fn(_) { "?" }), ",")
          <> ")",
        [sqlight.text(session), ..list.map(mail_ids, sqlight.text)],
        {
          use id <- decode.field(0, decode.string)
          use sender <- decode.field(1, decode.optional(decode.string))
          use name <- decode.field(2, decode.optional(decode.string))
          use kind <- decode.field(3, decode.string)
          decode.success(#(id, sender, name, kind))
        },
      )
      |> result.map_error(p.Storage)
  })
  list.try_map(decoded, fn(row) {
    use actor <- result.try(case row.3 {
      None ->
        Ok(case row.2 {
          types.User(_) | types.UserImage(_, _) -> "unknown_origin"
          _ -> actor(row.2)
        })
      Some(display) ->
        case display.operation_id, row.4 {
          None, Some("host-note:" <> _) -> note_actor(display.source)
          _, _ ->
            case display.source {
              "chat" -> Ok(actor(row.2))
              "mail" | "webhook" ->
                case
                  list.find(senders, fn(sender) { Some(sender.0) == row.4 })
                {
                  Ok(#(_, Some(sender), _, kind)) ->
                    Ok("agent_report:" <> sender <> ":" <> kind)
                  Ok(#(_, None, Some(name), kind)) ->
                    Ok("external_report:" <> name <> ":" <> kind)
                  _ ->
                    Error(p.SourceUnavailable(
                      "source reporter metadata unavailable",
                    ))
                }
              source -> note_actor(source)
            }
        }
    })
    Ok(Row(row.0, row.1, row.2, actor))
  })
}

fn note_actor(origin: String) -> Result(String, p.DomainError) {
  case string.byte_size(origin) <= 128 {
    True -> Ok("system_note:" <> origin)
    False ->
      Error(p.SourceUnavailable(
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

fn digest(rows: List(Row)) -> String {
  rows
  |> json.array(fn(row) {
    json.array(
      [
        json.int(row.seq),
        json.string(bit_array.base16_encode(row.payload) |> string.lowercase),
        json.string(row.actor),
      ],
      fn(value) { value },
    )
  })
  |> json.to_string
  |> hash
}

fn resolve_one_in(
  db: sqlight.Connection,
  binding: p.Binding,
  ref: p.SourceRef,
  read: fn(String, Int, Int) -> Result(#(String, List(String)), p.DomainError),
) -> Result(p.SourceRef, p.DomainError) {
  use _ <- result.try(
    case
      string.byte_size(ref.id) <= 128
      && string.byte_size(ref.digest) <= 64
      && option.unwrap(ref.lcm_hint, "") |> string.byte_size <= 128
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("invalid source identifier or hint"))
    },
  )
  case ref.id {
    "" -> {
      use _ <- result.try(
        case ref.session == "" && ref.actors == [] && ref.origin == "" {
          True -> Ok(Nil)
          False -> Error(p.Invalid("source attribution is host-owned"))
        },
      )
      use _ <- result.try(
        case
          ref.first_seq <= binding.pre_binding_through
          && ref.last_seq > binding.pre_binding_through
        {
          True ->
            Error(p.Invalid("split evidence at the disclosed binding boundary"))
          False -> Ok(Nil)
        },
      )
      use metadata <- result.try(read(
        binding.session,
        ref.first_seq,
        ref.last_seq,
      ))
      let #(digest, actors) = metadata
      use _ <- result.try(case ref.digest == "" || ref.digest == digest {
        True -> Ok(Nil)
        False -> Error(p.SourceUnavailable("source digest mismatch"))
      })
      let origin = case ref.last_seq <= binding.pre_binding_through {
        True -> "imported"
        False ->
          case
            list.any(actors, fn(actor) {
              string.starts_with(actor, "system_note:")
              || actor == "unknown_origin"
            })
          {
            True -> "imported"
            False ->
              case
                list.any(actors, fn(actor) {
                  string.starts_with(actor, "agent_report:")
                  || string.starts_with(actor, "external_report:")
                  || actor == "tool_report"
                })
              {
                True -> "reported"
                False -> "experienced"
              }
          }
      }
      let id =
        hash(
          json.to_string(json.array(
            [
              binding.persona_id,
              binding.session,
              int.to_string(ref.first_seq),
              int.to_string(ref.last_seq),
              digest,
              origin,
              int.to_string(binding.revision),
            ],
            json.string,
          )),
        )
      Ok(p.SourceRef(
        id,
        binding.session,
        ref.first_seq,
        ref.last_seq,
        digest,
        actors,
        origin,
        binding.revision,
        binding.pre_binding_through,
        ref.lcm_hint,
        "available",
      ))
    }
    _ -> {
      use _ <- result.try(
        case
          ref.first_seq == 0
          && ref.last_seq == 0
          && ref.session == ""
          && ref.actors == []
          && ref.origin == ""
          && ref.lcm_hint == None
        {
          True -> Ok(Nil)
          False ->
            Error(p.Invalid(
              "source ID cannot override its exact range or attribution",
            ))
        },
      )
      use saved <- result.try(find_in(db, binding.persona_id, ref.id))
      use metadata <- result.try(read(
        saved.session,
        saved.first_seq,
        saved.last_seq,
      ))
      use _ <- result.try(
        case saved.availability == "available" && metadata.0 == saved.digest {
          True -> Ok(Nil)
          False ->
            Error(p.SourceUnavailable("source digest or availability changed"))
        },
      )
      case ref.digest == "" || ref.digest == saved.digest {
        True -> Ok(saved)
        False -> Error(p.SourceUnavailable("source digest mismatch"))
      }
    }
  }
}

pub fn resolve_in(
  db: sqlight.Connection,
  binding: p.Binding,
  refs: List(p.SourceRef),
) -> Result(List(p.SourceRef), p.DomainError) {
  use _ <- result.try(case list.length(refs) <= 512 {
    True -> Ok(Nil)
    False -> Error(p.Invalid("too many evidence references"))
  })
  // Metadata-only bounded preflight keeps the whole operation, including many
  // small links, within one read budget before any packed body is materialized.
  use ranges <- result.try(
    list.try_map(refs, fn(ref) {
      case ref.id {
        "" -> Ok(#(binding.session, ref.first_seq, ref.last_seq))
        _ ->
          find_in(db, binding.persona_id, ref.id)
          |> result.map(fn(source) {
            #(source.session, source.first_seq, source.last_seq)
          })
      }
    }),
  )
  use sizes <- result.try(
    list.try_map(list.unique(ranges), fn(range) {
      store.one(
        db,
        "SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM (SELECT length(payload)+COALESCE((SELECT length(payload) FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),0) AS bytes FROM transcript WHERE session=? AND seq>=? AND seq<=? ORDER BY seq LIMIT 257)",
        [sqlight.text(range.0), sqlight.int(range.1), sqlight.int(range.2)],
        {
          use count <- decode.field(0, decode.int)
          use bytes <- decode.field(1, decode.int)
          decode.success(#(count, bytes))
        },
        "source sizes unavailable",
      )
      |> result.map_error(p.Storage)
    }),
  )
  use _ <- result.try(
    case
      list.fold(sizes, 0, fn(total, size) { total + size.0 }) <= 256
      && list.fold(sizes, 0, fn(total, size) { total + size.1 }) <= 262_144
    {
      True -> Ok(Nil)
      False ->
        Error(p.Invalid(
          "mutation evidence exceeds total 256 rows/256 KiB validation budget",
        ))
    },
  )
  use metadata <- result.try(
    list.try_map(list.unique(ranges), fn(range) {
      use rows <- result.try(rows_in(db, range.0, range.1, range.2))
      let actors = list.unique(list.map(rows, fn(row) { row.actor }))
      use _ <- result.try(
        case
          json.to_string(json.array(actors, json.string)) |> string.byte_size
          <= 1024
        {
          True -> Ok(Nil)
          False ->
            Error(p.Invalid(
              "source actor attribution exceeds 1 KiB; use narrower exact ranges",
            ))
        },
      )
      Ok(#(range, #(digest(rows), actors)))
    }),
  )
  list.try_map(
    refs,
    resolve_one_in(db, binding, _, fn(session, first, last) {
      list.key_find(metadata, #(session, first, last))
      |> result.replace_error(p.Storage("validated source metadata missing"))
    }),
  )
}

pub fn resolve(
  db: store.Store,
  binding: p.Binding,
  refs: List(p.SourceRef),
) -> Result(List(p.SourceRef), p.DomainError) {
  store.query(db, fn(connection) {
    use current <- result.try(binding_in(connection, binding.session))
    case current == binding {
      True -> resolve_in(connection, binding, refs)
      False -> Error(p.Conflict("binding changed during source validation"))
    }
  })
}

pub fn check_in(
  db: sqlight.Connection,
  source: p.SourceRef,
) -> Result(Nil, p.DomainError) {
  use _ <- result.try(case source.availability {
    "available" -> Ok(Nil)
    _ ->
      Error(p.SourceUnavailable(
        "source session deleted; exact evidence unavailable",
      ))
  })
  use rows <- result.try(rows_in(
    db,
    source.session,
    source.first_seq,
    source.last_seq,
  ))
  case digest(rows) == source.digest {
    True -> Ok(Nil)
    False ->
      Error(p.SourceUnavailable(
        "source digest mismatch; rows may have moved or changed",
      ))
  }
}

pub fn persist_in(
  db: sqlight.Connection,
  persona: String,
  source: p.SourceRef,
) -> Result(Nil, p.DomainError) {
  store.run(
    db,
    "INSERT INTO personality_source(id,persona_id,session,first_seq,last_seq,digest,actors,origin,binding_revision,pre_binding_through,lcm_hint) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
    [
      sqlight.text(source.id),
      sqlight.text(persona),
      sqlight.text(source.session),
      sqlight.int(source.first_seq),
      sqlight.int(source.last_seq),
      sqlight.text(source.digest),
      sqlight.text(json.to_string(json.array(source.actors, json.string))),
      sqlight.text(source.origin),
      sqlight.int(source.binding_revision),
      sqlight.int(source.pre_binding_through),
      sqlight.nullable(sqlight.text, source.lcm_hint),
    ],
  )
  |> result.map_error(p.Storage)
}

fn row_text(row: Row) -> String {
  let text = case row.input {
    types.User(text) | types.UserImage(text, _) | types.Assistant(text) -> text
    types.ToolOutput(_, text, _) -> text
    types.Replay(item) -> types.replay_json(item) |> json.to_string
  }
  "[seq " <> int.to_string(row.seq) <> "; " <> row.actor <> "]\n" <> text
}

pub fn page_json(page: p.SourcePage) -> json.Json {
  json.object([
    #("text", json.string(page.text)),
    #("source", json(page.source)),
    #("next_cursor", json.nullable(page.next, json.string)),
    #("bytes", json.int(page.bytes)),
  ])
}

pub fn expand(
  db: store.Store,
  session: String,
  source_id: String,
  cursor: option.Option(String),
) -> Result(p.SourcePage, p.DomainError) {
  use _ <- result.try(
    case
      string.byte_size(source_id) <= 128
      && string.byte_size(option.unwrap(cursor, "")) <= 2048
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("source ID or cursor exceeds its limit"))
    },
  )
  use captured <- result.try(
    store.query(db, fn(connection) {
      use binding <- result.try(binding_in(connection, session))
      use source <- result.try(find_in(
        connection,
        binding.persona_id,
        source_id,
      ))
      use _ <- result.try(case source.availability {
        "available" -> Ok(Nil)
        _ ->
          Error(p.SourceUnavailable(
            "source session deleted; exact evidence unavailable",
          ))
      })
      use rows <- result.try(rows_in(
        connection,
        source.session,
        source.first_seq,
        source.last_seq,
      ))
      case digest(rows) == source.digest {
        True -> Ok(#(source, rows))
        False ->
          Error(p.SourceUnavailable(
            "source digest mismatch; exact evidence unavailable",
          ))
      }
    }),
  )
  let #(source, rows) = captured
  use offset <- result.try(case cursor {
    None -> Ok(0)
    Some(cursor) -> {
      use parts <- result.try(
        json.parse(cursor, decode.list(decode.string))
        |> result.replace_error(p.Invalid("invalid source cursor")),
      )
      case parts {
        [id, digest, offset] if id == source.id && digest == source.digest ->
          int.parse(offset)
          |> result.replace_error(p.Invalid("invalid source offset"))
        _ -> Error(p.Invalid("source cursor belongs to another source"))
      }
    }
  })
  let text = list.map(rows, row_text) |> string.join("\n\n")
  use _ <- result.try(case offset >= 0 && offset <= text_scalars.length(text) {
    True -> Ok(Nil)
    False -> Error(p.Invalid("source cursor outside exact range"))
  })
  let rest = text_scalars.drop(text, offset)
  let chunk = text_scalars.take(rest, 768)
  let next = case text_scalars.length(rest) > 768 {
    True ->
      Some(
        json.to_string(json.array(
          [source.id, source.digest, int.to_string(offset + 768)],
          json.string,
        )),
      )
    False -> None
  }
  let page = p.SourcePage(chunk, source, next, 0)
  let bytes = page_json(page) |> json.to_string |> string.byte_size
  let page =
    p.SourcePage(
      ..page,
      bytes: bytes + string.byte_size(int.to_string(bytes)) - 1,
    )
  case page_json(page) |> json.to_string |> string.byte_size <= 8192 {
    True -> Ok(page)
    False -> Error(p.Invalid("source page exceeds 8 KiB rendered bytes"))
  }
}

@external(erlang, "albedo_conversation", "unpack")
fn unpack(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)
