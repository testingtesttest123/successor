//// Immutable formation facts, independent of graph, strategy and personality.
//// Source text and generated prose never supply trusted narrator metadata.

import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Perspective {
  Experienced
  Witnessed
  Reading
  Mixed
  Unknown
}

pub type Narrator {
  Narrator(subject: String, name: String, revision: Int)
}

pub type Boundary {
  Boundary(
    session: String,
    seq: Int,
    origin_session: String,
    origin_seq: Int,
    perspective: Perspective,
    actor: String,
    role: String,
  )
}

pub type Child {
  Child(
    session: String,
    id: Int,
    first_seq: Int,
    last_seq: Int,
    narrator: Option(Narrator),
    perspective: Perspective,
  )
}

pub type Frame {
  Frame(
    narrator: Option(Narrator),
    perspective: Perspective,
    sources: List(Boundary),
    children: List(Child),
  )
}

/// Text offsets count UTF-8 bytes and always end at whole codepoints.
pub type Portion {
  Portion(session: String, seq: Int, start: Int, end: Int, total: Int)
}

pub type Recall {
  Recall(cue: String, text: String)
}

pub type Formation {
  Formation(
    frame: Frame,
    mode: String,
    portions: List(Portion),
    previous: Option(Recall),
    budget: Int,
    source_only: Bool,
  )
}

pub fn perspective(value: Perspective) -> String {
  case value {
    Experienced -> "experienced"
    Witnessed -> "witnessed"
    Reading -> "reading"
    Mixed -> "mixed"
    Unknown -> "unknown"
  }
}

fn perspective_decoder() -> decode.Decoder(Perspective) {
  use value <- decode.then(decode.string)
  case value {
    "experienced" -> decode.success(Experienced)
    "witnessed" -> decode.success(Witnessed)
    "reading" -> decode.success(Reading)
    "mixed" -> decode.success(Mixed)
    "unknown" -> decode.success(Unknown)
    _ -> decode.failure(Unknown, "narration perspective")
  }
}

pub fn combine(values: List(Perspective)) -> Perspective {
  case list.unique(values) {
    [value] -> value
    [] -> Unknown
    _ -> Mixed
  }
}

fn narrator_json(value: Narrator) -> json.Json {
  json.object([
    #("subject", json.string(value.subject)),
    #("name", json.string(value.name)),
    #("revision", json.int(value.revision)),
  ])
}

fn narrator_decoder() -> decode.Decoder(Narrator) {
  use subject <- decode.field("subject", decode.string)
  use name <- decode.field("name", decode.string)
  use revision <- decode.field("revision", decode.int)
  decode.success(Narrator(subject, name, revision))
}

pub fn child_json(value: Child) -> json.Json {
  json.object([
    #("session", json.string(value.session)),
    #("id", json.int(value.id)),
    #("first_seq", json.int(value.first_seq)),
    #("last_seq", json.int(value.last_seq)),
    #(
      "narrator",
      option.map(value.narrator, narrator_json) |> option.unwrap(json.null()),
    ),
    #("perspective", json.string(perspective(value.perspective))),
  ])
}

fn child_decoder() -> decode.Decoder(Child) {
  use session <- decode.field("session", decode.string)
  use id <- decode.field("id", decode.int)
  use first <- decode.field("first_seq", decode.int)
  use last <- decode.field("last_seq", decode.int)
  use narrator <- decode.field("narrator", decode.optional(narrator_decoder()))
  use perspective <- decode.field("perspective", perspective_decoder())
  decode.success(Child(session, id, first, last, narrator, perspective))
}

pub fn frame_json(value: Frame) -> json.Json {
  json.object([
    #(
      "narrator",
      option.map(value.narrator, narrator_json) |> option.unwrap(json.null()),
    ),
    #("perspective", json.string(perspective(value.perspective))),
    #(
      "sources",
      json.array(value.sources, fn(source) {
        json.object([
          #("session", json.string(source.session)),
          #("seq", json.int(source.seq)),
          #("origin_session", json.string(source.origin_session)),
          #("origin_seq", json.int(source.origin_seq)),
          #("perspective", json.string(perspective(source.perspective))),
          #("actor", json.string(source.actor)),
          #("role", json.string(source.role)),
        ])
      }),
    ),
    #("children", json.array(value.children, child_json)),
  ])
}

/// Model-facing header; the durable source and child arrays are paged separately.
pub fn header_json(value: Frame) -> json.Json {
  json.object([
    #(
      "narrator",
      option.map(value.narrator, narrator_json) |> option.unwrap(json.null()),
    ),
    #("perspective", json.string(perspective(value.perspective))),
    #("source_count", json.int(list.length(value.sources))),
    #("child_count", json.int(list.length(value.children))),
    #("detail", json.string("paged by lcm_describe metadata_content")),
  ])
}

pub fn optional_json(value: Option(Frame)) -> json.Json {
  option.map(value, frame_json) |> option.unwrap(json.null())
}

