//// Explicitly installed main identity, independent of compaction strategy.

import albedo/harness/extension
import successor/personality/bindings
import successor/personality/projection
import successor/personality/schema
import successor/personality/service
import successor/personality/tools

pub fn extension() -> extension.Extension {
  extension.Extension(
    "personality",
    "Durable main identity with explicit authenticated setup",
    [],
    [
      extension.ToolPlugin(tools.instructions, tools.tools(), [], []),
      extension.MigrationPlugin(extension.SchemaMigration(schema.apply)),
      extension.ServicePlugin(extension.Service(
        service.admission,
        service.handle,
      )),
      extension.RequestContextPlugin(projection.prepare, True),
      extension.CleanPlugin(bindings.forget_session_in),
    ],
    extension.no_initialise,
  )
}
