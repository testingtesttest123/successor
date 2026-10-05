import gleam/dynamic/decode
import gleam/option.{None, Some}
import sqlight

pub fn nullable_one_of_probe_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) =
    sqlight.exec("CREATE TABLE t (a INT, b TEXT)", on: conn)
  let assert Ok(_) =
    sqlight.exec("INSERT INTO t VALUES (1, NULL)", on: conn)
  let d =
    decode.one_of(
      decode.map(decode.at([0], decode.string), Some),
      or: [decode.success(None)],
    )
  let rows =
    sqlight.query("SELECT b FROM t", on: conn, with: [], expecting: d)
  let assert Ok([value]) = rows
  assert value == None
}
