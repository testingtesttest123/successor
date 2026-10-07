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
  one durable deployment identity, provider-attempt receipts (intent before
  call; completed/failed/aborted; usage only on success).
- [x] **1C — configuration.** Strict canonical schema (`successor/recipe`)
  with effective-value provenance (Defaults vs Recipe), plus a compatibility
  reader for the reference-recipe oracle subset: mock provider selection,
  mock settings, and module toggles recorded as named accepted-but-not-
  modeled warnings. Unknown agent fields and unsupported providers are
  errors, never silent projections.
- [x] **1D — provider boundary.** Canonical messages/content blocks, tools,
  usage, per-attempt identity, opaque continuation capsule bound to a
  compatibility domain (never inspected by the runtime), typed failures
  incl. `Aborted`. Deterministic mock adapter (echo mode, fixed usage
  estimate, no network/clock).
- [x] **1E — ContextPolicy.** Passthrough plan over the record tail:
  selected records, message projection, deterministic token estimate,
  sha256 projection hash (stale-plan detection input).
- [x] **1F — walking scenario.** AgentRuntime (generation-guarded
  activations; async provider dispatch in its own process; stale completions
  rejected and never settled) + SessionRuntime (owns its agent; forwards
  turn events) under a keyed supervisor (supervisor → session → agent).
  Sessions re-register after registry restart without losing their live
  runtime. Provider workers are cancelled on owner death via an isolated
  guardian, while adapter crashes remain contained.
  Operator surface: start_session / open_session / submit / turn events.
  **The 23.1F gate is met and tested:** user turn → durable user record →
  plan → provider response → durable assistant record + attempt receipt →
  restart → identical canonical history; stale completion settles nothing;
  second turn appends with branch-local sequences.
  Explicit reopen by durable session ID selects the persisted branch and
  current host config, preserves history and receipts, and does not replay
  provider work. Concurrent/repeated opens share one live owner even during
  registry loss. A restarted host can reopen that same session and append
  another turn without creating a new session or branch.

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
gleam test    # 64 tests: 1A gate, 1B durable contracts, 1C provenance/compat,
              # provider/context units, 1F walking/stale gates, review regressions,
              # real supervised lifecycle/recovery tests, and durable-session reopen tests
gleam run     # (no main yet — the host binary arrives with the operator wire surface)
python3 -m unittest discover -s conformance -p 'test_*.py' -v  # test bridge plumbing
```

Prerequisites: Gleam 1.19+, Erlang/OTP 27 (full distribution incl. `erlang-dev`
for the esqlite NIF), rebar3.

## Shared conformance bridge

`gleam run -m conformance_host` exposes a **test-only** JSONL adapter used by
Home's shared `provider/mock-text-turn` and
`storage/restart-after-committed-turn` scenarios. The adapter uses the public
application/session APIs and read-only SQLite snapshots. Each host start is a
fresh BEAM process; reopening uses the exact previously observed durable
session ID. See [the bridge contract](conformance/README.md).

This is bounded acceptance of **2 of 13** Home scenarios, not full parity.
Reference time/IPC context injection, mock echo selection, Chronicle bookkeeping,
and diagnostic/UI projections differ deliberately. Provider request, model,
system-prompt, and tool-surface parity are not established by this slice.
Home owns the shared scenarios, immutable reference baselines, explicit delta
rules, corpus/schema validation, and fresh-reference execution gate. The local
protocol tests above only check adapter plumbing; they do not replace that gate.
