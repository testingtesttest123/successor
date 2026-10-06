import gleam/list
import gleam/string
import successor/ids

// Chapter 20.7: explicit opaque IDs. Freshness is the contract — values are
// generated, compared, and stored, never derived from content.

pub fn fresh_ids_are_unique_test() {
  let a = ids.fresh(prefix: "x")
  let b = ids.fresh(prefix: "x")
  assert a != b
}

pub fn fresh_ids_use_the_prefix_test() {
  let id = ids.fresh(prefix: "dep")
  assert string.starts_with(id, "dep_")
}

pub fn fresh_ids_are_hex_suffixed_test() {
  let assert "dep_" <> suffix = ids.fresh(prefix: "dep")
  assert string.length(suffix) == 32
  let chars = string.to_graphemes(suffix)
  assert list.all(chars, is_hex_digit)
}

pub fn id_values_are_distinct_test() {
  // Identity is generated, never derived: two ids of DIFFERENT ontology
  // kinds still carry different values.
  let ids.DeploymentId(dep_value) = ids.new_deployment_id()
  let ids.SessionId(session_value) = ids.new_session_id()
  assert dep_value != session_value
}

pub fn each_ontology_id_has_a_generator_test() {
  // Compile-time property: each generator returns its own nominal type.
  let ids.BranchId(_) = ids.new_branch_id()
  let ids.AgentId(_) = ids.new_agent_id()
  let ids.AgentIncarnationId(_) = ids.new_agent_incarnation_id()
  let ids.ActivationId(_) = ids.new_activation_id()
  let ids.ContextCompileId(_) = ids.new_context_compile_id()
  let ids.ToolCallId(_) = ids.new_tool_call_id()
  let ids.EffectId(_) = ids.new_effect_id()
  let ids.ProviderAttemptId(_) = ids.new_provider_attempt_id()
}

fn is_hex_digit(c: String) -> Bool {
  case c {
    "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f" -> True
    _ -> False
  }
}
