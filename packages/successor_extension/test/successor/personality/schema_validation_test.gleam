//// Catches schema coercion/repair and omitted v2 table/column checks through a
//// real SQLite connection. Slice 1 has no installed daemon or initializer.

import albedo/daemon/store
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/string
import gleeunit/should
import sqlight
import successor/personality/schema_validation

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

type Snapshot {
  Snapshot(
    schema: List(Dynamic),
    rows: List(#(String, List(Dynamic))),
    facts: List(Dynamic),
  )
}

fn fixture() -> String {
  let assert Ok(bytes) = read_file("test/fixtures/schema-v2.sql")
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn quoted(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

fn tables(db: sqlight.Connection) -> List(String) {
  let assert Ok(names) =
    store.rows(
      db,
      "SELECT name FROM main.sqlite_master WHERE type='table' ORDER BY name",
      [],
      decode.field(0, decode.string, decode.success),
    )
  names
}

fn snapshot(db: sqlight.Connection) -> Snapshot {
  let assert Ok(schema) =
    store.rows(
      db,
      "SELECT type,name,tbl_name,rootpage,sql FROM main.sqlite_master ORDER BY type,name",
      [],
      decode.dynamic,
    )
  let rows =
    list.map(tables(db), fn(name) {
      let assert Ok(data) =
        store.rows(
          db,
          "SELECT * FROM " <> quoted(name) <> " ORDER BY rowid",
          [],
          decode.dynamic,
        )
      #(name, data)
    })
  let assert Ok(facts) =
    store.rows(
      db,
      "SELECT total_changes(),(SELECT schema_version FROM pragma_schema_version),(SELECT user_version FROM pragma_user_version)",
      [],
      decode.dynamic,
    )
  Snapshot(schema, rows, facts)
}

fn check(sql: String, expected_ok: Bool) {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = store.exec(db, sql)
  let before = snapshot(db)
  let outcome = schema_validation.validate(db)
  let after = snapshot(db)
  // Close before assertions, so even the expected RED cases release SQLite.
  let assert Ok(_) = sqlight.close(db)
  after |> should.equal(before)
  case expected_ok {
    True -> outcome |> should.equal(Ok(Nil))
    False -> {
      let _ = outcome |> should.be_error
      Nil
    }
  }
}

pub fn healthy_v2_validation_leaves_all_schema_and_data_untouched_test() {
  check(fixture(), True)
}

pub fn additional_unrelated_schema_is_ignored_without_mutation_test() {
  check(
    fixture()
      <> "CREATE TABLE extra(value TEXT); INSERT INTO extra VALUES('keep');",
    True,
  )
}

pub fn missing_or_unsupported_v2_markers_refuse_without_mutation_test() {
  check(fixture() <> "DELETE FROM personality_meta;", False)
  check(fixture() <> "UPDATE personality_meta SET singleton=2;", False)
  check(fixture() <> "UPDATE personality_meta SET version=1;", False)
  check(fixture() <> "UPDATE personality_meta SET version=3;", False)
  check(
    fixture() <> "UPDATE personality_meta SET version='not an integer';",
    False,
  )
}

pub fn legacy_and_empty_stores_are_not_initialized_or_repaired_test() {
  check(
    "CREATE TABLE legacy_personality(document TEXT); INSERT INTO legacy_personality VALUES('retain');",
    False,
  )
  check(
    "CREATE TABLE unrelated_sentinel(payload TEXT); INSERT INTO unrelated_sentinel VALUES('retain');",
    False,
  )
  check("", False)
}

pub fn every_required_v2_table_is_checked_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = store.exec(db, fixture())
  let required =
    tables(db)
    |> list.filter(fn(name) { string.starts_with(name, "personality_") })
  let assert Ok(_) = sqlight.close(db)
  list.length(required) |> should.equal(8)
  list.each(required, fn(name) {
    check(fixture() <> "DROP TABLE " <> quoted(name) <> ";", False)
  })
}

pub fn compatible_views_cannot_replace_any_required_real_table_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = store.exec(db, fixture())
  let required =
    tables(db)
    |> list.filter(fn(name) { string.starts_with(name, "personality_") })
  let assert Ok(_) = sqlight.close(db)
  list.each(required, fn(name) {
    let retained = "retained_" <> name
    check(
      fixture()
        <> "ALTER TABLE "
        <> quoted(name)
        <> " RENAME TO "
        <> quoted(retained)
        <> "; CREATE VIEW "
        <> quoted(name)
        <> " AS SELECT * FROM "
        <> quoted(retained)
        <> ";",
      False,
    )
  })
}

pub fn every_required_column_is_checked_without_schema_repair_test() {
  let assert Ok(db) = sqlight.open(":memory:")
  let assert Ok(_) = store.exec(db, fixture())
  let required =
    tables(db)
    |> list.filter(fn(name) { string.starts_with(name, "personality_") })
  let columns =
    list.flat_map(required, fn(name) {
      let assert Ok(fields) =
        store.rows(
          db,
          "PRAGMA table_info(" <> quoted(name) <> ")",
          [],
          decode.field(1, decode.string, decode.success),
        )
      list.map(fields, fn(field) { #(name, field) })
    })
  let assert Ok(_) = sqlight.close(db)
  // Fixture-derived matrix, independent of the validator's private constants.
  list.each(columns, fn(pair) {
    check(
      fixture()
        <> "ALTER TABLE "
        <> quoted(pair.0)
        <> " DROP COLUMN "
        <> quoted(pair.1)
        <> ";",
      False,
    )
  })
}
