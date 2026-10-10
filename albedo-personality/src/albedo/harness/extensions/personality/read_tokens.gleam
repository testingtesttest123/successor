//// Internal local signing state for read-only continuation/reference integrity.
//// Initialization alone creates the key. Reads never repair or rotate it.

import albedo/daemon/store
import albedo/harness/extensions/personality/types as p
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

pub fn initialise(db: sqlight.Connection) -> Result(Nil, String) {
  use versioned <- result.try(store.one(
    db,
    "SELECT COUNT(*) FROM pragma_table_info('personality_capacity') WHERE name='read_token_version'",
    [],
    decode.field(0, decode.int, decode.success),
    "personality read state unavailable",
  ))
  use exists <- result.try(store.one(
    db,
    "SELECT COUNT(*) FROM main.sqlite_master WHERE name='personality_read_key'",
    [],
    decode.field(0, decode.int, decode.success),
    "personality read state unavailable",
  ))
  use _ <- result.try(case exists, versioned {
    0, 0 -> {
      use _ <- result.try(store.exec(
        db,
        "CREATE TABLE personality_read_key(singleton INTEGER PRIMARY KEY CHECK(singleton=1),secret TEXT NOT NULL,fingerprint TEXT NOT NULL)",
      ))
      let secret = crypto.strong_random_bytes(32) |> bit_array.base16_encode
      store.run(
        db,
        "INSERT INTO personality_read_key(singleton,secret,fingerprint) VALUES(1,?,?)",
        [sqlight.text(secret), sqlight.text(fingerprint(secret))],
      )
    }
    0, _ ->
      Error("personality read signing state missing; restore original state")
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(
    key(db)
    |> result.replace_error(
      "personality read signing state invalid; restore original state",
    ),
  )
  store.add_columns(db, "personality_capacity", [
    #(
      "read_token_version",
      "INTEGER NOT NULL DEFAULT 1 CHECK(read_token_version=1)",
    ),
  ])
}

pub fn key(db: sqlight.Connection) -> Result(String, p.DomainError) {
  use saved <- result.try(
    store.one(
      db,
      "SELECT secret,fingerprint FROM main.personality_read_key WHERE singleton=1 AND (SELECT COUNT(*) FROM main.personality_read_key)=1",
      [],
      {
        use secret <- decode.field(0, decode.string)
        use fingerprint <- decode.field(1, decode.string)
        decode.success(#(secret, fingerprint))
      },
      "personality read signing state unavailable",
    )
    |> result.replace_error(p.Storage(
      "personality read signing state unavailable",
    )),
  )
  let key = saved.0
  case
    string.byte_size(key) == 64 && fingerprint(key) == saved.1,
    bit_array.base16_decode(key)
  {
    True, Ok(bytes) -> {
      case bit_array.byte_size(bytes) == 32 {
        True -> Ok(key)
        False -> Error(p.Storage("personality read signing state invalid"))
      }
    }
    _, _ -> Error(p.Storage("personality read signing state invalid"))
  }
}

/// Domain-separated 128-bit HMAC. Compact exact source IDs remain <=128 bytes,
/// including four maximum signed-SQLite integers, full SHA-256, and attribution.
pub fn proof(key: String, scope: String, state: String) -> String {
  let mac =
    crypto.hmac(
      bit_array.from_string("personality-source-v1\n" <> scope <> "\n" <> state),
      crypto.Sha256,
      bit_array.from_string(key),
    )
  let assert Ok(mac) = bit_array.slice(mac, 0, 16)
  bit_array.base64_url_encode(mac, False)
}

pub fn authentic(
  key: String,
  scope: String,
  state: String,
  mac: String,
) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(proof(key, scope, state)),
    bit_array.from_string(mac),
  )
}

fn fingerprint(key: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(key))
  |> bit_array.base16_encode
}
