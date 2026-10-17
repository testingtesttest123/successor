//// Converts durable provider output into the portable model-input subset.
//// Raw replay remains untouched only for the provider/protocol that produced it.

import albedo/context_cost
import albedo/daemon/message_content as events
import albedo/daemon/transcript
import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Non-payload facts sufficient to price complete native units on either wire.
/// Consecutive transferred Responses rows retain their Chat coalescing boundary.
pub type ChatPrice {
  Direct(tokens: Int)
  Fragment(text_bytes: Int, has_text: Bool, call_bytes: Int, calls: Int)
}

pub type CostFacts {
  CostFacts(
    native_tokens: Int,
    provider: Option(String),
    protocol: Option(types.Protocol),
    responses: Result(Int, String),
    chat: Result(ChatPrice, String),
  )
}

pub fn cost_facts(entry: transcript.Entry) -> CostFacts {
  let native = context_cost.estimate_input(entry.input)
  case entry.input {
    types.Replay(item) -> {
      // Force transfer independently of any saved provider name.
      let foreign = transcript.Entry(..entry, provider: None)
      let responses =
        for_model([foreign], "", types.Responses)
        |> result.map(context_cost.estimate_inputs)
      let chat = case types.replay_protocol(item) {
        types.ChatCompletions ->
          for_model([foreign], "", types.ChatCompletions)
          |> result.map(fn(inputs) {
            Direct(context_cost.estimate_inputs(inputs))
          })
        types.Responses ->
          response_semantics(item)
          |> result.map(fn(semantic) {
            case semantic {
              ResponseReasoning("") -> Fragment(0, False, 0, 0)
              ResponseReasoning(text) -> text_fragment(reasoning_summary(text))
              ResponseText(text) -> text_fragment(text)
              ResponseCall(call) ->
                Fragment(
                  0,
                  False,
                  string.byte_size(json.to_string(replay.tool_call(call))),
                  1,
                )
            }
          })
      }
      CostFacts(
        native,
        entry.provider,
        Some(types.replay_protocol(item)),
        responses,
        chat,
      )
    }
    _ -> CostFacts(native, entry.provider, None, Ok(native), Ok(Direct(native)))
  }
}

fn text_fragment(text: String) -> ChatPrice {
  Fragment(string.byte_size(json.to_string(json.string(text))) - 2, True, 0, 0)
}

/// Same projection transitions as for_model; only immutable scalar facts cross this seam.
pub fn estimate_facts(
  facts: List(CostFacts),
  provider: Option(String),
  protocol: types.Protocol,
) -> Result(Int, String) {
  price_facts(facts, provider, protocol, 0, Fragment(0, False, 0, 0))
}

fn price_facts(
  facts: List(CostFacts),
  provider: Option(String),
  protocol: types.Protocol,
  total: Int,
  pending: ChatPrice,
) -> Result(Int, String) {
  case facts {
    [] -> Ok(total + fragment_tokens(pending))
    [fact, ..rest] -> {
      let own =
        provider != None
        && fact.provider == provider
        && fact.protocol == Some(protocol)
      case own, protocol {
        True, _ ->
          price_facts(
            rest,
            provider,
            protocol,
            total + fragment_tokens(pending) + fact.native_tokens,
            Fragment(0, False, 0, 0),
          )
        False, types.Responses -> {
          use tokens <- result.try(fact.responses)
          price_facts(rest, provider, protocol, total + tokens, pending)
        }
        False, types.ChatCompletions -> {
          use chat <- result.try(fact.chat)
          case chat, pending {
            Direct(tokens), _ ->
              price_facts(
                rest,
                provider,
                protocol,
                total + fragment_tokens(pending) + tokens,
                Fragment(0, False, 0, 0),
              )
            Fragment(t, h, c, n), Fragment(pt, ph, pc, pn) ->
              price_facts(
                rest,
                provider,
                protocol,
                total,
                Fragment(pt + t, ph || h, pc + c, pn + n),
              )
            _, Direct(_) -> Error("invalid pending Chat price")
          }
        }
      }
    }
  }
}

