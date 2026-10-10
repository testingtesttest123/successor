//// Installed, disabled until selected; selection never creates an identity.

import albedo/daemon/store
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/personality/migrations/schema
import albedo/harness/extensions/personality/projection
import albedo/harness/extensions/personality/service
import albedo/harness/extensions/personality/tools

pub fn extension() -> extension.Extension {
  extension.Extension(
    "personality",
    "One explicitly bound durable identity across owner sessions. Human setup is required.",
    [],
    [
      extension.ToolPlugin(tools.instructions, tools.tools(), [], []),
      extension.MigrationPlugin(extension.SchemaMigration(schema.apply)),
      extension.ServicePlugin(extension.Service(
        service.admission,
        service.handle,
      )),
      extension.CommandPlugin([
        command.resource(
          "/personality",
          "Inspect and explicitly set up this session's identity",
          [],
        ),
      ]),
      extension.ClientPlugin(service.clients()),
      extension.RequestContextPlugin(projection.prepare),
      extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["personality_session"], session)
      }),
    ],
    extension.no_initialise,
  )
}
