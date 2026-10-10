//// Cross-extension invariant: failed bundles must not contribute request-time
//// callbacks. Arbitrary synthetic bundles cannot be installed by daemon HTTP.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/request_context
import gleam/list
import gleeunit/should

pub fn callbacks_are_scoped_to_whole_loaded_active_bundles_test() -> Nil {
  let assert Ok(ledger) = store.start(":memory:", "")
  let read =
    extension.RequestContextPlugin(fn(_) {
      Ok(request_context.empty("readable"))
    })
  let active =
    extension.Extension("active", "", [], [read], extension.no_initialise)
  let broken =
    extension.Extension(
      "broken",
      "",
      [],
      [read, extension.ManagedPlugin(fn(_, _, _) { Error("fixture failure") })],
      extension.no_initialise,
    )
  let composed = composition.compose([active, broken], ledger, "owner", "/tmp")
  composition.request_context(composed) |> list.length |> should.equal(1)
  composition.extensions(composed)
  |> list.map(fn(item) { item.name })
  |> should.equal(["active"])
  composition.close(composed)
  store.close(ledger)
}
