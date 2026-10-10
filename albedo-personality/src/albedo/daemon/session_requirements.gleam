//// Core-owned durable capability admission, independent of extension storage.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(store.exec(
        db,
        "CREATE TABLE IF NOT EXISTS migrations(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL)",
      ))
      use applied <- result.try(store.rows(
        db,
        "SELECT name FROM migrations WHERE name='session_requirements'",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      use present <- result.try(store.rows(
        db,
        "SELECT name FROM main.sqlite_master WHERE name='session_requirements' AND type='table'",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      use _ <- result.try(case applied, present {
        [_], [] ->
          Error(
            "session admission state is missing after migration; restore the database before starting",
          )
        [], _ ->
          store.exec(
            db,
            "CREATE TABLE IF NOT EXISTS session_requirements(session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,capability TEXT NOT NULL CHECK(length(capability)>0),PRIMARY KEY(session,capability));",
          )
        _, _ -> Ok(Nil)
      })
      use _ <- result.try(require_table_in(db))
      use _ <- result.try(
        store.run(
          db,
          "SELECT session,capability FROM main.session_requirements LIMIT 0",
          [],
        )
        |> result.map_error(fn(error) {
          "session admission state is unreadable: " <> error
        }),
      )
      store.run(
        db,
        "INSERT OR IGNORE INTO migrations(name,applied_at) VALUES('session_requirements',unixepoch())",
        [],
      )
    })
  })
}

/// The caller owns the transaction that also changes its domain binding.
pub fn set_in(
  db: sqlight.Connection,
  session: String,
  capability: String,
  required: Bool,
) -> Result(Nil, String) {
  case required {
    True ->
      store.run(
        db,
        "INSERT INTO main.session_requirements(session,capability) VALUES(?,?) ON CONFLICT(session,capability) DO NOTHING",
        [sqlight.text(session), sqlight.text(capability)],
      )
    False ->
      store.run(
        db,
        "DELETE FROM main.session_requirements WHERE session=? AND capability=?",
        [sqlight.text(session), sqlight.text(capability)],
      )
  }
}

/// An unreadable or missing table is an admission failure, including for an
/// ordinary session. Never repair or infer requirements during a request.
pub fn check(
  ledger: store.Store,
  session: String,
  loaded: List(String),
) -> Result(Nil, String) {
  use required <- result.try(
    store.query(ledger, fn(db) {
      use _ <- result.try(require_table_in(db))
      store.rows(
        db,
        "SELECT capability FROM main.session_requirements WHERE session=? ORDER BY capability",
        [sqlight.text(session)],
        decode.field(0, decode.string, decode.success),
      )
    })
    |> result.map_error(fn(error) { "session admission unavailable: " <> error }),
  )
  list.try_each(required, fn(capability) {
    case list.contains(loaded, capability) {
      True -> Ok(Nil)
      False -> Error("required session capability unavailable: " <> capability)
    }
  })
}

/// A compatible view cannot replace persisted authority state. Check the
/// main-schema relation on the same store turn as creation or admission reads.
fn require_table_in(db: sqlight.Connection) -> Result(Nil, String) {
  use kind <- result.try(store.one(
    db,
    "SELECT type FROM main.sqlite_master WHERE name='session_requirements'",
    [],
    decode.field(0, decode.string, decode.success),
    "session admission table is missing",
  ))
  case kind {
    "table" -> Ok(Nil)
    _ -> Error("session admission state must be a real core table")
  }
}
