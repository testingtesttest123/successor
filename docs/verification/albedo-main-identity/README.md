# Bounded Albedo main-identity verification

This publication preserves the tested Successor source tree and adds only this verification documentation. It does not change standalone main, Albedo upstream, repository settings, or deployments.

## Exact source identity

- External-plugin base commit: `87257be698c034ea6a58d9b9a853f51789bc73fc`.
- Tested Successor tree: `8040a26e07d72500a5f8c60f8d475ccd1451cbc8` (49 changed paths, including31 additions).
- Albedo base commit: `e086179bbaa8beda2b2a20e688dfa86bfe39b190`.
- Reconstructed Albedo tree: `ce2b7c4641713138e3e6d0da53d6577c1c9573ea` (48 changed paths, including7 additions).
- Albedo patch: [`../../../patches/albedo-current/0001-durable-main-identity.patch`](../../../patches/albedo-current/0001-durable-main-identity.patch), SHA256 `53143a8d8cc152240581d590df7909cbabde81ad473b48aa6b30c83204da20ba`.

The first publication commit has the exact tested Successor tree. The following documentation commit adds only this directory. The inventories record every tested source path, Git blob, Git mode, size and SHA256; they intentionally describe the tested trees before this publication-only directory. Both cumulative patches reconstructed their advertised trees using temporary indexes, and every source byte and normalized Git mode matched the preserved source handoff archive before publication.

## Outcome and defects resolved

The host provides configurable startup with both listener ports, transactional lifecycle callbacks, persistent generic session capability requirements, an authenticated idle mutation bridge, and captured request context. The opt-in external extension owns one explicitly initialized main identity, immutable revisions, owner binding, complete mandatory projection, revision-CAS edits and replay receipts.

Unbind initially exposed a fail-open in both provider protocols: it removed the persistent requirement while a cached stock composition still omitted the selected identity contributor. Admission now checks selected and retained required contributors in both directions independently of persisted requirements. Mismatch refuses with `reload required`; explicit session reload restores the requested composition. Global enablement cannot bypass this check. Persisted requirements independently protect missing, disabled, quarantined, and removed owners.

Saved warming requests carry the configuration revision captured in their observer handle. Serialized background admission rejects changed revisions before provider lookup; idle binding mutations cannot race a running/booting/background session. Document-only edits preserve exact saved-request reuse without recapture. Independent review also found a provider call-ID collision could recover a human edit receipt; model recovery now requires owner-agent actor, exact origin session and call ID.

## Verified local evidence

| Suite | Result |
|---|---|
| Final native Albedo |456 passed, zero failures|
| Final immutable HTTP snapshot, Responses and Chat Completions |32 passed, zero failures;40 daemon boots|
| Frozen request-context fixture |37 passed, zero failures|
| Identity package |45 passed, zero failures|
| Lifecycle fixture |21 passed, zero failures|
| Startup fixture |12 passed, zero failures|
| Product composition |1 passed|

Gleam check/format passed for the affected host/package/fixtures. Pinned Ruff lint/format and ty passed for the HTTP tooling. Independent source review found no unresolved material findings after the fixes; the reviewer did not independently rerun behavioral suites. Concise evidence and hashes of original execution logs are in [test-evidence.json](test-evidence.json). Behavioral red evidence was retained for admission, unbind/global enablement, receipt recovery and warming. The initial wider P1 port failed compilation against missing/in-progress contracts; that initial red was not a fully executing behavioral baseline.

The final HTTP snapshot's1986 assets and copied source hashes matched, with no symlinks or remaining owned processes. Tests used isolated homes, synthetic data and local scripted providers only. Native process tests used a test-only Linux subreaper because container PID1 did not reap orphan children; assertions and timeouts were unchanged.

## Reproduction

Use Linux with Gleam1.19.0, Erlang/OTP29.0, Python3.11.16, rebar3 3.25.1, Go1.26.8, Rust/Cargo1.98.1, Ruff0.16.10 and ty0.0.85. Use authorized source access and ordinary verified dependency channels. Do not supply real provider credentials.

Check out Albedo at its exact base as the sibling `albedo` directory of this Successor checkout. Apply the cumulative host patch with `git apply --check` then `git apply --index`; `git write-tree` must equal the reconstructed Albedo tree above. Do not apply the historical six-patch series. Build the renderer with `cargo build --release --locked --manifest-path native/render/Cargo.toml`, copy `native/render/target/release/albedo-render` to `priv/bin/albedo-render`, and build the CLI with `go -C cli build -buildvcs=false -o bin/albedo ./cmd/albedo`.

With an allowlisted PATH and isolated HOME, ALBEDO_HOME and test-temporary directory, run:

- Host: `gleam check`, `gleam format --check src test`, and `gleam test` under a test-only subreaper when required by container PID1.
- Successor: `python3 compat/main_identity/run.py` (45 package tests plus check/format).
- `compat/p1/fixture_app`: `gleam test`, `gleam check`, `gleam format --check src test` (37 tests).
- `compat/p3a/fixture_app`: `gleam test`, `gleam check`, `gleam format --check test` (21 tests).
- `apps/successor_daemon`: `gleam check`, `gleam format --check src test`, `gleam test` (1 composition test).
- Follow [HTTP snapshot and acceptance instructions](../../../compat/live_identity/README.md) for the32 actual-daemon cases and pinned Python checks.
- Follow [P0 instructions](../../../compat/p0/README.md) for the12 startup cases. Do not run the historical freeze scripts against current source.

## Remaining limits

This is bounded local qualification, not production or complete host qualification. The unchanged full `./test.sh` gate was not passed: missing Nix and remaining treefmt/glinter infrastructure, plus browser Chrome CDP startup, remain unresolved. Historical Successor aggregate qualification remains FAILED/OPEN. The renderer was built from the pinned source and exercised by passing tests; no separate full renderer/aggregate gate is claimed.

No delegate inheritance, general persona/default management, deployed-data migration or background memory is implemented. Bound child/fork/rewind operations refuse before effects. Identity remains opt-in with explicit authenticated setup/binding. No real-provider, remote-CI, deployment or production-readiness claim is implied. Any automatically triggered GitHub checks must be reported separately from these recorded local results.
