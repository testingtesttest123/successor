//// ContextPolicy behavior + the passthrough implementation (chapter 23.1E).
////
//// A policy turns the canonical record tail into a ContextPlan: which
//// records the provider sees, with a token estimate and a projection hash
//// so stale activations can be detected. Passthrough selects everything,
//// byte-faithful. No compression at this phase (chapter 22.6 context group).

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode as ddecode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import successor/db.{type Record}
import successor/provider.{type Message, Assistant, Message, User}

pub type Policy {
  /// Byte-faithful whole-history selection (chapter 22.6: passthrough).
  Passthrough
}

pub type PlannedRecord {
  PlannedRecord(record: Record, blocks: List(provider.ContentBlock))
}

pub type ContextPlan {
  ContextPlan(
    /// Records selected, in contract order (ascending sequence).
    selected: List(PlannedRecord),
    /// Role/message projection the provider receives.
    messages: List(Message),
    /// Estimate only — accounting is the planner's+emitter's to reconcile
    /// (chapter 22.6). ~4 chars per token, deterministic.
    token_estimate: Int,
    /// Hash over the selected record ids + sequence range: two plans with
    /// the same hash select the same history.
    projection_hash: String,
  )
}

/// Compile a plan for the given records under the policy.
pub fn plan(
  policy policy: Policy,
  records records: List(Record),
) -> ContextPlan {
  case policy {
    Passthrough -> passthrough(records)
  }
}

fn passthrough(records: List(Record)) -> ContextPlan {
  let selected =
    list.map(records, fn(r: Record) {
      PlannedRecord(record: r, blocks: decode_blocks(r.payload))
    })
  let messages =
    selected
    |> list.map(fn(p: PlannedRecord) {
      let role = case p.record.kind {
        "assistant" -> Assistant
        _ -> User
      }
      Message(role: role, blocks: p.blocks)
    })
  let chars =
    selected
    |> list.fold(0, fn(acc, p: PlannedRecord) { acc + blocks_chars(p.blocks) })
  let hash = projection_hash(records)
  ContextPlan(
    selected: selected,
    messages: messages,
    token_estimate: chars / 4 + 1,
    projection_hash: hash,
  )
}

/// Records are stored with JSON payloads of canonical content blocks.
/// The decode is lenient by design at this phase: an unparsable payload
/// becomes a single text block so nothing is silently dropped.
pub fn decode_blocks(payload: String) -> List(provider.ContentBlock) {
  case parse_blocks(payload) {
    Ok(blocks) -> blocks
    Error(_) -> [provider.TextBlock(payload)]
  }
}

fn parse_blocks(payload: String) -> Result(List(provider.ContentBlock), Nil) {
  let parsed = json.parse(from: payload, using: blocks_decoder())
  case parsed {
    Ok(blocks) -> Ok(blocks)
    Error(_) -> Error(Nil)
  }
}

fn blocks_decoder() -> ddecode.Decoder(List(provider.ContentBlock)) {
  ddecode.list(block_decoder())
}

fn block_decoder() -> ddecode.Decoder(provider.ContentBlock) {
  use kind <- ddecode.field("type", ddecode.string)
  case kind {
    "text" -> {
      use text <- ddecode.field("text", ddecode.string)
      ddecode.success(provider.TextBlock(text))
    }
    "thinking" -> {
      use thinking <- ddecode.field("thinking", ddecode.string)
      ddecode.success(provider.ThinkingBlock(thinking))
    }
    "tool_use" -> {
      use id <- ddecode.field("id", ddecode.string)
      use name <- ddecode.field("name", ddecode.string)
      use input <- ddecode.field("input", ddecode.string)
      ddecode.success(provider.ToolUseBlock(id, name, input))
    }
    "tool_result" -> {
      use tool_use_id <- ddecode.field("toolUseId", ddecode.string)
      use content <- ddecode.field("content", ddecode.string)
      use is_error <- ddecode.field("isError", ddecode.bool)
      ddecode.success(provider.ToolResultBlock(tool_use_id, content, is_error))
    }
    _ -> ddecode.failure(provider.TextBlock(""), "ContentBlock")
  }
}

fn blocks_chars(blocks: List(provider.ContentBlock)) -> Int {
  list.fold(blocks, 0, fn(acc, b) {
    case b {
      provider.TextBlock(text) -> acc + string.length(text)
      provider.ThinkingBlock(t) -> acc + string.length(t)
      provider.ToolUseBlock(input, _, _) -> acc + string.length(input)
      provider.ToolResultBlock(content, _, _) -> acc + string.length(content)
    }
  })
}

/// Stable hash over `id@sequence` pairs, in order. Same history -> same hash;
/// any append changes it (used for stale-activation detection in 1F).
fn projection_hash(records: List(Record)) -> String {
  let fingerprint =
    records
    |> list.map(fn(r: Record) { r.id <> "@" <> int.to_string(r.sequence) })
    |> string.join(",")
  crypto.hash(crypto.Sha256, <<fingerprint:utf8>>) |> bit_array.base16_encode
}