fn fragment_tokens(fragment: ChatPrice) -> Int {
  case fragment {
    Fragment(_, False, _, 0) -> 0
    Fragment(text, has_text, call_bytes, calls) -> {
      let shell =
        string.byte_size(
          json.to_string(replay.message(json.null(), "", None, [])),
        )
      let content = case has_text {
        True -> text + 2 - 4
        False -> 0
      }
      let tools = case calls {
        0 -> 0
        _ -> {
          let blank = types.ToolCall("", "", "")
          let with_call =
            string.byte_size(
              json.to_string(replay.message(json.null(), "", None, [blank])),
            )
          let blank_bytes =
            string.byte_size(json.to_string(replay.tool_call(blank)))
          with_call - shell - blank_bytes + call_bytes + calls - 1
        }
      }
      { shell + content + tools + 3 } / 4 + 12
    }
    Direct(tokens) -> tokens
  }
}

/// Durable index boundary: scalar projection facts only, never text or replay bodies.
pub fn cost_facts_json(facts: CostFacts) -> json.Json {
  let responses = case facts.responses {
    Ok(tokens) -> [#("responses", json.int(tokens))]
    Error(message) -> [#("responses_error", json.string(message))]
  }
  let chat = case facts.chat {
    Error(message) -> [#("chat_error", json.string(message))]
    Ok(Direct(tokens)) -> [#("chat", json.int(tokens))]
    Ok(Fragment(text, has_text, bytes, calls)) -> [
      #("text_bytes", json.int(text)),
      #("has_text", json.bool(has_text)),
      #("call_bytes", json.int(bytes)),
      #("calls", json.int(calls)),
    ]
  }
  json.object(list.append(
    [
      #("native", json.int(facts.native_tokens)),
      #(
        "provider",
        option.map(facts.provider, json.string) |> option.unwrap(json.null()),
      ),
      #(
        "protocol",
        option.map(facts.protocol, fn(p) { json.string(types.protocol_name(p)) })
          |> option.unwrap(json.null()),
      ),
    ],
    list.append(responses, chat),
  ))
}

pub fn cost_facts_decoder() -> decode.Decoder(CostFacts) {
  use native <- decode.field("native", decode.int)
  use provider <- decode.field("provider", decode.optional(decode.string))
  use protocol <- decode.field(
    "protocol",
    decode.optional(types.protocol_decoder()),
  )
  use response_error <- decode.optional_field(
    "responses_error",
    None,
    decode.optional(decode.string),
  )
  use response_tokens <- decode.optional_field("responses", 0, decode.int)
  use chat_error <- decode.optional_field(
    "chat_error",
    None,
    decode.optional(decode.string),
  )
  use direct <- decode.optional_field("chat", None, decode.optional(decode.int))
  use text <- decode.optional_field("text_bytes", 0, decode.int)
  use has_text <- decode.optional_field("has_text", False, decode.bool)
  use bytes <- decode.optional_field("call_bytes", 0, decode.int)
  use calls <- decode.optional_field("calls", 0, decode.int)
  decode.success(
    CostFacts(
      native,
      provider,
      protocol,
      case response_error {
        Some(error) -> Error(error)
        None -> Ok(response_tokens)
      },
      case chat_error, direct {
        Some(error), _ -> Error(error)
        None, Some(tokens) -> Ok(Direct(tokens))
        None, None -> Ok(Fragment(text, has_text, bytes, calls))
      },
    ),
  )
}

/// A native image fit changes dimensions, with every other projection fact retained.
pub fn adjust_image_tokens(facts: CostFacts, delta: Int) -> CostFacts {
  CostFacts(
    ..facts,
    native_tokens: facts.native_tokens + delta,
    responses: result.map(facts.responses, fn(tokens) { tokens + delta }),
    chat: result.map(facts.chat, fn(chat) {
      case chat {
        Direct(tokens) -> Direct(tokens + delta)
        fragment -> fragment
      }
    }),
  )
}

pub fn for_model(
  newest_first: List(transcript.Entry),
  provider: String,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  newest_first
  |> list.reverse
  |> project(provider, protocol, [], empty_chat())
}

fn project(
  entries: List(transcript.Entry),
  provider: String,
  protocol: types.Protocol,
  projected: List(types.Input),
  pending_chat: ChatSemantic,
) -> Result(List(types.Input), String) {
  case entries {
    [] -> flush_chat(projected, pending_chat)
    [entry, ..rest] -> {
      // Both continuations capture this row's position in the walk.
      let ahead = fn(inputs: List(types.Input)) {
        use projected <- result.try(flush_chat(projected, pending_chat))
        project(
          rest,
          provider,
          protocol,
          list.append(list.reverse(inputs), projected),
          empty_chat(),
        )
      }
      let carry = fn(chat: ChatSemantic) {
        project(rest, provider, protocol, projected, chat)
      }
      case entry.input {
        types.Replay(item) ->
          case
            types.replay_protocol(item) == protocol
            && entry.provider == Some(provider)
          {
            True -> ahead([entry.input])
            False ->
              case types.replay_protocol(item), protocol {
                types.Responses, types.ChatCompletions ->
                  case response_semantics(item) {
                    Ok(ResponseReasoning(summary)) ->
                      case summary {
                        "" -> carry(pending_chat)
                        _ ->
                          carry(add_text(
                            pending_chat,
                            reasoning_summary(summary),
                          ))
                      }
                    Ok(ResponseCall(call)) ->
                      carry(add_call(pending_chat, call))
                    Ok(ResponseText(text)) ->
                      carry(add_text(pending_chat, text))
                    Error(error) -> Error(error)
                  }
                types.Responses, types.Responses -> {
                  use inputs <- result.try(canonical_response(item))
                  ahead(inputs)
                }
                types.ChatCompletions, target -> {
                  use semantics <- result.try(chat_semantics(item))
                  use inputs <- result.try(chat_inputs(semantics, target))
                  ahead(inputs)
                }
              }
          }
        input -> ahead([input])
      }
    }
  }
}

type ResponseSemantic {
  ResponseReasoning(String)
  ResponseText(String)
  ResponseCall(types.ToolCall)
}

fn canonical_response(
  item: types.ReplayItem,
) -> Result(List(types.Input), String) {
  use semantic <- result.try(response_semantics(item))
  case semantic {
    ResponseReasoning("") -> Ok([])
    ResponseReasoning(summary) ->
      Ok([types.Assistant(reasoning_summary(summary))])
    ResponseText(text) -> Ok([types.Assistant(text)])
    ResponseCall(call) ->
      response_call(call)
      |> result.map(fn(item) { [types.Replay(item)] })
  }
}

fn response_semantics(
  item: types.ReplayItem,
) -> Result(ResponseSemantic, String) {
  use kind <- result.try(inspect(
    item,
    decode.field("type", decode.string, decode.success),
    "Responses output item type",
  ))
  case kind {
    "reasoning" -> Ok(ResponseReasoning(events.thinking_text(item)))
    "message" -> response_text(item) |> result.map(ResponseText)
    "function_call" -> response_call_semantics(item) |> result.map(ResponseCall)
    other ->
      Error(
        "cannot transfer Responses output item type "
        <> string.inspect(other)
        <> "; its semantics are not portable",
      )
  }
}

fn reasoning_summary(text: String) -> String {
  "[Reasoning summary]\n" <> text
}

fn response_text(item: types.ReplayItem) -> Result(String, String) {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.list(response_part_decoder()))
    case role {
      "assistant" -> decode.success(string.concat(content))
      _ -> decode.failure("", "assistant response message")
    }
  }
  inspect(item, decoder, "Responses assistant message")
}

