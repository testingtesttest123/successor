//// Opaque identity types for the successor ontology (chapter 20.7).
////
//// Every live resource has exactly one of these identifiers; display names
//// are metadata and never authorization or destructive-action identity.
//// Constructors are exposed for persistence adapters, but business code
//// should treat these as opaque values that are generated, compared, and
//// stored — never parsed apart.

import gleam/bit_array
import gleam/crypto
import gleam/string

pub type DeploymentId {
  DeploymentId(value: String)
}

pub type SessionId {
  SessionId(value: String)
}

pub type BranchId {
  BranchId(value: String)
}

pub type AgentId {
  AgentId(value: String)
}

pub type AgentIncarnationId {
  AgentIncarnationId(value: String)
}

pub type ActivationId {
  ActivationId(value: String)
}

pub type ContextCompileId {
  ContextCompileId(value: String)
}

pub type ToolCallId {
  ToolCallId(value: String)
}

pub type EffectId {
  EffectId(value: String)
}

pub type ProviderAttemptId {
  ProviderAttemptId(value: String)
}

/// Fresh random identity: `<prefix>_<32 lowercase hex chars>` from 16 bytes
/// of cryptographically strong entropy. Uniqueness across restarts is the
/// contract; the prefix keeps rows human-auditable in the store.
pub fn fresh(prefix prefix: String) -> String {
  prefix
  <> "_"
  <> crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn new_deployment_id() -> DeploymentId {
  DeploymentId(fresh(prefix: "dep"))
}

pub fn new_session_id() -> SessionId {
  SessionId(fresh(prefix: "ses"))
}

pub fn new_branch_id() -> BranchId {
  BranchId(fresh(prefix: "br"))
}

pub fn new_agent_id() -> AgentId {
  AgentId(fresh(prefix: "agent"))
}

pub fn new_agent_incarnation_id() -> AgentIncarnationId {
  AgentIncarnationId(fresh(prefix: "inc"))
}

pub fn new_activation_id() -> ActivationId {
  ActivationId(fresh(prefix: "act"))
}

pub fn new_context_compile_id() -> ContextCompileId {
  ContextCompileId(fresh(prefix: "ctx"))
}

pub fn new_tool_call_id() -> ToolCallId {
  ToolCallId(fresh(prefix: "tc"))
}

pub fn new_effect_id() -> EffectId {
  EffectId(fresh(prefix: "eff"))
}

pub fn new_provider_attempt_id() -> ProviderAttemptId {
  ProviderAttemptId(fresh(prefix: "pa"))
}
