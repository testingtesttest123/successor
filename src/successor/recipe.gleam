//// Configuration loading (chapter 23.1C): the successor's canonical typed
//// config from JSON, with effective-value PROVENANCE, and a compatibility
//// reader for the reference recipe subset needed by the minimum oracle.
////
//// The normal schema is strict: unknown fields are errors, never silently
//// projected away (chapter 20.3 class C). The compatibility reader accepts
//// the pinned reference's recipe shape for the oracle subset; module
//// toggles it does not model are recorded as named warnings, not dropped.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import successor/config.{
  type Config, type ProviderConfig, MockProvider, OperatorBinding,
}

pub type Source {
  Defaults
  Recipe
}

/// Where each effective value came from (chapter 23.1C provenance).
pub type Provenance {
  Provenance(field: String, source: Source)
}

pub type LoadOutcome {
  LoadOutcome(
    config: Config,
    provenance: List(Provenance),
    warnings: List(String),
  )
}

pub type LoadError {
  MalformedJson(String)
  UnknownField(String)
  InvalidValue(String)
}

/// Wrap a decoder so that object KEYS outside `known` make the whole decode
/// fail with the first offending name. Strictness is the normal schema's
/// contract: unknown fields are errors, never silently projected away
/// (chapter 20.3 class C).
fn reject_unknown(
  known: List(String),
  inner: decode.Decoder(t),
) -> decode.Decoder(t) {
  use keys <- decode.then(decode.dict(decode.string, decode.dynamic))
  use value <- decode.then(inner)
  let offenders =
    dict.keys(keys)
    |> list.filter(fn(k) { !list.contains(known, k) })
  case offenders {
    [] -> decode.success(value)
    [first, ..] -> decode.failure(value, "known-field:" <> first)
  }
}

// --- canonical schema (strict) ---------------------------------------------

/// {
///   "dataDir": "/path",
///   "operator": { "host": "127.0.0.1", "port": 0 },
///   "providers": [ { "id": "mock", "kind": "mock",
///                    "echoMode": true, "defaultResponse": "..." } ]
/// }
pub const known_top_level = ["dataDir", "operator", "providers"]

pub const known_operator = ["host", "port"]

pub const known_provider = ["id", "kind", "echoMode", "defaultResponse"]

// Compatibility-reader allowlists (reference recipe subset).
pub const known_recipe_top_level = ["name", "agent", "modules"]

pub const known_recipe_agent = ["name", "provider", "systemPrompt", "mock"]

pub const known_recipe_mock = ["echoMode", "defaultResponse"]