fn response_part_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "output_text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(text)
    }
    "refusal" -> {
      use text <- decode.field("refusal", decode.string)
      decode.success(text)
    }
    other -> decode.failure("", "portable response content part, got " <> other)
  }
}

fn response_call_semantics(
  item: types.ReplayItem,
) -> Result(types.ToolCall, String) {
  inspect(item, replay.function_call_decoder(), "Responses function call")
}

type ChatSemantic {
  ChatSemantic(text: List(String), calls: List(types.ToolCall))
}

fn chat_semantics(item: types.ReplayItem) -> Result(ChatSemantic, String) {
  let decoder = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use _ <- decode.then(reject_chat_semantics(fields))
    use content <- decode.optional_field(
      "content",
      None,
      decode.optional(decode.string),
    )
    use refusal <- decode.optional_field(
      "refusal",
      None,
      decode.optional(decode.string),
    )
    use calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(chat_call_decoder()),
    )
    let text =
      list.filter_map([content, refusal], fn(value) {
        case value {
          Some(text) -> Ok(text)
          None -> Error(Nil)
        }
      })
    let summary = case events.thinking_text(item) {
      "" -> []
      text -> [reasoning_summary(text)]
    }
    decode.success(ChatSemantic(list.append(summary, text), calls))
  }
  inspect(item, decoder, "Chat Completions assistant message")
}

