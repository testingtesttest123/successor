# Successor extension: slice 1

This package extracts pure personality types, bounded document operations and
read-only v2 schema validation from Successor's frozen reference commit
`fb1f4dc4099d915ee926139fc49a5c55bb63eac4`. It depends on unpatched Albedo
`e9df547f67f6819ebcd217649be326e53111027c`; the Gleam-generated manifest locks
the resolved consumer dependencies.

The production surface is three modules:

- `successor/personality/types`: data types only.
- `successor/personality/domain`: existing UTF-8 byte limits, substring editing,
  hash identity, copied prefixes and byte-offset paging.
- `successor/personality/schema_validation`: existing v2 marker, real-table and
  required-column validation through Albedo's public store helpers.

Validation runs SELECT statements only. It does not initialize, migrate, repair
or bind a store. The test SQL fixture explicitly constructs disposable SQLite
databases; no `apply()` implementation is copied into production or tests.

From this directory, run:

```sh
gleam deps download
gleam test
gleam check
gleam format --check src test
python3 ../../scripts/verify_extension_slice1.py
```

The boundary verifier checks the full downloaded host checkout against its
pinned Git tree and checks extraction identity against the immutable reference.
The package tests exercise the real public functions and SQLite connections.
They are isolated library tests because this slice has no installed daemon
surface. The allocation observer traces only the calling test process and is
test-only. Missing tables, compatible views and every required column are tested
with complete schema/data snapshots before and after validation.

This is a library checkpoint. It does not install personality behavior, context
selection, bindings, agents, kernel/background-memory integration or host hooks.
Historical Successor qualification remains **FAILED/OPEN**; package tests do not
establish parity or runtime readiness. No broader host/full aggregate gate is
claimed here.

Later gates remain deferred: P2 final-request receipt acceptance needs separate
justification and review while the carried selector is unwired. Before P1
approval, forced compaction, tool/steering continuations, static prompt pins and
selected-but-quarantined admission require capture/retry/budget coverage. Any
additional source-index or invalidation hook is a separately reviewed boundary;
triggers and catch-up are not authorized by this slice.

Source provenance is recorded in `provenance.json`. Albedo's pinned upstream
license and attribution are preserved in `UPSTREAM-LICENSE.txt`. This extraction
is copied/adapted source, not a clean-room implementation, and does not introduce
a repository-wide license grant.
