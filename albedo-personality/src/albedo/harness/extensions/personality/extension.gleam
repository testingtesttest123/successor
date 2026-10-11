//// Opt-in living identity with native LCM, ordinary tools and human setup.

import albedo/daemon/store
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/projection
import albedo/harness/extensions/personality/service
import albedo/harness/extensions/personality/tools
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "personality",
    "Living identity document and native LCM memory",
    ["lcm-memory"],
    [
      extension.ToolPlugin(tools.instructions, tools.tools(), [], []),
      extension.CompactionPlugin(lcm.strategy("personality")),
      extension.MigrationPlugin(extension.SchemaMigration(schema.apply)),
      extension.ServicePlugin(extension.Service(
        service.admission,
        service.handle,
      )),
      extension.CommandPlugin([
        command.resource(
          "/personality",
          "Read, edit or set up this identity",
          [],
        ),
      ]),
      extension.ClientPlugin(service.clients()),
      extension.RequestContextPlugin(projection.prepare, True),
      // Managed preparation runs before transcript admission. Projection stays read-only.
      extension.ManagedPlugin(fn(db, session, _) {
        use _ <- result.map(
          ledger.resolve_fresh_binding(db, session)
          |> result.map_error(ledger.message),
        )
        extension.empty()
      }),
      extension.CleanPlugin(graph.forget_session),
      extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["personality_session"], session)
      }),
    ],
    extension.no_initialise,
  )
}