fn boundary_decoder() -> decode.Decoder(Boundary) {
  use session <- decode.field("session", decode.string)
  use seq <- decode.field("seq", decode.int)
  use original <- decode.field("origin_session", decode.string)
  use original_seq <- decode.field("origin_seq", decode.int)
  use perspective <- decode.field("perspective", perspective_decoder())
  use actor <- decode.field("actor", decode.string)
  use role <- decode.field("role", decode.string)
  decode.success(Boundary(
    session,
    seq,
    original,
    original_seq,
    perspective,
    actor,
    role,
  ))
}

pub fn decoder() -> decode.Decoder(Frame) {
  use narrator <- decode.field("narrator", decode.optional(narrator_decoder()))
  use perspective <- decode.field("perspective", perspective_decoder())
  use sources <- decode.field("sources", decode.list(boundary_decoder()))
  use children <- decode.field("children", decode.list(child_decoder()))
  decode.success(Frame(narrator, perspective, sources, children))
}

pub fn stored_decoder() -> decode.Decoder(Option(Frame)) {
  use value <- decode.then(decode.optional(decode.string))
  case value {
    None -> decode.success(None)
    Some(text) ->
      case json.parse(text, decoder()) {
        Ok(frame) -> decode.success(Some(frame))
        Error(_) -> decode.failure(None, "valid stored narration")
      }
  }
}

pub fn portion_json(value: Portion) -> json.Json {
  json.object([
    #("session", json.string(value.session)),
    #("seq", json.int(value.seq)),
    #("start_byte", json.int(value.start)),
    #("end_byte", json.int(value.end)),
    #("total_bytes", json.int(value.total)),
  ])
}

// Compact only complete adjacent *actual* source rows. Sequence gaps can belong
// to another session; frame position, not arithmetic adjacency, proves coverage.
// Partial byte ranges stay explicit. The immutable formation keeps all portions.
type Coverage {
  Coverage(first: Portion, last: Portion, rows: Int)
}

fn coverage(frame: Frame, portions: List(Portion)) -> List(Coverage) {
  let positions =
    list.index_map(frame.sources, fn(source, index) {
      #(#(source.session, source.seq), index)
    })
    |> dict.from_list
  list.fold(portions, [], fn(acc: List(Coverage), portion) {
    case acc {
      [last, ..rest] -> {
        let consecutive = case
          dict.get(positions, #(last.last.session, last.last.seq)),
          dict.get(positions, #(portion.session, portion.seq))
        {
          Ok(before), Ok(after) -> after == before + 1
          _, _ -> False
        }
        case
          consecutive
          && last.last.session == portion.session
          && last.last.start == 0
          && last.last.end == last.last.total
          && portion.start == 0
          && portion.end == portion.total
        {
          True -> [Coverage(..last, last: portion, rows: last.rows + 1), ..rest]
          False -> [Coverage(portion, portion, 1), ..acc]
        }
      }
      [] -> [Coverage(portion, portion, 1)]
    }
  })
  |> list.reverse
}

pub fn coverage_ranges(
  frame: Frame,
  portions: List(Portion),
) -> List(#(Int, Int)) {
  coverage(frame, portions)
  |> list.map(fn(span) { #(span.first.seq, span.last.seq) })
}

pub fn coverage_json(frame: Frame, portions: List(Portion)) -> json.Json {
  json.array(coverage(frame, portions), fn(span) {
    case span.first.start == 0 && span.last.end == span.last.total {
      True ->
        json.object([
          #("coverage", json.string("complete_source_rows")),
          #("session", json.string(span.first.session)),
          #("first_seq", json.int(span.first.seq)),
          #("last_seq", json.int(span.last.seq)),
          #("row_count", json.int(span.rows)),
        ])
      False -> portion_json(span.first)
    }
  })
}

pub fn recall_cue(
  session: String,
  id: Int,
  first_seq: Int,
  last_seq: Int,
  frame: Option(Frame),
) -> String {
  let narrator = case frame {
    Some(Frame(Some(who), view, _, _)) ->
      who.name
      <> " ("
      <> who.subject
      <> ", identity revision "
      <> int.to_string(who.revision)
      <> "; "
      <> perspective(view)
      <> ")"
    _ -> "unknown narrator"
  }
  "[memory recall; narrator "
  <> narrator
  <> "; session "
  <> session
  <> "; node #"
  <> int.to_string(id)
  <> "; source rows "
  <> int.to_string(first_seq)
  <> ".."
  <> int.to_string(last_seq)
  <> "; generated fallible memory. Current-session details: lcm_describe/lcm_expand; other-session details: agents.messages/search_messages only when available.]"
}

pub fn recall_inputs(
  session: String,
  id: Int,
  first_seq: Int,
  last_seq: Int,
  summary: String,
  frame: Option(Frame),
  current_subject: Option(String),
) -> List(types.Input) {
  case frame, current_subject {
    Some(Frame(Some(who), _, _, _)), Some(subject) if who.subject == subject -> [
      types.User(recall_cue(session, id, first_seq, last_seq, frame)),
      types.Assistant(summary),
    ]
    _, _ -> [
      types.User(
        recall_cue(session, id, first_seq, last_seq, frame)
        <> "\nAttributed historical evidence:\n"
        <> summary,
      ),
    ]
  }
}
