# Agent-owned Python workspaces — first slice

Status: implemented locally and tested, 2026-10-09; no commit/push made. User chose continuing the independent Connectome-informed successor and explicit Python workspaces for agents and subagents, borrowing coding mechanisms from Albedo. This brings a small operator-driven execution slice forward ahead of the full model tool loop and advanced memory roadmap.

## Ownership and scope

The DeploymentStore is the sole durable writer. Durable AgentId identifies a private scratch directory and Python namespace; directory changes do not define identity. One root workspace per existing session, plus distinct child AgentIds linked to a parent and that parent's session. Duplicate display labels are allowed. This slice creates child execution workspaces, NOT model-driven subagent inference. Canonical session records and provider behavior remain unchanged.

A workspace coordinator under the application supervision tree owns per-agent execution actors, which own Python transport processes. An execution actor admits one cell at a time, records source/intent before dispatch, and rejects concurrent work as busy. Other agents execute independently. Python remains alive between successful/error cells; timeout/transport loss ends that incarnation. A new one starts with an empty namespace. A cell is NEVER reexecuted automatically.

Private scratch: `<data_dir>/agents/<AgentId>/workspace`, created on first execution. Project checkouts are separate explicit paths supplied to trusted code; the root does not move other agents. Directories/artifacts are retained on close/restart, not deleted automatically. No heap pickle, definition replay, remote worker, browser API, HTTP daemon, UI, or real provider is added. The follow-on coding-helper cohort adds files/jobs/output and top-level await; see [helper contract](coding-helpers-contract.md).

Trusted local execution, not a filesystem/network sandbox. Separate interpreters give namespace/default-CWD isolation, not security against intentional host access. Start Python with an explicit minimal environment and isolated mode, without inheriting provider tokens. Configurable source/output/time guards protect transport and accidental runaway work, not adversarial Python. The mechanism must reap owned execution processes on close and owner death; escaped arbitrary subprocesses are not a claimed sandbox property.

## Shared types (workspace_types.gleam)

`AgentWorkspace(id: ids.AgentId, session: ids.SessionId, parent: Option(ids.AgentId), name: String, incarnation: Option(ids.AgentIncarnationId))`.

`CellState { Intent; Succeeded; Failed; OutcomeUnknown }`.

`Cell(id: String, agent: ids.AgentId, incarnation: ids.AgentIncarnationId, source: String, state: CellState, output: String, truncated: Bool, error: Option(String))`.

## Store messages (store.Msg additions)

- `EnsureRootWorkspace(session: SessionId, name: String, reply: Subject(Result(AgentWorkspace, String)))`: idempotent per session, preserves existing identity.
- `CreateChildWorkspace(parent: AgentId, name: String, reply: Subject(Result(AgentWorkspace, String)))`: new identity, same session, distinct parent.
- `GetWorkspace(agent: AgentId, reply: Subject(Result(AgentWorkspace, String)))`.
- `ActivateWorkspace(agent: AgentId, incarnation: AgentIncarnationId, reply: Subject(Result(Nil, String)))`: advances active fence and marks prior intent rows outcome_unknown, without deleting artifacts/results.
- `BeginCell(cell: Cell, reply: Subject(Result(Nil, String)))`: validates current incarnation and intent state; unique cell IDs; at most one intent per agent. An unacknowledged write does not authorize dispatch.
- `SettleCell(cell: Cell, reply: Subject(Result(Nil, String)))`: validates agent/incarnation/current-fence, existing intent, matching source, terminal state; a duplicate or stale settlement refuses rather than overwrites. If settlement acknowledgement is unknown, return an error and require inspection; never resend source.
- `GetCell(id: String, reply: Subject(Result(Cell, String)))`.
- `RecoverWorkspaces(reply: Subject(Result(Nil, String)))`: coordinator/store startup classifies unresolved intents unknown and clears old incarnation fences before serving; never replays source.
- `ListCells(agent: AgentId, reply: Subject(Result(List(Cell), String)))`: first-slice explicit inspection only; not called in a per-turn hot path. Document growth/no GC.

