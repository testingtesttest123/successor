//// Product composition: stock Albedo with optional external live identity.

import albedo/daemon/server
import albedo/daemon/storage_cli
import albedo/harness/extensions
import gleam/list
import successor/personality/extension as personality

pub fn composition() -> extensions.Config {
  let stock = extensions.defaults()
  extensions.Config(
    list.append(stock.extensions, [personality.extension()]),
    stock.default_enabled,
  )
}

pub fn main() -> Nil {
  case storage_cli.arguments() {
    [] -> server.main_with_config(composition())
    arguments -> storage_cli.main(arguments)
  }
}
