# Coding helpers: local usage and acceptance

Local adaptation begun 2026-10-09, final verification 2026-10-10. Uncommitted;
no publication or remote CI success is claimed. Trusted Linux execution, not a
sandbox. Python stdlib only; `rg` is an explicit external search dependency.
The [contract](coding-helpers-contract.md) fixes ownership and resource bounds;
[third-party notices](../THIRD_PARTY_NOTICES.md) identify actual Albedo reuse.

## Usage inside each private Python workspace

Pass these sources through `app.execute_python(host, agent.id, source, limits)`.
Whole source intent is durably acknowledged before evaluation. Namespaces and
helper registries are agent/incarnation-local; scratch and inspection artifacts
remain on close/restart, but heaps/handles do not replay.

```python
await files.write("example.txt", "hello\n")
await files.edit("example.txt", "hello", "changed")
await files.read("example.txt", limit=10)
```

```python
job = run("python3", "-c", "import sys; print(sys.stdin.read().upper())",
          stdin="hello", timeout=300)
await job
print(job.exit_code, job.duration)
job.tail(lines=1)
job.save("complete-output.txt")
```

`run()` schedules and returns a handle immediately; a bare handle is NOT
implicitly awaited by last-expression display. Jobs progress whenever the
persistent loop has control, including between cells. `.pipe(...)` / `stdin=job`
connect bounded backpressured feeds. Awaiting/stopping a final stage owns the
whole pipeline, but exit codes are still individual: explicitly check every
stage when required (no implicit shell/pipefail policy). Early broken readers
wake producers and cut their read pipe. No shell interpolation occurs.

`await files.find("needle", "src", context=1)` and
`await files.paths("*.gleam", "src")` use supervised `rg` jobs. The production
kernel PATH is deliberately `/usr/bin:/bin`; this does not discover tools or
credentials from the embedding user's environment. Install trusted tools on
that path, use absolute `run()` programs, or explicitly set `os.environ['PATH']`
inside a journaled cell. Missing rg raises; incomplete/unknown/timeout search
never silently becomes no matches. Final local search acceptance uses a
specific trusted installed rg PATH; CI installs ripgrep explicitly.

`output.read(job.id, offset=..., limit=...)` inspects a bounded byte page.
`output.list()` lists retained incarnation-local channels. Background asyncio
stdout goes to bounded `native`, not a future cell's receipt. Deleting a
shadowed injected binding restores it on the next cell. Raw fd1/fd2 writes
remain unsupported protocol contamination.

## Honest completion, retention and cleanup

- A `Succeeded` spawning cell is a completed SOURCE evaluation, not a completed
  command/effect receipt. `Failed` is a Python exception, not proof of zero
  effects. An unknown job/status raises with exit/duration unset; no source or
  command is automatically retried. Private job status files/markers are not
  SQL authority, durable tool receipts or dispatch/retry permissions.
- Each command has an independent guardian, lifetime pipe and SH job lease.
  Target exec is gated until captured PID/start token and initial atomic status.
  Deadline works even while the kernel loop is CPU-bound. Ordinary target-group
  descendants are checked TERM/KILL-cleaned; zombies are not running work.
- Shared-lease absence is insufficient if the guardian is killed. A pre-spawn
  fsynced `active-jobs/<job-id>` marker remains until checked cleanup. Startup
  requires BOTH an exclusive jobs.lock probe AND no active markers. Native
  close waits boundedly and `Nil` does not guarantee a completed-job receipt.
  A killed guardian, ambiguous spawn or storage failure may strand the fence
  indefinitely. Do not remove markers or unlink stable locks merely to restart:
  trusted operators must reconcile the owned group using original start-token
  identity, prove no running members, and only then retire its cleanup marker.
  This slice has no automatic guardian resurrection/reconciliation service.