Workspace SQL belongs in `workspace_store.gleam` called only by DeploymentStore with its private connection. No module cycles to db.gleam; workspace store errors are strings. Schema version 2 must migrate genuine version 1 transactionally, retain all existing rows/identities, refuse future/corrupt versions without mutation; add all needed indexes and constraints. Test upgrade/reopen/future refusal and fencing. The schema change updates config.schema_version; old config tests should reference that constant unless specifically testing old/future versions.

## Python transport (python.gleam + successor_python_ffi.erl + priv/python)

Public exact API:

- opaque `Kernel`.
- `max_output_bytes_limit = 11173888`, derived as `(64MiB-65536)//6`
  for worst-case JSON escaping within the response frame. Higher capture limits
  refuse before intent/evaluation; nonempty cell IDs are at most4096 UTF8 bytes.
  The kernel independently refuses response frames above64MiB.
- `Limits(timeout_ms: Int, max_source_bytes: Int, max_output_bytes: Int)`; `default_limits()` returns 300000 ms, 1048576 source bytes, 262144 retained output bytes. These are configurable transport guards, not task/token quotas.
- `Outcome { Succeeded(output: String, truncated: Bool); Failed(output: String, truncated: Bool, error: String); Unknown(reason: String) }`.
- `start(workspace: String) -> Result(Kernel, String)`; owns a persistent interpreter, linked/monitored to calling execution actor; ensure private directory exists and reject bad startup.
- `execute(kernel: Kernel, cell_id: String, source: String, limits: Limits) -> Result(Outcome, String)`; preserve namespace between cells, stdout/stderr capture, last-expression display if feasible; validate correlation and complete bounded framing. Errors at transport level mean outcome_unknown to the coordinator, not safe retry.
- `close(kernel: Kernel) -> Nil`; stop/reap owned execution process promptly even during a long cell.
- `os_pid(kernel: Kernel) -> Int`; diagnostic/testing only.

Do not run user source before limits validation and before the coordinator acknowledges its intent. Captured output must be bounded during production, not just sliced afterward. Exceptions give a failed cell but do not reset a healthy namespace. Deadline/owner loss closes/reaps the kernel; late responses never attach to another cell. Use the stdlib only for Python. Protocol v1. No inherited host key stores, no shell command interpolation. Copying Albedo code requires precise provenance/notices; borrowing mechanisms alone is fine. Take framing, stable call identity and honest failure lessons, not a huge bundled kernel transplant.

## Coordinator and lifecycle

Root/child/get APIs produce durable IDs. Lazy per-agent actors/kernels on execution; each incarnation activated before admitting cells. Generate cell ID/source intent, dispatch only after BeginCell Ok, map outcomes to terminal receipt, publish success only after SettleCell Ok. Keep actor responsive while a child dispatch blocks on Python: active requests return busy. Kernel loss kills/disposes its transport and the next admission gets a fresh incarnation. Closing retains files/history. Coordinator shutdown/owner death must close all its children; root host ordered stop must not leave Python running.

## Acceptance

- Published main lifecycle/reopen/conformance coverage remains green, no regression to walking provider path.
- Real Python: repeat cells retain variables; root and same-label children have independent names, files/default CWD; Python errors keep namespace; output overflow bounded/truncated; no inherited synthetic secret; cell timeout unknown/new namespace; close/death no ordinary owned-process leak.
- Journal intent is visible while a slow cell runs; rejected intent causes zero Python side effects; failures/duplicates/stale incarnation cannot overwrite receipts.
- Close/restart retains AgentIds, paths/files and terminal receipts; heap state loss explicit; unfinished intent is classified unknown and not replayed.
- Schema 1->2 preserves sessions/records/deployment; future versions fail closed.

Canonical model tool-call dispatch, projected host tools and full subagent inference are next slices, not claimed here.

## Operator/library usage

```gleam
let assert Ok(sid) = app.start_session(host, "resident")
let assert Ok(root) = app.root_workspace(host, sid)
let assert Ok(child) = app.child_workspace(host, root.id, "test-worker")
let assert Ok(first) = app.execute_python(
  host, root.id, "answer = 40\nanswer + 2", python.default_limits(),
)
let assert Ok(second) = app.execute_python(
  host, root.id, "answer += 2\nanswer", python.default_limits(),
)
// `child.id` has a separate interpreter and scratch directory.
let assert Ok(receipt) = app.inspect_python(host, first.id)
let assert Ok(_) = app.close_python(host, root.id)
// After host restart, app.open_session(host, sid) reopens the original session.
```