fn reject_chat_semantics(
  fields: Dict(String, dynamic.Dynamic),
) -> decode.Decoder(Nil) {
  case
    fields
    |> dict.keys
    |> list.find(fn(name) { !list.contains(replay.portable_fields, name) })
  {
    Ok(name) ->
      decode.failure(Nil, "known portable assistant field, got " <> name)
    Error(_) -> decode.success(Nil)
  }
}

fn chat_call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.optional_field("type", "function", decode.string)
  use call <- decode.field("function", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  })
  case kind == "function" && id != "" && call.0 != "" {
    True -> decode.success(types.ToolCall(id, call.0, call.1))
    False ->
      decode.failure(
        types.ToolCall(id, call.0, call.1),
        "function tool call with identity",
      )
  }
}

fn empty_chat() -> ChatSemantic {
  ChatSemantic([], [])
}

/// A call joins the message being assembled.
fn add_call(chat: ChatSemantic, call: types.ToolCall) -> ChatSemantic {
  let ChatSemantic(text, calls) = chat
  ChatSemantic(text, [call, ..calls])
}

/// Answer text joins the message being assembled.
fn add_text(chat: ChatSemantic, text: String) -> ChatSemantic {
  let ChatSemantic(texts, calls) = chat
  ChatSemantic([text, ..texts], calls)
}

fn chat_inputs(
  semantic: ChatSemantic,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  let ChatSemantic(text, calls) = semantic
  case protocol {
    types.ChatCompletions ->
      case calls {
        [] -> Ok(list.map(text, types.Assistant))
        _ ->
          chat_message(text, calls)
          |> result.map(fn(item) { [types.Replay(item)] })
      }
    types.Responses -> {
      use tools <- result.try(
        list.try_map(calls, fn(call) {
          response_call(call) |> result.map(types.Replay)
        }),
      )
      Ok(list.append(list.map(text, types.Assistant), tools))
    }
  }
}

fn flush_chat(
  projected: List(types.Input),
  pending: ChatSemantic,
) -> Result(List(types.Input), String) {
  let ChatSemantic(text, calls) = pending
  case text, calls {
    [], [] -> Ok(projected)
    _, _ -> {
      use item <- result.try(chat_message(
        list.reverse(text),
        list.reverse(calls),
      ))
      Ok([types.Replay(item), ..projected])
    }
  }
}

fn chat_message(
  text: List(String),
  calls: List(types.ToolCall),
) -> Result(types.ReplayItem, String) {
  replay_item(
    types.ChatCompletions,
    replay.message(
      case text {
        [] -> json.null()
        text -> json.string(string.concat(text))
      },
      "",
      None,
      calls,
    ),
  )
}

fn response_call(call: types.ToolCall) -> Result(types.ReplayItem, String) {
  replay_item(
    types.Responses,
    json.object([
      #("type", json.string("function_call")),
      #("call_id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments)),
      #("status", json.string("completed")),
    ]),
  )
}

fn replay_item(
  protocol: types.Protocol,
  value: json.Json,
) -> Result(types.ReplayItem, String) {
  json.parse(json.to_string(value), types.replay_decoder(protocol))
  |> result.map_error(fn(error) {
    "could not construct portable replay item: " <> string.inspect(error)
  })
}

fn inspect(
  item: types.ReplayItem,
  decoder: decode.Decoder(a),
  context: String,
) -> Result(a, String) {
  types.inspect_item(item, decoder)
  |> result.map_error(fn(error) { context <> ": " <> string.inspect(error) })
}
