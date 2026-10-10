# Agent-local coding helpers — implementation contract

2026-10-09. Work6, authorized continuation. Port cohesive Albedo machinery at
pin `8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450` (WTFPLv2); record copied source paths
and modifications, retain relevant notices. Do not call this clean-room.

## Owner and invariants

`priv/python/successor_tools/` owns helper implementations, inside each private
CPython interpreter. Kernel injects `files`, `run`, `jobs`, `output`, `Path`,
`asyncio`. Persistent event loop and top-level await allow background jobs to
make progress between cells. Existing DeploymentStore remains sole canonical
writer: whole cell source intent ACK before execution, current-fence receipts,
no automatic source replay. A successful spawning cell is NOT a completed-job
receipt. Job handles/registry are incarnation-local; output/status files are
inspection artifacts, not dispatch permits or durable effect reconciliation.
No model tool projection, inference subagents, provider credentials or remote
workers. Schema/API v1 cell transport and existing IDs/receipts stay unchanged.

Trusted POSIX/Linux local execution, NOT a sandbox. Helpers default to this
process's current CWD (initially agent scratch); explicit project paths/cwd are
supported, never identity. Job cwd/environment are snapshotted at invocation.
No automatic shell interpolation, credential discovery or unrelated cleanup.

## Shared Python ABI

- `api.py`: adapted Albedo `Text(str)`, `ReadyList(list)`, `excerpt`,
  `OutputCapture` protocol; `RETAIN=1048576`, `OUTPUT_PREVIEW=65536`.
- `capture.py`: adapted `Capture(id, kind="job", spill_dir=None)`; fields
  `data`, `seen`, `spill`, `spilled`, property `retained`; methods
  `write_bytes`, `write`, `tail(limit=65536)`, `read_bytes(offset,limit)`,
  `read(offset=0,limit=4000)`, `end_spill`. First1MiB + last64KiB memory,
  exact prefix spill up to16MiB. Explicit lost-byte/incomplete-output refusal.
  No trace/images/host hooks or automatic disk deletion.
- `output.py`: adapted Albedo `JobOutput` methods `head`, `tail`, `read`,
  `save` (atomic complete bytes only); uses job attributes capture/duration/
  exit_code/_read. `OutputRegistry(spill_dir)` exposes `capture(id)->Capture`,
  `read(id,offset=0,limit=4000)->Text`, `list()->ReadyList`, `forget(id)`.
  Captures register once; forget closes handles, NOT artifact deletion.
- `files.py`: adapted Albedo module functions `read`, `write`, `edit`, `ls`,
  `find`, `paths`; `initialize(runtime)` binds JobRuntime, no import cycle.
  Keep bounded numbered reads, exact-unique edit/ambiguous matches/line_hint
  diagnostics, readonly search diagnostics. Search commands use supervised
  runtime jobs; never direct subprocess. Pure writes/edits atomic, UTF8 errors
  leave original intact. Bound helper write/edit to64MiB; fail before mutation.
- `jobs.py`: `JobPolicy(active_limit=64,retained_limit=64)`;
  `JobRuntime(workspace,output_registry,policy=None)` has `jobs` dict and
  `run(program,*args,cwd=None,env=None,stdin=None,timeout=300)->Job`,
  `forget(job)`, `shutdown()` async. Admission/finite timeout validation before
  spawn. Environment explicit overrides inherited MINIMAL kernel environment.
  `stdin` supports text, bytes, PathLike, or another Job.
- Job uses copied/adapted Albedo Job/Command/Outlet/Feed and JobOutput mechanics;
  `id`, `argv`, `command`, `pipeline`, `exit_code`, `duration`, `timed_out`,
  `termination`, `capture`; `.pipe(...)` returns reader Job; `await job` waits
  owned pipeline; `.poll()`/`.returncode`; `await job.stop()` requests stop and
  returns Termination when known. Preserve backpressure, bound preconnect feed
  buffering and late-pipe refusal when full input cannot be supplied. Active
  cleanup uncertainty stays owned; only terminal handles evict in completion
  order. No daemon notifications/services/remote/shims/trace stubs.

