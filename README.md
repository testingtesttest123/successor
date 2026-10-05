# successor

Clean-room reimplementation of the useful Connectome model on **Gleam/BEAM**
(chapter 20.2), built against the executable oracle in
[`testingtesttest123/home/conformance`](https://github.com/testingtesttest123/home).
Behavior contracts come from the observed pinned reference, not from its
source structure (chapter 23.1 build rule 2).

## Status: Phase 1 in progress (chapter 23)

- [x] **1A — application skeleton.** Supervision root owned by a keeper
  process (a crashing tree cannot take the caller with it; `stop` is
  gen_server ordered termination). Tree slots: DeploymentStore worker,
  Operator worker, Session supervisor (awaiting 1F), Provider supervisor
  (awaiting 1D). Starts and stops cleanly with zero configured providers.
- [x] **1B — durable store.** SQLite via sqlight: transactional session
  catalog (session + `main` branch commit atomically), append-only canonical
  record table with branch-local sequences, branch graph with head
  referential integrity, `schema_version` gate (mismatch refuses to open),
  one durable deployment identity. Namespaced-state, provider-attempt,
  effect-receipt and blob tables exist for 1C/1D.
- [ ] 1C — configuration provenance + compatibility reader for the minimum
  oracle recipe subset.
- [ ] 1D — provider boundary (canonical messages, tools, usage, attempt id,
  continuation capsule, cancellation, typed failures) + deterministic mock
  adapter.
- [ ] 1E — ContextPolicy behavior with the passthrough implementation.
- [ ] 1F — walking scenario: operator message → durable user record →
  activation → passthrough ContextPlan → provider request/response → durable
  receipts → idle → restart → same canonical history.

## Layout

```text
src/successor/
  ids.gleam        chapter-20.7 opaque identity ontology + generators
  config.gleam     strict typed configuration (schema v1)
  logging.gleam    structured key=value events
  db.gleam         SQLite storage layer (pure functions over a connection)
  store.gleam      DeploymentStore actor — single durable writer
  operator.gleam   minimal operator authority (health; wire protocol in 1F)
  app.gleam        supervision root + lifecycle
```

## Development

```bash
gleam test    # 24 tests: 1A gate + 1B durable contracts
gleam run     # (no main yet — the host binary arrives with the operator wire surface)
```

Prerequisites: Gleam 1.19+, Erlang/OTP 27 (full distribution incl. `erlang-dev`
for the esqlite NIF), rebar3.
