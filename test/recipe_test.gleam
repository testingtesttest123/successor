import gleam/list
import successor/recipe

// Chapter 23.1C: provenance-carrying canonical config, strict normal schema,
// and a compatibility reader for the reference recipe oracle subset.

pub fn canonical_config_round_trip_test() {
  let json_text =
    "{ \"dataDir\": \"/tmp/store\", \"operator\": {\"host\": \"0.0.0.0\", \"port\": 8080},"
    <> " \"providers\": [ {\"id\": \"m\", \"kind\": \"mock\", \"echoMode\": false,"
    <> " \"defaultResponse\": \"canned\"} ] }"
  let assert Ok(outcome) = recipe.from_json(text: json_text)
  assert outcome.config.data_dir == "/tmp/store"
  assert outcome.config.operator.host == "0.0.0.0"
  assert outcome.config.operator.port == 8080
  // Provenance: recipe-sourced fields are marked as such.
  assert has_provenance(outcome.provenance, "dataDir", recipe.Recipe)
  assert has_provenance(outcome.provenance, "operator", recipe.Recipe)
  assert has_provenance(outcome.provenance, "providers", recipe.Recipe)
  let assert [only] = outcome.config.providers
  let assert config.MockProvider("m", False, "canned") = only
}

import successor/config

pub fn defaults_are_marked_as_defaults_test() {
  let assert Ok(outcome) = recipe.from_json(text: "{ \"dataDir\": \"/tmp/s\" }")
  assert has_provenance(outcome.provenance, "operator", recipe.Defaults)
  assert has_provenance(outcome.provenance, "providers", recipe.Defaults)
}

pub fn reference_recipe_reader_accepts_mock_subset_test() {
  // Modeled on conformance/fixtures/recipes/mock-minimal.json.
  let recipe_text =
    "{ \"name\": \"Conformance Mock Minimal\","
    <> " \"agent\": { \"name\": \"agent\", \"provider\": \"mock\","
    <> " \"systemPrompt\": \"You are a mock agent for offline host testing.\" },"
    <> " \"modules\": { \"subagents\": false, \"lessons\": false, \"retrieval\": false,"
    <> " \"wake\": false, \"workspace\": false } }"
  let assert Ok(outcome) = recipe.read_reference_recipe(text: recipe_text)
  // The mock provider is selected with the recipe's agent name as its id.
  let assert [only] = outcome.config.providers
  let assert config.MockProvider("agent", True, _) = only
  // Module toggles are accepted-but-not-modeled and recorded BY NAME.
  assert list.any(outcome.warnings, fn(w) { string_contains(w, "subagents") })
  assert list.any(outcome.warnings, fn(w) { string_contains(w, "wake") })
}

pub fn reference_recipe_mock_settings_test() {
  let recipe_text =
    "{ \"agent\": { \"name\": \"a\", \"provider\": \"mock\","
    <> " \"mock\": { \"echoMode\": false, \"defaultResponse\": \"canned\" } } }"
  let assert Ok(outcome) = recipe.read_reference_recipe(text: recipe_text)
  let assert [config.MockProvider(_, False, "canned")] = outcome.config.providers
}

pub fn reference_recipe_rejects_unsupported_provider_test() {
  let recipe_text =
    "{ \"agent\": { \"name\": \"a\", \"provider\": \"anthropic\" } }"
  let assert Error(_) = recipe.read_reference_recipe(text: recipe_text)
}

pub fn reference_recipe_rejects_malformed_json_test() {
  let assert Error(recipe.MalformedJson(_)) =
    recipe.read_reference_recipe(text: "{ not json")
}

pub fn canonical_config_rejects_malformed_json_test() {
  let assert Error(recipe.MalformedJson(_)) = recipe.from_json(text: "nope")
}

pub fn canonical_config_rejects_invalid_values_test() {
  let assert Error(recipe.InvalidValue(_)) =
    recipe.from_json(text: "{ \"dataDir\": \"\" }")
}

// --- helpers --------------------------------------------------------------

import gleam/string

fn string_contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

fn has_provenance(
  provenance: List(recipe.Provenance),
  field field: String,
  source source: recipe.Source,
) -> Bool {
  list.any(provenance, fn(p: recipe.Provenance) { p.field == field && p.source == source })
}
