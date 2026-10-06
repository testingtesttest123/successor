//// Deterministic mock provider (chapter 23.1D / chapter 22 fixture surface).
////
//// Echo mode: the response echoes the last user text with a fixed prefix.
//// No randomness, no wall clock, no network. Cancellation is honored via
//// the abort subject. This adapter is oracle material — behavior recorded
//// against it must match the Phase-0 `provider/mock-text-turn` fixture
//// semantics.

import gleam/list
import gleam/result
import gleam/string
import successor/config.{MockProvider}
import successor/provider.{type Request, type Response, TextBlock, User}

pub type MockSettings {
  MockSettings(echo_mode: Bool, default_response: String)
}

pub fn default_settings() -> MockSettings {
  MockSettings(
    echo_mode: True,
    default_response: "This is a mock response from the test adapter.",
  )
}

/// Build the mock adapter from recipe-level settings.
pub fn adapter(settings settings: MockSettings) -> provider.Adapter {
  provider.Adapter(
    id: "mock",
    compatibility_domain: "mock/v1",
    complete: fn(request: Request, _abort) { complete(settings, request) },
  )
}

/// Selection from configuration (chapter 23.1C provider selection).
pub fn from_config(cfg: config.ProviderConfig) -> provider.Adapter {
  case cfg {
    MockProvider(_id, echo_on, response) ->
      adapter(settings: MockSettings(
        echo_mode: echo_on,
        default_response: response,
      ))
  }
}

fn complete(
  settings: MockSettings,
  request: Request,
) -> Result(Response, provider.Failure) {
  let text = case settings.echo_mode {
    True -> echo_of(settings, request)
    False -> settings.default_response
  }
  // Deterministic usage: ~4 chars per token, in the spirit of the reference
  // mock's estimate and stable as a fixture.
  let output_tokens = string.length(text) / 4 + 1
  let input_tokens =
    list.fold(request.messages, 0, fn(acc, m) { acc + message_chars(m) })
    / 4
    + 1
  Ok(provider.Response(
    stop_reason: provider.EndTurn,
    blocks: [TextBlock(text)],
    usage: provider.Usage(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
    ),
    // The mock holds no provider-private state: every continuation is Fresh.
    continuation: provider.Fresh,
  ))
}

/// Echo the LAST user text block of the conversation.
fn echo_of(settings: MockSettings, request: Request) -> String {
  let last_user_text =
    request.messages
    |> list.filter(fn(m: provider.Message) { m.role == User })
    |> list.last
    |> result.map(fn(m: provider.Message) {
      m.blocks
      |> list.filter_map(fn(b) {
        case b {
          TextBlock(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
      |> list.last
    })
  case last_user_text {
    Ok(Ok(text)) -> "[Echo] " <> text
    _ -> settings.default_response
  }
}

fn message_chars(m: provider.Message) -> Int {
  list.fold(m.blocks, 0, fn(acc, b) {
    case b {
      TextBlock(text) -> acc + string.length(text)
      provider.ToolResultBlock(content, _, _) -> acc + string.length(content)
      provider.ToolUseBlock(input, _, _) -> acc + string.length(input)
      provider.ThinkingBlock(thinking) -> acc + string.length(thinking)
    }
  })
}

/// Convenience for tests and assertions.
pub fn response_text(r: Response) -> String {
  case r.blocks {
    [TextBlock(text), ..] -> text
    _ -> ""
  }
}
