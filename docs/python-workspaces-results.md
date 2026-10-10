# Local workspace-slice results

2026-10-09, successor baseline `d1f75b322aae53019bc9539c9aab2084018ff1cf`.
Implementation is uncommitted; no push or successor live-provider request made.
Environment: Gleam 1.19, OTP 27, Python 3.13.5, local POSIX/Linux.

## Gates personally rerun by the parent

| Gate | Real result |
| --- | --- |
| `ERL_FLAGS="+S 4:4" gleam build` | Exit 0, no warnings after final cleanup |
| `ERL_FLAGS="+S 4:4" gleam test` | **74 passed, no failures**, ~3 seconds; three consecutive full repeats passed, then final cleanup run passed |
| `gleam format --check src test` | Exit 0 |
| `python3 -m unittest discover -s test/python -v` | **17 tests OK**, 2.566 seconds reported by unittest |
| `erlc -Werror` for production/test Erlang bridges | Exit 0 |
| `python3 -m py_compile` for kernel/lock/tests | Exit 0 |
| `git diff --check` | Exit 0 |

The 74 Gleam tests include the existing 45, 11 workspace-store tests, and 18
workspace/runtime integration tests. They execute real Python and SQLite, not
an in-memory fake executor. Deliberate kill/fault tests emit expected OTP crash
reports; those are not failed assertions. The CI workflow includes Gleam and
Python commands, but this unpushed change has **not** been verified by remote CI.

Local raw logs: `/tmp/successor-workspaces-20261009-verify/`.
No successor kernel/lock-helper processes remained in the final `/proc` scan.

## Accepted behavior exercised

- Persistent variables and last-expression output; exceptions preserve healthy
  heaps. Root identity is idempotent; same-label children have distinct IDs,
  independent namespace/files/default CWD and parent/session linkage.
- Minimal environment excludes a synthetic host secret; scratch HOME is private.
  Million-character writes are captured with bounded production retention.
  Invalid timers/source limits refuse before journal/dispatch and keep the
  existing kernel healthy. BEAM timer headroom is checked at every boundary.
- Slow work exposes an intent; same-agent busy rejects without another intent;
  other agents run. Timeout, mid-cell close and owner death reap ordinary owned
  processes, yield unknown and create a fresh heap on later explicit execution.
- Rejected and persisted-but-unacknowledged intent cannot authorize source.
  Withheld acknowledgement gates dispatch. Refused terminal settlement cannot
  publish success, even when a side effect occurred once. Inspection distinguishes
  durable receipt from caller uncertainty; source is never automatically replayed.
- Host restart preserves deployment/session/root/child IDs, source/receipts/files.
  Executor death classifies unfinished work without waiting for another cell.
  Coordinator restart fences orphaned intents; writer restart tears down later
  owners before recovery. Suspended close does not block another agent's cell.
- Finite live slots reject before intent; close/unknown/failed-start retirement
  frees capacity. Concurrent session opens share one runtime; duplicate live
  claims refuse. Name-backed factory references reach the replacement supervisor;
  temporary missing registry/factory returns error rather than caller panic.
- Genuine v1 migration preserves canonical history. Required schema columns,
  workspace indexes/order/uniqueness/partial predicates are read-only-preflighted.
  Malformed v1, missing v2 tables/indexes and future version refusal leave the
  database bytes unchanged. Migration failure rolls back tables/version stamp.
- Real transport rejects malformed/truncated/corrupt/oversized advertised frames;
  native fd1/fd2 contamination is not supported output. fd2 cannot flood host
  stderr. Repeated PID queries cannot extend a task deadline. Large escaped ID
  plus long Unicode exception fits the bounded metadata allowance and retains
  the healthy namespace. Same-directory lock overlap refuses; close permits
  reacquisition.

## Boundaries (not broader completion claims)

[Contract](python-workspaces.md) is authoritative. Single exclusive host owner,
trusted execution (not sandbox), shared writer/control latency, no automatic
source retry, no heap persistence, no GC or deployment lease. Model tool
projection, rich files/jobs/output helpers, full inference subagents, real
providers, remote worker, daemon and UI remain subsequent work. The reuse map
identifies actual Albedo cohorts; it does not claim they have already been ported.
