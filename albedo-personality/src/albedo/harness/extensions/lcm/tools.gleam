//// Bounded, read-only access to source-backed LCM nodes and transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/narration_types as narration
import albedo/harness/search
import albedo/harness/tool
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn definitions() -> List(extension.Tool) {
  [
    tool.text(
      "lcm_list",
      "List stored LCM folds in this session, including folds absent from the current request. Pages are bounded by node count and bytes. Narration is a header/count; use lcm_describe metadata pages for exact source/child facts.",
      False,
      [],
      [
        #("limit", "integer"),
        #("offset", "integer"),
      ],
      {
        use limit <- decode.optional_field("limit", 20, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        decode.success(#(limit, offset))
      },
      "expected optional limit and offset",
      fn(context, arguments) {
        let #(limit, offset) = arguments
        list_folds(context.store, context.session, limit, offset)
      },
    ),
    tool.text(
      "lcm_grep",
      "Find a case-insensitive literal term in this session's durable conversation and LCM summaries. Results are paged; source matches name their covering summary node.",
      False,
      ["pattern"],
      [
        #("pattern", "string"),
        #("limit", "integer"),
        #("offset", "integer"),
        #("summary_id", "integer"),
      ],
      {
        use pattern <- decode.field("pattern", decode.string)
        use limit <- decode.optional_field("limit", 10, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use summary_id <- decode.optional_field(
          "summary_id",
          None,
          decode.optional(decode.int),
        )
        decode.success(#(pattern, limit, offset, summary_id))
      },
      "expected pattern and optional limit, offset, summary_id",
      fn(context, arguments) {
        let #(pattern, limit, offset, summary_id) = arguments
        grep_page(
          context.store,
          context.session,
          pattern,
          limit,
          offset,
          summary_id,
        )
      },
    ),
    tool.text(
      "lcm_describe",
      "Inspect one LCM node. Narration is a bounded header; metadata_content pages exact source/child facts as serialized JSON. Concatenate pages using next_metadata_offset. Metadata and summary offsets/limits count UTF-8 bytes; limits are capped at 2048 bytes.",
      False,
      ["id"],
      [
        #("id", "integer"),
        #("metadata_offset", "integer"),
        #("metadata_limit", "integer"),
        #("summary_offset", "integer"),
        #("summary_limit", "integer"),
      ],
      {
        use id <- decode.field("id", decode.int)
        use metadata_offset <- decode.optional_field(
          "metadata_offset",
          0,
          decode.int,
        )
        use metadata_limit <- decode.optional_field(
          "metadata_limit",
          1024,
          decode.int,
        )
        use summary_offset <- decode.optional_field(
          "summary_offset",
          0,
          decode.int,
        )
        use summary_limit <- decode.optional_field(
          "summary_limit",
          2048,
          decode.int,
        )
        decode.success(#(
          id,
          metadata_offset,
          metadata_limit,
          summary_offset,
          summary_limit,
        ))
      },
      "expected id and optional metadata_offset, metadata_limit, summary_offset, summary_limit",
      fn(context, args) {
        describe(
          context.store,
          context.session,
          args.0,
          args.1,
          args.2,
          args.3,
          args.4,
        )
      },
    ),
    tool.text(
      "lcm_expand",
      "Read a bounded page of the original transcript rows covered by one LCM node. Use next_offset to continue; image payloads remain in the durable transcript.",
      False,
      ["id"],
      [
        #("id", "integer"),
        #("offset", "integer"),
        #("limit", "integer"),
      ],
      {
        use id <- decode.field("id", decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use limit <- decode.optional_field("limit", 4000, decode.int)
        decode.success(#(id, offset, limit))
      },
      "expected id, optional offset and limit",
      fn(context, arguments) {
        let #(id, offset, limit) = arguments
        expand(context.store, context.session, id, offset, limit)
      },
    ),
  ]
}

fn list_folds(
  ledger: store.Store,
  session: String,
  limit: Int,
  offset: Int,
) -> Result(String, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM list offset must be nonnegative",
  ))
  let limit = int.clamp(limit, 1, 20)
  use page <- result.try(graph.list_page(ledger, session, limit, offset))
  let entries = list_entries(page.nodes, 0, [])
  let next = offset + list.length(entries)
  json.object([
    #("total", json.int(page.total)),
    #("offset", json.int(offset)),
    #("next_offset", tool.next_offset(next, next < page.total)),
    #("folds", json.array(entries, fn(entry) { entry })),
  ])
  |> json.to_string
  |> Ok
}

fn grep_page(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
  offset: Int,
  summary_id: Option(Int),
) -> Result(String, String) {
  use needle <- result.try(search.needle(pattern))
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM search offset must be nonnegative",
  ))
  use scope <- result.try(case summary_id {
    Some(id) -> required_node(ledger, session, id) |> result.map(Some)
    None -> Ok(None)
  })
  let limit = int.clamp(limit, 1, 20)
  let #(first, last) = case scope {
    None -> #(0, 9_223_372_036_854_775_807)
    Some(node) -> #(node.first_seq, node.last_seq)
  }
  use sources <- result.try(search.page(
    ledger,
    session,
    needle,
    first,
    last,
    offset,
    limit,
  ))
  use summaries <- result.try(graph.search_page(
    ledger,
    session,
    scope,
    needle,
    limit,
    offset,
  ))
  use covering <- result.try(graph.covering_nodes(
    ledger,
    session,
    list.map(sources.matches, fn(match) { match.seq }),
  ))
  let next = offset + limit
  json.object([
    #("pattern", json.string(string.trim(pattern))),
    #("offset", json.int(offset)),
    #("source_count", json.int(sources.count)),
    #("node_count", json.int(summaries.count)),
    #(
      "next_offset",
      tool.next_offset(next, next < sources.count || next < summaries.count),
    ),
    #(
      "sources",
      json.array(sources.matches, fn(match) {
        json.object([
          #("seq", json.int(match.seq)),
          #("node_id", case dict.get(covering, match.seq) {
            Ok(id) -> json.int(id)
            Error(_) -> json.null()
          }),
          #("preview", json.string(search.preview(match.text, needle))),
        ])
      }),
    ),
    #(
      "nodes",
      json.array(summaries.nodes, fn(node) {
        json.object([
          #("id", json.int(node.id)),
          #("preview", json.string(search.preview(node.summary, needle))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

// The list has both a node cap and an encoded-byte cap; one source-heavy node
// cannot bypass paging. Large display fields remain recoverable via describe.
fn list_entries(
  nodes: List(#(graph.Node, Bool)),
  used: Int,
  acc: List(json.Json),
) -> List(json.Json) {
  case nodes {
    [] -> list.reverse(acc)
    [#(node, frontier), ..rest] -> {
      let entry =
        json.object([
          #("id", json.int(node.id)),
          #("depth", json.int(node.depth)),
          #("first_seq", json.int(node.first_seq)),
          #("last_seq", json.int(node.last_seq)),
          #("frontier", json.bool(frontier)),
          #("narration", narration_header(node.frame)),
          #("preview", json.string(byte_prefix(node.summary, 200))),
        ])
      let size = string.byte_size(json.to_string(entry)) + 1
      case used + size <= 12_000 {
        True -> list_entries(rest, used + size, [entry, ..acc])
        False -> list.reverse(acc)
      }
    }
  }
}

fn narration_header(frame: Option(narration.Frame)) -> json.Json {
  option.map(frame, narration.header_json) |> option.unwrap(json.null())
}

fn describe(
  ledger: store.Store,
  session: String,
  id: Int,
  metadata_offset: Int,
  metadata_limit: Int,
  summary_offset: Int,
  summary_limit: Int,
) -> Result(String, String) {
  use node <- result.try(required_node(ledger, session, id))
  use children <- result.try(graph.children(ledger, node.id))
  let metadata =
    json.object([
      #("narration", narration.optional_json(node.frame)),
      #("children", json.array(children, json.int)),
    ])
    |> json.to_string
  use #(detail, next_detail) <- result.try(byte_page(
    metadata,
    metadata_offset,
    metadata_limit,
  ))
  use #(summary, next_summary) <- result.try(byte_page(
    node.summary,
    summary_offset,
    summary_limit,
  ))
  json.object([
    #("id", json.int(node.id)),
    #("depth", json.int(node.depth)),
    #("first_seq", json.int(node.first_seq)),
    #("last_seq", json.int(node.last_seq)),
    #("children", json.array(list.take(children, 20), json.int)),
    #("children_count", json.int(list.length(children))),
    #("summary", json.string(summary)),
    #("summary_offset", json.int(summary_offset)),
    #(
      "next_summary_offset",
      option.map(next_summary, json.int) |> option.unwrap(json.null()),
    ),
    #("narration", narration_header(node.frame)),
    #("metadata_content", json.string(detail)),
    #("metadata_offset", json.int(metadata_offset)),
    #("metadata_total_bytes", json.int(string.byte_size(metadata))),
    #(
      "next_metadata_offset",
      option.map(next_detail, json.int) |> option.unwrap(json.null()),
    ),
  ])
  |> json.to_string
  |> Ok
}