## Guardian/lease ABI (do not weaken cleanup)

Async jobs use separate program groups. Killing kernel group alone would leak
those jobs; guard them independently, including CPU-bound kernel SIGKILL.

`guardian.py` CLI:
`--lifetime-fd N --lease-fd N --status PATH --active-record PATH --deadline MONOTONIC_SECONDS -- argv...`

Kernel job launcher persists an exclusive-create/fsynced per-job marker in
`<workspace>/.successor-runtime/active-jobs/` before guardian spawn (after SH
lease acquisition). No argv/source/env is stored. A definitive pre-spawn error
may remove its own marker; ambiguous spawn never removes it. Guardian removes
its marker only after checked target-group absence, never on mere process
exit/error. This private cleanup latch is NOT a canonical cell/job receipt or
dispatch/retry permit. If the guardian itself is killed, the marker persists:
absence of shared lease alone is not proof of cleanup. Startup and shutdown
require BOTH exclusive jobs.lock and no active markers. A stranded marker
requires trusted manual process reconciliation; no automatic GC/replay.

Kernel job launcher opens stable `<workspace>/.successor-runtime/jobs.lock`,
acquires shared flock BEFORE spawning, and passes that same FD to guardian
via pass_fds. Parent closes its FD, never flock(LOCK_UN) on the shared open
file description. Guardian runs in its own session, owns inherited shared
lease and lifetime read pipe (kernel sole write end, close-on-exec). Target
runs in another session via `command.py --gate-fd N -- argv...`, holding on
one-byte GO (`G`) until guardian captures PID/start token, writes initial
status atomically, and only then authorizes exec. GO EOF exits without exec.
Target must inherit neither lifetime nor lease descriptors.

Status JSON <=8192 bytes: v1, state running/terminated/cleanup_uncertain,
pid (target pgid), leader (start token), returncode (int/null), timed_out(bool),
reason(string), termination (Albedo Termination.as_json or null). argv/env
are not written to status. Terminal publication must follow checked cleanup.
Job sees missing/corrupt/nonterminal status after guardian loss as unknown,
NOT exit0. Job cancellation writes S to lifetime pipe then closes; EOF means
kernel owner loss. Guardian deadline is independent of kernel event-loop
progress. Natural target exit also cleans remaining group members.

Borrow `proc.py` directly from albedo_proc.py, including checked TERM/KILL,
start tokens and zombie-aware probes. Guardian stays alive with lease while
cleanup cannot prove gone. Job metadata/active slot stays uncertain and owned.
No program re-execution. Intentional escaped descendants remain out of scope.

Parent lock helper probes jobs.lock exclusively at kernel STARTUP; active
shared leases refuse replacement before source. During shutdown it waits for
exclusive job-lock proof and empty active-marker directory before releasing kernel.lock, with a bounded native
wait and conservative busy/replacement refusal if cleanup remains uncertain.
Stable lock files are never unlinked. EOF/SIGKILL of kernel therefore cannot
open a new incarnation while old ordinary program groups remain live.

## Work placement, growth and tests

No helper history scan per cell. Registry maps bounded active64 + terminal64 (and admission counts pending handles + stranded markers),
page64KiB, in-memory retained1MiB/channel, disk prefix16MiB/channel. Artifacts
retained on restart/eviction; no GC or aggregate disk quota claimed. Complete
read/save refuses discarded output. Cell stdout still separately bounded by
existing per-cell limits. Paths/edits scan bounded input or stream; external
search has finite deadline/result/output bounds.

Tests: real kernel await/background progress, two-agent isolation, files/edits/
search, pipelines/backpressure/stdin/nonzero exit, >1MiB spill/pages/exact save,
>16MiB incomplete refusal, timeout/cancel, kernel close and CPU-bound SIGKILL
with active job descendants, no early replacement while lease held OR guardian lost, restart
no replay and retained artifacts. Previous74Gleam +17Python gates are retained within final76Gleam +77Python.
No tests touch real home/credentials/projects. Parent serializes Gleam gates.
