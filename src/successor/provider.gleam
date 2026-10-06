//// The provider boundary (chapter 23.1D).
////
//// Canonical semantic core + adapter-owned continuation capsule (chapter
//// 20.5): the runtime NEVER inspects the capsule — it stores it, binds it to
//// the adapter's compatibility domain, and hands it back only to an adapter
//// claiming the same domain. Provider-specific reasoning representation is
//// sensitive data and stays inside the capsule.

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import successor/ids.{type ProviderAttemptId}

// --- canonical content ----------------------------------------------------

pub type Role {
  User
  Assistant
}

pub type ContentBlock {
  TextBlock(text: String)
  /// Private reasoning: durable transcript data, never ordinary prose
  /// (chapter 20.5 — never stringified into assistant text).
  ThinkingBlock(thinking: String)
  ToolUseBlock(id: String, name: String, input: String)
  ToolResultBlock(tool_use_id: String, content: String, is_error: Bool)
}

pub type Message {
  Message(role: Role, blocks: List(ContentBlock))
}

pub type Tool {
  Tool(name: String, description: String, input_schema: String)
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

// --- request / response ---------------------------------------------------

/// Opaque continuation state. `Fresh` starts a new provider-side context;
/// `Capsule` resumes with adapter-private state. `compatibility_domain`
/// names the provider/model-family the capsule is valid for.
pub type Continuation {
  Fresh
  Capsule(payload: String, compatibility_domain: String)
}

pub type Request {
  Request(
    model: String,
    system: String,
    messages: List(Message),
    tools: List(Tool),
    max_tokens: Int,
    /// Identity of this provider attempt: every asynchronous completion
    /// carries it (chapter 23.1 build rule 5).
    attempt: ProviderAttemptId,
    continuation: Continuation,
  )
}

pub type StopReason {
  EndTurn
  ToolUse
  MaxTokens
}

pub type Response {
  Response(
    stop_reason: StopReason,
    blocks: List(ContentBlock),
    usage: Usage,
    /// Capsule for the NEXT turn with the SAME adapter. Fresh when the
    /// adapter holds no provider-private state.
    continuation: Continuation,
  )
}

/// Typed failures (chapter 23.1D). Cancellation is `Aborted`.
pub type Failure {
  RateLimited(retry_after_ms: Option(Int))
  AuthFailed
  ContextTooLarge
  Network(String)
  Aborted
  Provider(String)
}

/// An abort signal for an in-flight request. The adapter decides what
/// checking it means; receiving `Abort` at least once means: stop, and
/// report `Aborted` unless a terminal result already exists.
pub type Abort {
  Abort
}

// --- the adapter interface ------------------------------------------------

/// One adapter per provider family. `complete` may block; the caller runs it
/// in its own process. Deterministic adapters (mock) make the whole host
/// testable offline.
pub type Adapter {
  Adapter(
    id: String,
    compatibility_domain: String,
    complete: fn(Request, Option(Subject(Abort))) -> Result(Response, Failure),
  )
}

/// Default max tokens when configuration does not name one. (The reference
/// defaults the main output cap to 16,384 — SOURCE-MANIFEST drift note 3.)
pub const default_max_tokens = 16_384
