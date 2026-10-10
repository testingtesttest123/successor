//// Cross-capability invariant: an absent or unreadable core guard must fail
//// closed independently of any extension. The daemon API cannot uninstall a
//// core table or install arbitrary capability validators during a request.

import albedo/daemon/session_requirements
import albedo/daemon/store
import gleam/dynamic/decode
import gleam/result
import gleeunit/should

pub fn missing_core_admission_is_never_no_requirements_test() -> Nil {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions(id) VALUES('owner'),('ordinary')",
    )
  session_requirements.check(ledger, "ordinary", [])
  |> result.is_error
  |> should.be_true
  let assert Ok(_) = session_requirements.initialise(ledger)
  session_requirements.check(ledger, "ordinary", []) |> should.equal(Ok(Nil))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      session_requirements.set_in(db, "owner", "personality", True)
    })
  session_requirements.check(ledger, "owner", [])
  |> result.is_error
  |> should.be_true
  session_requirements.check(ledger, "owner", ["personality"])
  |> should.equal(Ok(Nil))
  let assert Ok(_) =
    store.query(ledger, store.exec(
      _,
      "DROP TABLE session_requirements; CREATE VIEW session_requirements AS SELECT 'unreadable' AS wrong",
    ))
  session_requirements.check(ledger, "ordinary", [])
  |> result.is_error
  |> should.be_true
  store.close(ledger)
}

pub fn failed_binding_transaction_rolls_back_requirement_test() -> Nil {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions(id) VALUES('owner')",
    )
  let assert Ok(_) = session_requirements.initialise(ledger)
  let failed =
    store.query(ledger, fn(db) {
      store.transaction(db, fn() {
        use _ <- result.try(session_requirements.set_in(
          db,
          "owner",
          "personality",
          True,
        ))
        Error("binding failed")
      })
    })
  failed |> should.equal(Error("binding failed"))
  session_requirements.check(ledger, "owner", []) |> should.equal(Ok(Nil))
  store.close(ledger)
}

pub fn compatible_empty_view_cannot_replace_required_core_table_test() -> Nil {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions(id) VALUES('owner')",
    )
  let assert Ok(_) = session_requirements.initialise(ledger)
  let assert Ok(_) =
    store.query(ledger, session_requirements.set_in(
      _,
      "owner",
      "personality",
      True,
    ))
  session_requirements.check(ledger, "owner", [])
  |> result.is_error
  |> should.be_true
  let assert Ok(_) =
    store.query(ledger, store.exec(
      _,
      "DROP TABLE session_requirements; CREATE VIEW session_requirements AS SELECT '' AS session,'' AS capability WHERE 0",
    ))
  session_requirements.check(ledger, "owner", [])
  |> result.is_error
  |> should.be_true
  store.close(ledger)
}

pub fn fresh_admission_migration_refuses_a_compatible_view_test() -> Nil {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); CREATE TABLE migrations(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL); CREATE VIEW session_requirements AS SELECT '' AS session,'' AS capability WHERE 0",
    )
  session_requirements.initialise(ledger) |> result.is_error |> should.be_true
  let assert Ok([]) =
    store.read(
      ledger,
      "SELECT name FROM migrations WHERE name='session_requirements'",
      [],
      decode.dynamic,
    )
  let assert Ok([_]) =
    store.read(
      ledger,
      "SELECT name FROM sqlite_master WHERE name='session_requirements' AND type='view'",
      [],
      decode.dynamic,
    )
  store.close(ledger)
}
