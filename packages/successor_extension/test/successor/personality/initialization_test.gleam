//// Deterministic startup corruption probes use real SQLite, including a view
//// collision and existing data. HTTP cannot install damaged schemas on demand.

import albedo/daemon/store
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleeunit/should
import sqlight
import successor/personality/schema
import successor/personality/schema_validation

fn snapshot(db: sqlight.Connection) -> #(List(Dynamic), List(Dynamic)) {
  let assert Ok(objects) =
    store.rows(
      db,
      "SELECT type,name,tbl_name,rootpage,sql FROM main.sqlite_master ORDER BY type,name",
      [],
      decode.dynamic,
    )
  let assert Ok(facts) =
    store.rows(
      db,
      "SELECT total_changes(),(SELECT schema_version FROM pragma_schema_version),(SELECT user_version FROM pragma_user_version)",
      [],
      decode.dynamic,
    )
  #(objects, facts)
}

pub fn fresh_initialization_creates_only_owned_v2_tables_once_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    store.exec(
      db,
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('keep');",
    )
  schema.apply(db) |> should.equal(Ok(Nil))
  schema_validation.validate(db) |> should.equal(Ok(Nil))
  let assert Ok([8]) =
    store.rows(
      db,
      "SELECT COUNT(*) FROM main.sqlite_master WHERE type='table' AND name GLOB 'personality_*'",
      [],
      decode.field(0, decode.int, decode.success),
    )
  let assert Ok(["keep"]) =
    store.rows(
      db,
      "SELECT value FROM sentinel",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let before = snapshot(db)
  schema.apply(db) |> should.equal(Ok(Nil))
  snapshot(db) |> should.equal(before)
  let assert Ok(_) = sqlight.close(db)
}

pub fn similarly_named_unrelated_table_is_not_owned_state_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) =
    store.exec(
      db,
      "CREATE TABLE personalityXunrelated(value TEXT); INSERT INTO personalityXunrelated VALUES('retain');",
    )
  schema.apply(db) |> should.equal(Ok(Nil))
  let assert Ok(["retain"]) =
    store.rows(
      db,
      "SELECT value FROM personalityXunrelated",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert Ok(_) = sqlight.close(db)
}

fn refuse_untouched(sql: String) -> Nil {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = store.exec(db, sql)
  let before = snapshot(db)
  schema.apply(db) |> should.be_error
  snapshot(db) |> should.equal(before)
  let assert Ok(_) = sqlight.close(db)
  Nil
}

pub fn existing_partial_or_view_state_is_never_completed_or_replaced_test() {
  refuse_untouched(
    "CREATE TABLE personality_persona(id TEXT); INSERT INTO personality_persona VALUES('retain');",
  )
  refuse_untouched(
    "CREATE TABLE retained_identity(id TEXT); INSERT INTO retained_identity VALUES('retain'); CREATE VIEW personality_meta AS SELECT 1 AS singleton,2 AS version;",
  )
  refuse_untouched(
    "CREATE TABLE personality_meta(singleton INTEGER,version INTEGER); INSERT INTO personality_meta VALUES(1,2);",
  )
}

pub fn damaged_existing_v2_refuses_without_schema_or_data_repair_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = schema.apply(db)
  let assert Ok(_) =
    store.exec(
      db,
      "INSERT INTO personality_persona VALUES('keep','retained',1,1); INSERT INTO personality_revision VALUES('keep',1,'retained document','user','','initial',42); ALTER TABLE personality_revision RENAME TO retained_revision;",
    )
  let before = snapshot(db)
  schema.apply(db) |> should.be_error
  snapshot(db) |> should.equal(before)
  let assert Ok(["retained document"]) =
    store.rows(
      db,
      "SELECT document FROM retained_revision",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert Ok(_) = sqlight.close(db)
}
