//// Independent test extension: effects happen during install/service only.

import albedo/daemon/store
import albedo/harness/extension
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import mist

pub fn extension(fail_install: Bool) -> extension.Extension {
  extension.Extension(
    name: "boundary-fixture",
    description: "independent P0 acceptance fixture",
    requires: [],
    plugins: [
      extension.ServicePlugin(
        extension.Service(
          admission: fn(_, _) {
            extension.Admission(extension.DaemonToken, 1024)
          },
          handle: fn(daemon, path, _, _) {
            case path {
              ["ping"] -> {
                let assert Ok([starts]) =
                  store.read(
                    daemon.ledger,
                    "SELECT starts FROM boundary_fixture WHERE singleton=1",
                    [],
                    decode.field(0, decode.int, decode.success),
                  )
                response.new(200)
                |> response.set_header("content-type", "application/json")
                |> response.set_body(
                  mist.Bytes(bytes_tree.from_string(
                    "{\"pong\":true,\"starts\":" <> int.to_string(starts) <> "}",
                  )),
                )
              }
              _ ->
                response.new(404)
                |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
            }
          },
        ),
      ),
    ],
    initialise: fn(ledger) {
      case fail_install {
        True -> Error("intentional fixture install failure")
        False ->
          store.query(ledger, fn(db) {
            store.exec(
              db,
              "CREATE TABLE IF NOT EXISTS boundary_fixture(singleton INTEGER PRIMARY KEY,starts INTEGER NOT NULL); INSERT OR IGNORE INTO boundary_fixture VALUES(1,0); UPDATE boundary_fixture SET starts=starts+1 WHERE singleton=1;",
            )
          })
      }
    },
  )
}
