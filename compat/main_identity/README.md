# Main identity compatibility fixture

This fixture exercises the bounded external `personality` extension against the
current adapted host. It does not install the extension into stock defaults.

The package tests use real SQLite and the host store actor for fresh v2 setup,
idempotent setup receipts, expected document revisions, immutable revision reads,
explicit owner binding, atomic persistent requirements, and full mandatory context.
Existing v2 state is validated without migration or requirement backfill. Delegate
rows are retained as data but cannot capture or mutate the main identity.

Run the package suite using the isolated toolchain and an isolated HOME:

```
cd packages/successor_extension
gleam test
gleam check
gleam format --check src test
```

Host request-context and lifecycle fixtures additionally exercise provider-entry
refusals, retained retry capture, removal/quarantine, child/fork/rewind rejection,
and restored warming. Passing package tests alone does not qualify those paths.
No real provider or personal credentials are used by this fixture.