pub fn from_json(text text: String) -> Result(LoadOutcome, LoadError) {
  case
    json.parse(
      from: text,
      using: reject_unknown(known_top_level, strict_decoder()),
    )
  {
    Error(json.UnableToDecode(errors)) -> Error(decode_error_kind(errors))
    Error(_) -> Error(MalformedJson("could not parse config"))
    Ok(#(cfg, provenance)) ->
      case config.validate(cfg) {
        Error(e) -> Error(InvalidValue(e))
        Ok(_) ->
          Ok(LoadOutcome(config: cfg, provenance: provenance, warnings: []))
      }
  }
}

/// Map decode failures to their load-error class: unknown-field markers from
/// `reject_unknown` become UnknownField, everything else is malformed input.
fn decode_error_kind(errors: List(decode.DecodeError)) -> LoadError {
  case
    list.filter_map(errors, fn(e: decode.DecodeError) {
      case string.starts_with(e.expected, "known-field:") {
        True -> Ok(string.drop_start(e.expected, 12))
        False -> Error(Nil)
      }
    })
  {
    [field, ..] -> UnknownField(field)
    [] -> MalformedJson("could not parse config")
  }
}

fn strict_decoder() -> decode.Decoder(#(Config, List(Provenance))) {
  use data_dir <- decode.field("dataDir", decode.string)
  use operator <- decode.optional_field(
    "operator",
    OperatorBinding(host: "127.0.0.1", port: 0),
    operator_decoder(),
  )
  use providers <- decode.optional_field("providers", [], provider_decoder())
  let cfg =
    config.Config(data_dir: data_dir, operator: operator, providers: providers)
  let provenance = [
    Provenance("dataDir", source_of(data_dir, "")),
    Provenance("operator", source_of_operator(operator)),
    Provenance("providers", source_of_providers(providers)),
  ]
  decode.success(#(cfg, provenance))
}

fn operator_decoder() -> decode.Decoder(config.OperatorBinding) {
  reject_unknown(known_operator, {
    use host <- decode.optional_field("host", "127.0.0.1", decode.string)
    use port <- decode.optional_field("port", 0, decode.int)
    decode.success(OperatorBinding(host: host, port: port))
  })
}

fn provider_decoder() -> decode.Decoder(List(ProviderConfig)) {
  decode.list(provider_item_decoder())
}

fn provider_item_decoder() -> decode.Decoder(ProviderConfig) {
  reject_unknown(known_provider, {
    use id <- decode.field("id", decode.string)
    use kind <- decode.field("kind", decode.string)
    case kind {
      "mock" -> {
        use echo_on <- decode.optional_field("echoMode", True, decode.bool)
        use response <- decode.optional_field(
          "defaultResponse",
          "This is a mock response from the test adapter.",
          decode.string,
        )
        decode.success(MockProvider(
          id: id,
          echo_mode: echo_on,
          default_response: response,
        ))
      }
      _ ->
        decode.failure(
          MockProvider(id: id, echo_mode: True, default_response: ""),
          "mock provider",
        )
    }
  })
}

fn source_of(value: String, empty: String) -> Source {
  case value == empty {
    True -> Defaults
    False -> Recipe
  }
}

fn source_of_operator(binding: config.OperatorBinding) -> Source {
  case binding.host == "127.0.0.1" && binding.port == 0 {
    True -> Defaults
    False -> Recipe
  }
}

fn source_of_providers(providers: List(ProviderConfig)) -> Source {
  case providers {
    [] -> Defaults
    _ -> Recipe
  }
}

// --- compatibility reader (reference recipe subset) -------------------------

/// Read a PINNED REFERENCE recipe (chapter 23.1C: "a compatibility
/// reader/migrator for the subset needed by the minimum oracle"). Accepted
/// subset: name, agent{name, provider, systemPrompt, mock{echoMode,
/// defaultResponse}}. `modules` toggles are accepted and every recognized
/// module key is reported as a warning (accepted-but-not-modeled). Unknown
/// AGENT-level fields are ERRORS — the compat path accepts legacy SHAPE, it
/// does not reproduce permissive legacy VALIDATION.
pub fn read_reference_recipe(
  text text: String,
) -> Result(LoadOutcome, LoadError) {
  case
    json.parse(
      from: text,
      using: reject_unknown(known_recipe_top_level, recipe_decoder()),
    )
  {
    Error(json.UnableToDecode(errors)) -> Error(decode_error_kind(errors))
    Error(_) -> Error(MalformedJson("could not parse reference recipe"))
    Ok(#(cfg, warnings)) ->
      case config.validate(cfg) {
        Error(e) -> Error(InvalidValue(e))
        Ok(_) -> {
          let provenance = [
            Provenance("dataDir", Defaults),
            Provenance("operator", Defaults),
            Provenance("providers", case cfg.providers {
              [] -> Defaults
              _ -> Recipe
            }),
          ]
          Ok(LoadOutcome(
            config: cfg,
            provenance: provenance,
            warnings: warnings,
          ))
        }
      }
  }
}

fn recipe_decoder() -> decode.Decoder(#(Config, List(String))) {
  use name <- decode.optional_field("name", "", decode.string)
  use agent <- decode.field("agent", agent_decoder())
  use modules <- decode.optional_field("modules", [], module_decoder())
  let #(providers, agent_warnings) = agent
  let data_dir = "data"
  let module_warnings =
    list.map(modules, fn(m: String) {
      "recipe module accepted, not modeled: " <> m
    })
  let agent_and_modules = list.append(agent_warnings, module_warnings)
  let warnings = case name {
    "" -> agent_and_modules
    _ -> [
      "recipe.name accepted (display metadata): " <> name,
      ..agent_and_modules
    ]
  }
  decode.success(#(
    config.Config(
      data_dir: data_dir,
      operator: OperatorBinding(host: "127.0.0.1", port: 0),
      providers: providers,
    ),
    warnings,
  ))
}

fn agent_decoder() -> decode.Decoder(#(List(ProviderConfig), List(String))) {
  reject_unknown(known_recipe_agent, {
    use name <- decode.field("name", decode.string)
    use provider_kind <- decode.field("provider", decode.string)
    use system <- decode.optional_field("systemPrompt", "", decode.string)
    use mock_block <- decode.optional_field(
      "mock",
      #(True, "This is a mock response from the test adapter."),
      mock_decoder(),
    )
    let #(echo_on, response) = mock_block
    case provider_kind {
      "mock" ->
        decode.success(
          #(
            [
              MockProvider(
                id: name,
                echo_mode: echo_on,
                default_response: response,
              ),
            ],
            [system_prompt_warning(system)],
          ),
        )
      other ->
        decode.failure(
          #([], ["unsupported recipe provider: " <> other]),
          "reference recipe provider",
        )
    }
  })
}

fn system_prompt_warning(system: String) -> String {
  case system {
    "" -> "recipe has no systemPrompt"
    _ -> "recipe.systemPrompt accepted (agent behavior, not host config)"
  }
}

fn mock_decoder() -> decode.Decoder(#(Bool, String)) {
  reject_unknown(known_recipe_mock, {
    use echo_on <- decode.optional_field("echoMode", True, decode.bool)
    use response <- decode.optional_field(
      "defaultResponse",
      "This is a mock response from the test adapter.",
      decode.string,
    )
    decode.success(#(echo_on, response))
  })
}

fn module_decoder() -> decode.Decoder(List(String)) {
  // Module toggles are recorded by NAME (accepted, not modeled). The value
  // is validated as JSON but not interpreted.
  let entries: decode.Decoder(dict.Dict(String, decode.Dynamic)) =
    decode.dict(decode.string, decode.dynamic)
  use parsed <- decode.then(entries)
  decode.success(dict.keys(parsed))
}
