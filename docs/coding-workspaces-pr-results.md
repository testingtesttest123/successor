# Python coding-workspace PR integration

PR: https://github.com/testingtesttest123/successor/pull/2

The initial local76Gleam/77Python gates were real but based on local
`d1f75b322aae53019bc9539c9aab2084018ff1cf`. Publication fetched current main
`bc54ff77c6b96dac04dd44dd5c99b683350fa07e` (merged PR1), containing additional
keyed session ownership, reopening and conformance coverage. This PR preserves
that published work rather than replacing it with the older feature baseline.

## Integration decisions

- The keyed OTP session-supervisor catalog owns session admission/idempotence.
  Registry presence is discovery, not the one-owner admission authority. Main's
  exact monitored/outage-tolerant session registration and typed reopen errors,
  persisted selected-branch validation, and tests remain.
- RestForOne dependency order is store → workspaces → operator → keyed sessions
  → registry → providers. Writer loss tears down workspace executors/dependents
  before recovery/admission. Registry-only loss preserves session workers and
  uses their existing monitored re-registration. Native keyed start pins the
  supervisor PID once with a finite acknowledgement wait; no name reroute.
- Start/reopen ensures the durable resident workspace before success, without
  resetting the selected branch, creating another session, or replaying work.

## Independent-review fixes

- Enable and verify connection-local SQLite foreign-key enforcement on every
  db.open. Missing-session roots cannot be inserted.
- No-meta means fresh only if there are no non-internal SQLite schema objects.
  A partial/corrupt database is refused byte-for-byte, not initialized over.
- Validate the known generated schema, including authority-bearing table/index
  definitions, before compatible-store writes or genuine-v1 migration. This is
  bounded startup schema-object checking, not a scan of historical rows and not
  arbitrary handwritten-schema compatibility. SQL literal whitespace/case may
  not be folded into a different predicate/check.
- Cell raw output limit is derived from the fixed64MiB response frame:
  `(67108864 - 65536) // 6 = 11173888` bytes. Sixfold worst-case JSON escaping
  plus bounded4096-byte UTF8 ID /4096-character error /fixed fields fits the
  envelope. Gleam/workspace admission, native transport and kernel agree before
  effects; default remains262144. Oversized requests refuse without source
  execution/journal intent, and a healthy heap remains usable.

## Final acceptance

Frozen integrated-source local gates (2026-10-10, OTP27/Gleam1.19/Python3.13.5):

- `gleam test`: **104 passed, no failures** (7.355s wall).
- `python3 -m unittest discover -s test/python -v`: **80 passed, no skips**
  (84.556s tests,84.636s wall), including the real worst-case escaped-output
  native boundary and persistent guardian-death cleanup fence.
- `python3 -m unittest discover -s conformance -p 'test_*.py' -v`:
  **4 passed** (2.147s tests), including read-only inspect and host ownership.
- Build, Gleam format, Python compileall, all production Erlang adapters
  `erlc -Werror`, and `git diff --check`: **exit0**.
- Controlled-runtime `/proc` scan: **no runnable owned runtime processes**.
- Independent storage/ownership and helpers/native reviewers: **no remaining
  merge blockers**, after the fixes above. Review is not a substitute for tests.

Evidence: `/tmp/successor-pr-workspaces-20261010`, with full suite logs,
`source-sha256.json` (60 source/test entries), static logs and process scan.
The initial integrated Gleam run had103 passes and one fixture-only open error:
raw sqlight.open did not create its parent directory. A flat unique /tmp path
fixed setup without weakening any assertion; full104 then passed. The initial
red log is retained. The historical76/77 gates are not the publication gate.

The workflow runs the integrated Gleam, all80 Python,4 conformance and format
checks, installs ripgrep, and uses OTP29/Gleam1.19. GitHub Actions run
[38012691359](https://github.com/testingtesttest123/successor/actions/runs/38012691359)
completed **SUCCESS** for the exact integrated source commit
`76cc3f848700094e212e77041b54afb2b46c7af7` on2026-10-10. All workflow steps passed.
The subsequent documentation-only revision leaves the60-entry tested code
manifest unchanged. Any later PR head is also gated on its own CI before merge;
[PR2 checks](https://github.com/testingtesttest123/successor/pull/2/checks) are the
public authority for that final-head result.

Trusted local operator/library tier only: no sandbox, automatic process
reconciliation/GC, full Home parity, live credentials/providers, inference tool
loop or remote worker. The other result documents retain their historical
checkpoint measurements; this document is the publication gate.