- Default maps: active64 + retained64; uncertain cleanup keeps capacity. Latches
  count against admission too. Registry guards are not a heap/CPU sandbox.
  Cached pipeline display grows with its stage/argument history; directory
  listings materialize that directory. Neither is a global heap quota.
  Explicit cwd/environment are snapshotted; HOME defaults to private scratch
  even if cwd is a project; explicit overrides are allowed.
- Capture retains first1MiB + last64KiB; spills exact first16MiB per channel;
  previews/pages <=64KiB. Complete saves are atomic exact bytes and refuse
  discarded data without replacing the destination. Limited pages may inspect
  a retained prefix while completion is unknown. UTF8 display is not binary
  fidelity; use save for exact bytes. Spill/status artifacts are noncanonical.
- File writes/edits <=64MiB, atomic UTF8 replacement. Write/edit follow symlinks
  and preserve the link. Exact edits refuse ambiguity, including two matches
  on a hinted line. Concurrent snapshot checking is best effort, not a cross-
  process filesystem CAS; changes racing after its final check can still occur.
  Synchronous file operations can block this loop; external cell deadlines and
  independent guardians remain necessary. Large diagnostics are bounded.
- No aggregate disk quota, artifact GC, heap persistence, model tool loop,
  inference subagents, live credentials/providers, remote worker or sandbox is
  supplied. Deliberately escaped/tampered processes are outside this trusted
  tier. If a guardian itself is killed, its target may remain running until
  explicit reconciliation; replacement refuses rather than masking that loss.

## Verification

Parent independently ran the final frozen-source gates:

| Gate | Real result |
| --- | --- |
| `ERL_FLAGS="+S 4:4" gleam test` | **76 passed, no failures**, 6.825 s wall |
| `ERL_FLAGS="+S 4:4" python3 -m unittest discover -s test/python -v` | **77 passed**, no skips, 83.476 s suite / 83.576 s wall |
| Python breakdown | files/output15 + jobs20 + joined kernel9 + guardian13 + baseline kernel8 + native transport12 |
| `gleam build`; `gleam format --check src test` | exit 0 |
| `erlc -Werror` shipped/test native modules | exit 0; real installed native fixture compiles the current bridge too |
| Python compileall; `git diff --check`; explicit untracked source whitespace check | exit 0 / no whitespace findings |
| Final `/proc` owned-helper/controlled-target scan | empty |
| Frozen tested-source SHA256 manifest | unchanged, 19 relevant Python/native/joined-test files |

Evidence directory: `/tmp/successor-coding-helpers-20261009-verify/`.
Final logs: `gleam-test-final.log`, `python-tests-final.log`,
`native-persistent-fence.log`, `process-scan.json`, and
`tested-source-sha256.json`; other build/compile/format/check logs are alongside.
Earlier red and pre-latch logs are retained as review evidence, not final gates.
The 76 Gleam tests preserve the previous74 and add2 joined coding cases.
Expected injected OTP process-kill reports are test evidence, not failures.
Git HEAD remains `d1f75b322aae53019bc9539c9aab2084018ff1cf`.
CI configuration includes the tests and explicit rg installation; **remote CI
was not run**, because no commit/push was authorized.

Important joined coverage: real SQLite source ACK before helper launch,
spawning-cell-vs-job completion, pipeline nonzero/source completion, separate
child registry/files, close cleanup and fresh handles with retained artifacts;
real kernel await, background progress and late-output attribution; real native
CPU-bound timeout with forked target, paused guardian holding lease, and killed
guardian with vanished lease but persisted marker refusing replacement.

The verbatim proc module (after its three-line provenance header) has pinned
SHA256 `25f20d7354b38d10f0c0e9e579fc567b11455bcdfb368cf304bfd52b89b25ea8`.
Parent personally verified its exact byte equality and the verbatim license.

## Publication follow-up

The measurements above describe the local checkpoint before publication.
See [PR integration and release acceptance](coding-workspaces-pr-results.md)
for current-main preservation, independent-review fixes, and final CI evidence.