A returned `Cell` is a durable terminal receipt; inspect its state, not merely
`Ok`: `Failed` means a Python exception and `OutcomeUnknown` means effects may
have occurred. A request/receipt error may be ambiguous; inspect the ID in the
error or `workspaces.cells(host.store, agent)` before deciding what to do.
Never equate an error with permission to resend side-effecting source.

Root supervision is rest-for-one: a writer failure stops later runtime owners
before recovery. Session factory references retain the registered name, not
an obsolete PID. Session keyed session-supervisor child catalogs refuse a second live owner. Registered-name absence
during restart returns an error instead of a caller panic. Session-factory
creation pins the owner and waits at most 15 seconds; a timeout may leave a
late-created runtime, which the registry can discover. Creation is not retried
automatically.
Temporary execution actors never automatically restart/reexecute a cell.
Executor death attempts a tombstone fence/classification before releasing its
slot; a tombstone incarnation is not evidence of a live kernel. If the writer
cannot acknowledge classification, pending receipts may still show intent:
the caller gets an uncertainty error and replacement must acknowledge a fresh
fence (classifying old intent) before any dispatch.
Coordinator startup also fences orphaned intents before accepting new work.

Normal close is asynchronous inside the pool: other agents can continue while
one execution owner is closing, and that agent cannot get a replacement until
owner DOWN and classification. The durable writer is still shared: admission,
settlement and pool fencing can wait up to five seconds for store acknowledgement
and can delay other control requests. This slice does **not** promise full
latency isolation while the writer is stalled.

## Resource, retention and recovery limits

- Use one host/store owner for a data directory. Cross-host deployment leasing
  is not implemented; do not run two hosts against the same database.
- Default capacity is 16 live kernel slots, including startup/cleanup. The
  standalone coordinator exposes `start_with_policy(..., Policy(n))`; app
  configuration wiring is not yet exposed. Close idle workspaces to free slots.
  Failed startup, unknown outcome, or receipt failure retires its actor/slot.
- Timeout is 1..4,294,937,295 ms (BEAM timer limit minus call headroom), not a
  campaign/token budget. Source/output guards are configurable. Wire/output
  protection also has a hard 64 MiB frame/output ceiling; very large escaped
  payloads may refuse rather than fit. Defaults are 1 MiB source / 256 KiB output.
- Captured Python stdout/stderr is bounded while being written. Raw native fd1/fd2
  output is not a supported output API: malformed headers/correlation lose the
  transport and produce unknown, never a fabricated completion. CPython is not
  an adversarial protocol boundary; code can access host files or tamper with
  its own process intentionally. No heap/CPU/file quota sandbox is claimed.
- Stable, never-unlinked kernel and shared job-lease locks fence replacement
  through transport/group cleanup. Native close has a bounded drain wait;
  an uncertain surviving guardian retains its job lease and startup refuses.
  A killed guardian can lose that lease while its target survives, so persisted
  `active-jobs` cleanup markers also refuse startup until trusted reconciliation.
  `close -> Nil` is not itself a durable completed-job receipt. Replacement can briefly refuse startup while old cleanup finishes;
  it does not automatically retry source. Keep `.successor-runtime` intact.
- Ordinary owned process groups are TERM/KILL-cleaned on close, deadline and
  owner death. Deliberately escaped processes are outside this trusted tier.
  Host stop triggers prompt cleanup; tests wait for actual OS process exit.
- Journal IDs/source/output and scratch files are retained indefinitely. There
  is no GC, paging API, disk quota, rich image rendering, traceback history, or
  heap snapshot/replay. ListCells is an explicit O(n) materialized inspection,
  not a per-turn operation; an internal durable insertion ordinal orders cells.
- Keep the data directory private. Raw source/output is stored, not redacted;
  an explicit secret written into a cell would therefore be journaled.
- Heap state is lost across interpreter/host replacement. Python supports last-expression display, a persistent asyncio loop and
  top-level await. Files/jobs/output are injected; the full Albedo plugin/daemon
  namespace is not transplanted.

Borrowing/cohort adaptation is tracked in [albedo-reuse.md](albedo-reuse.md).
