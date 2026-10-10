# successor

Independent, Connectome-informed behavioral implementation on **Gleam/BEAM**,
with specifications and an executable reference oracle in
[`testingtesttest123/home/conformance`](https://github.com/testingtesttest123/home).
Reference source has been inspected; this is not a claim of legal clean-room
provenance. Albedo's coding machinery is a reuse source, not a replacement for
successor's identity and durable ownership model.

## Status: walking core + private Python coding workspaces

- [x] **1A — application skeleton.** Supervision root owned by a keeper
  process (a crashing tree cannot take the caller with it; `stop` is
  gen_server ordered termination). Tree slots: DeploymentStore, Python workspace coordinator,
  Operator, session registry/factory, and provider supervisor. Starts and stops cleanly with zero configured providers.
- [x] **1B — durable store.** SQLite via sqlight: transactional session
  catalog (session + `main` branch commit atomically), append-only canonical
  record table with branch-local sequences, branch graph with head
  referential integrity, `schema_version` gate (v1 migrates atomically to v2; future/corrupt refuses),
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

- [x] **Agent-owned Python workspaces.** Stable root AgentId per session;
  separately identified child execution workspaces; private scratch directories
  and persistent Python namespaces; durable intent before dispatch and fenced
  result receipts. Timeout/crash means unknown effects, never automatic replay.
  Close/restart retains IDs, files, source and receipts, but not Python heaps.
  This advances a narrow Python-first slice, not the entire old Phase 5 plan.

- [x] **Albedo-derived coding helpers.** Files/read/exact-edit/search, async owned
  jobs/pipelines, bounded output/spill/artifact saves, persistent top-level await.
  Independent guardians clean ordinary job groups even if the kernel blocks or
  dies; shared leases plus persisted active-job cleanup markers refuse unsafe
  replacement, including loss of the guardian itself.

**Trusted local interpreters, not sandboxes.** This is an operator/library API;
model-driven tool dispatch, full subagent inference, live providers, daemon/UI
and remote execution are not implemented yet. Publication is tracked through the coding-workspace PR.

See [workspace contract and usage](docs/python-workspaces.md),
[local test evidence](docs/python-workspaces-results.md), and
[coding-helper usage/evidence](docs/coding-helpers-results.md),
[Albedo reuse cohorts](docs/albedo-reuse.md), and
[third-party notices](THIRD_PARTY_NOTICES.md).

## Layout

```text
src/successor/
  ids.gleam        chapter-20.7 opaque identity ontology + generators
  config.gleam     strict typed configuration; storage schema v2
  logging.gleam    structured key=value events
  db.gleam         SQLite storage layer (pure functions over a connection)
  store.gleam      DeploymentStore actor — single durable writer
  operator.gleam   minimal operator authority (health; wire protocol in 1F)
  app.gleam        rest-for-one supervision root + operator/library APIs
  workspace_store.gleam  durable agent identities and fenced cell journal
  workspaces.gleam       lazy execution actors + lifecycle coordination
  python.gleam           process-owned persistent Python transport
  calls.gleam            monitored, incarnation-pinned request/ack helper
priv/python/             stdlib-only kernel, locks and adapted successor_tools/
```

## Development

```bash
ERL_FLAGS="+S 4:4" gleam test  # includes real Python/SQLite, lifecycle/reopen and conformance integration
python3 -m unittest discover -s test/python -v  # 77 tests, kernel/helpers/guardian/native acceptance
gleam run     # (no main yet — the host binary arrives with the operator wire surface)
python3 -m unittest discover -s conformance -p 'test_*.py' -v  # test bridge plumbing
```

Prerequisites: Gleam 1.19+, Erlang/OTP 27 (full distribution incl. `erlang-dev`
for the esqlite NIF), rebar3. Python execution additionally needs Python 3.10+
and a POSIX/Linux host (`env`, `/bin/kill`, process groups, `fcntl.flock`).

File search additionally requires ripgrep (`rg`) on the kernel PATH. The native
launcher intentionally uses `/usr/bin:/bin`, not the embedding user's full
PATH or credentials. Install trusted tools there, use an explicit absolute
program path, or deliberately configure `os.environ['PATH']` inside a journaled
Python cell. No implicit shell expansion or credential-store discovery occurs.
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


## Albedo personality experiment: reviewed stages 1-7 checkpoint

The separate [`albedo-personality/`](albedo-personality/) subtree contains an
Albedo-derived personal experiment. Existing Successor runtime and entrypoints
remain unchanged. Approved [design](docs/experiments/albedo-personality-design.md)
and [staged plan](docs/experiments/albedo-personality-plan.md) describe the goal.

- Original Successor base: `b950f2d831f1fa5463799fbfe50995f644be52c3`.
- Albedo source: [okami.mom/albedo](https://tangled.org/okami.mom/albedo), pinned
  baseline `47735ec493f3e3a6ac73b619495098437759e0c0`.
- Exact independently reviewed publication checkpoint:
  `94edf26046e832e6940fc27a526ed43a3e9272fb`, tracked tree
  `53822f55a18b734dd8f8caeb3c8fd8134cd6bc3b`. Complete tracked source, tests,
  required assets, license and third-party/vendored notices are exported.
  No Albedo Git history, runtime homes or active uncommitted work is imported.
- Reviewed through stage 7: identity binding/admission and revisioned edits,
  immutable request-time identity context, source-backed memory correction and
  inspection, bounded current-record recall and canonical episodic expansion,
  and persona-aware native LCM compaction. Captured identity policy and trusted
  transcript attribution accompany exact leaf ranges and selected child nodes;
  unknown/historical attribution requires source expansion. Unbound native LCM
  retains its generic prompt, chunking and accounting. Bounded inspection keeps
  attempted summary captures even when later preparation fails; it does not
  assert provider completion. Generated summaries remain derived and fallible.
  Recall revalidates authority and evidence and authenticates exact references
  and paging state. Generated local signing state lives only in the application
  database; it is not part of this source export. Typed relationships/commitments
  (stage 8), production delegation/grants (stage 9) and imports are future work.
- Reviewed OAuth sanitization and generic webhook fixture cleanup are retained.
  Antigravity sign-in/refresh and Colab sign-in require explicit runtime config;
  tokens considered fresh by Albedo remain usable without it. See
  [`robot-docs/auth.md`](albedo-personality/robot-docs/auth.md).
  The historical GitHub fixture alert remains unresolved: this cleanup does not
  dismiss alerts, validate/rotate credentials or rewrite earlier Successor
  commits. Scoped scans are not a comprehensive security guarantee.
- Recorded final stage-7 checks: 67 selected socket-free native cases, 23
  human-HTTP daemon memory/recall cases, two API-doc cases, and successful static
  checks and CLI build. The last isolated notes-fixture correction received
  static/configuration checks and independent review; native/HTTP suites were
  not rerun for that test-only change. Prior stage-6 and unchanged Rust/Go and
  sanitization/fixture results remain recorded evidence, not new full-suite
  passes. Native provider encoding checks are not live provider transport tests.
- One initial live LCM attempt failed at AF_UNIX setup before provider semantics.
  Full `./test.sh`, full `gleam test`, kernel/provider-turn E2E and Chrome remain
  unverified under the approved AF_UNIX/Chrome exception. The inherited setup
  capacity gap remains assigned to stage 11; overall capacity compliance is not
  established. This is WIP, not the stage-12 release. Publication verifies exact
  subtree parity and existing Successor preservation without testing the active
  implementation worktree.
