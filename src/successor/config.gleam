//// Typed host configuration (chapter 23.1C subset for the skeleton).
////
//// The normal schema is strict: no permissive legacy validation here.
//// Effective-value provenance and a compatibility reader for the reference
//// recipes arrive with the rest of 1C.

import successor/ids

/// Bumped only by a deliberate, tested migration.
pub const schema_version = 1

/// Where the operator surface binds. Port 0 lets the OS assign one; the
/// bound port is reported through the operator surface once listening.
pub type OperatorBinding {
  OperatorBinding(host: String, port: Int)
}

pub type ProviderConfig {
  /// Deterministic offline provider (chapter 22 fixture surface).
  MockProvider(id: String, echo_mode: Bool, default_response: String)
}

pub type Config {
  Config(
    /// Root directory for durable state (SQLite store, blobs).
    data_dir: String,
    operator: OperatorBinding,
    /// Zero configured providers must be a valid, cleanly startable state
    /// (chapter 23.1A gate).
    providers: List(ProviderConfig),
  )
}

pub fn default(data_dir data_dir: String) -> Config {
  Config(
    data_dir: data_dir,
    operator: OperatorBinding(host: "127.0.0.1", port: 0),
    providers: [],
  )
}

/// Validate the invariants the rest of the host relies on. Strict: unknown
/// or nonsensical values are errors, never silently projected away
/// (chapter 20.3 class C).
pub fn validate(config: Config) -> Result(Nil, String) {
  case config.data_dir {
    "" -> Error("config: data_dir must not be empty")
    _ -> {
      case config.operator.port >= 0 && config.operator.port <= 65_535 {
        False -> Error("config: operator.port out of range")
        True -> {
          case check_provider_ids(config.providers, []) {
            Ok(_) -> Ok(Nil)
            Error(e) -> Error(e)
          }
        }
      }
    }
  }
}

fn check_provider_ids(
  providers: List(ProviderConfig),
  seen: List(String),
) -> Result(Nil, String) {
  case providers {
    [] -> Ok(Nil)
    [MockProvider(id, ..), ..rest] ->
      case id == "" || list_contains(seen, id) {
        True ->
          Error("config: provider ids must be non-empty and unique: " <> id)
        False -> check_provider_ids(rest, [id, ..seen])
      }
  }
}

fn list_contains(haystack: List(String), needle: String) -> Bool {
  case haystack {
    [] -> False
    [head, ..rest] ->
      case head == needle {
        True -> True
        False -> list_contains(rest, needle)
      }
  }
}

/// Identity of the single deployment this host manages (chapter 20.8: one
/// deployment). Durable: created on first boot, reused afterwards.
pub type DeploymentIdentity {
  DeploymentIdentity(id: ids.DeploymentId)
}
