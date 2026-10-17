# Bounded main-identity daemon acceptance

These tests run the actual product daemon through Albedo's existing HTTP harness with local scripted Responses and Chat Completions providers. Each protocol has its own concrete suite and each test owns a separate daemon home. No real-provider credentials are required.

Coverage includes explicit setup and retry receipts, revision CAS and edit receipts, restart persistence, one capture across gateway retry, next-request refresh, busy binding refusal, unbind retaining identity selection, missing requirements/tables, quarantine, deselection, complete declaration removal, ordinary unselected sessions, daemon-token authorization, and refused child/fork/rewind (including requested summaries) before new sessions or provider calls. Compaction must carry the mandatory identity or refuse explicitly. Global defaults do not override an explicit per-session selection.

The bounded suite intentionally excludes delegate inheritance, automatic binding, additional identity creation, default-management routes, and background memory. Refusal observations use a new persisted failed input turn or an explicitly blocked pending input with a diagnostic, followed by an unchanged scripted-provider request count.

From `apps/successor_daemon`, build with `gleam build`. Then run:

```sh
python3 ../../compat/live_identity/snapshot.py ../.. /absolute/new-snapshot /absolute/built-cli
```

The output copies compiled packages and all `priv` assets instead of linking back to source. It includes product and stock entrypoints, copied source and acceptance-test bytes, source hashes, asset hashes, and the host base commit. The stock entrypoint omits the personality declaration while retaining the same host implementation.

For immutable acceptance, run `python3 /absolute/new-snapshot/source/acceptance/run.py` with these variables:

- `ALBEDO_TEST_DAEMON`: snapshot `successor-daemon`.
- `ALBEDO_STOCK_TEST_DAEMON`: snapshot `stock-daemon`.
- `ALBEDO_TEST_CLI`: snapshot `test-cli`.
- `SUCCESSOR_TEST_HOST`: snapshot `source/host` for the immutable harness.
- `SUCCESSOR_TEST_EVIDENCE`: a new external directory for retained diagnostics.
- `HOME`, `ALBEDO_HOME`, and `ALBEDO_TEST_TMP`: isolated test locations.

Use an allowlisted environment without provider authentication variables. The runner sets `ALBEDO_NO_BROWSER=1` and uses a Linux subreaper to reap orphaned test descendants; assertions and timeouts remain unchanged. The unchanged host harness owns daemon shutdown. Test database snapshots contain only local synthetic test state.

An optional first argument selects an absolute test file or `file.py:Class.test_method`. Run pinned Ruff 0.16.10 lint/format and ty 0.0.85 from this directory; its ty configuration supplies the host harness search paths.
