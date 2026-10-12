//// Test consumer of the generic P0 startup API. No Successor dependency.

import albedo/daemon/server
import albedo/daemon/storage_cli
import albedo/harness/extensions
import boundary_fixture/service
import gleam/list

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String

// Declaration construction only: install and service effects are callbacks.
fn composition(mode: String) -> extensions.Config {
  let stock = extensions.defaults()
  case mode {
    "defaults" -> stock
    "enabled" | "disabled" | "quarantined" ->
      extensions.Config(
        list.append(stock.extensions, [service.extension(mode == "quarantined")]),
        case mode {
          "disabled" -> stock.default_enabled
          _ -> list.append(stock.default_enabled, ["boundary-fixture"])
        },
      )
    _ -> panic as "invalid test composition mode"
  }
}

pub fn main() -> Nil {
  case storage_cli.arguments() {
    [] ->
      case env("P0_FIXTURE_MODE") {
        "stock" -> server.main()
        mode -> server.main_with_config(composition(mode))
      }
    arguments -> storage_cli.main(arguments)
  }
}