fn byte_page(
  text: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, Option(Int)), String) {
  use _ <- result.try(compaction.require(
    offset >= 0 && offset <= string.byte_size(text) && limit > 0,
    "LCM byte offset or page limit outside bounds",
  ))
  let assert <<_:bytes-size(offset), rest:bytes>> = <<text:utf8>>
  use rest <- result.try(
    bit_array.to_string(rest)
    |> result.replace_error(
      "LCM byte offset must be a UTF-8 codepoint boundary",
    ),
  )
  let page = byte_prefix(rest, int.min(limit, 2048))
  use _ <- result.try(compaction.require(
    rest == "" || page != "",
    "LCM byte limit cannot fit the next UTF-8 codepoint",
  ))
  let next = offset + string.byte_size(page)
  Ok(
    #(page, case next < string.byte_size(text) {
      True -> Some(next)
      False -> None
    }),
  )
}

fn byte_prefix(text: String, limit: Int) -> String {
  let bytes = <<text:utf8>>
  let size = prefix_size(bytes, limit, 0)
  let assert <<page:bytes-size(size), _:bytes>> = bytes
  let assert Ok(page) = bit_array.to_string(page)
  page
}

fn prefix_size(bytes: BitArray, allowance: Int, used: Int) -> Int {
  case bytes {
    <<point:utf8_codepoint, rest:bytes>> -> {
      let size = bit_array.byte_size(<<point:utf8_codepoint>>)
      case size <= allowance {
        True -> prefix_size(rest, allowance - size, used + size)
        False -> used
      }
    }
    _ -> used
  }
}

fn expand(
  ledger: store.Store,
  session: String,
  id: Int,
  offset: Int,
  limit: Int,
) -> Result(String, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM expansion offset must be nonnegative",
  ))
  use node <- result.try(required_node(ledger, session, id))
  use snapshot <- result.try(conversation.snapshot(ledger, session))
  use #(page, next, more) <- result.try(tool.source_page(
    ledger,
    snapshot,
    node.first_seq,
    node.last_seq,
    "source",
    offset,
    limit,
  ))
  json.object([
    #("id", json.int(id)),
    #("offset", json.int(offset)),
    #("content", json.string(page)),
    #("next_offset", tool.next_offset(next, more)),
    #(
      "image_payloads",
      json.string("retained in transcript; text page shows metadata only"),
    ),
  ])
  |> json.to_string
  |> Ok
}

fn required_node(
  ledger: store.Store,
  session: String,
  id: Int,
) -> Result(graph.Node, String) {
  use found <- result.try(graph.node(ledger, session, id))
  option.to_result(
    found,
    "LCM node "
      <> int.to_string(id)
      <> " not found in this session; node ids come from lcm_list or lcm_grep"
      <> " nodes, and transcript row seqs belong to transcript_read",
  )
}
