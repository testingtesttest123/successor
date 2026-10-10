# Albedo Personality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable, editable, source-backed personality to native Albedo, with one enduring identity by default and read-only temporary delegation contexts.

**Architecture:** An extension owns the SQLite domain ledger, validated foreground operations, bounded recall, and request projection. A generic request-context contribution refreshes each inference without replacing static prompt caching; a small core admission ledger prevents bound sessions from running without their required capability. Existing LCM owns automatic episodic compaction, using a captured persona policy and trusted source envelopes, while curated memories remain explicit foreground writes.

**Tech Stack:** Existing Gleam/BEAM, SQLite/sqlight, Python fake-provider E2E harness, and native Go client; Python 3.11, OTP 29, Gleam 1.19, repository-pinned Nix tools. No new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-10-10-personality-layer-design.md`, approved by the user on 2026-10-10. Published approved copy: Successor commit `f66a618529092bdb6bcd8f8fdbb147422d78180a`, `docs/experiments/albedo-personality-design.md`. Albedo baseline: `47735ec493f3e3a6ac73b619495098437759e0c0`.

## Global Constraints

- “The default is one persistent identity. Forks and subagents are temporary working contexts for that identity, not newly enduring selves.”
- “Additional permanent identities require a deliberate user creation operation, separate from delegation or transcript branching.”
- “This slice starts no new background model calls.” Existing inference-triggered LCM summarization remains allowed.
- “Persona text cannot grant permissions.” Host/tool authorization remains authoritative; no runtime/code self-modification.
- “Use existing dependencies.” No second harness, new actor, vector database, extraction worker, automatic waking, scheduling, or separate summarization engine.
- “Current identity/instructions: 12 KiB UTF-8 total, at most 4 KiB per editable field.”
- “A memory/relationship/commitment text revision: 4 KiB; at most 16 evidence links and 16 tags.”
- “A mutation request: 64 KiB; at most 32 records.”
- “An import or handback: at most 256 KiB and 128 records, validated before commit.”
- “Request-only recall: at most 8 KiB and at most 16 records, including labels and source pointers.”
- “Paged inspection: 50 records or 8 KiB rendered text per page, whichever comes first.”
- “10,000 current records and 100 MiB” ordinary admission guards; “a further 10 MiB exclusively for identity edits, corrections, retractions, and commitment-status changes.” Receipts/events count, nothing silently expires, user-only capacity changes do not enlarge prompt limits.
- Owner candidate queries use “at most 256 candidates in total.” Delegates use only their captured manifest/local scope.
- “No provider work runs from ManagedPlugin.observe”; no provider/network work inside store queries or transactions.
- “Personality migrations create extension tables; a narrow core migration adds only the required-capability admission table.” No core fork-row-map migration.
- “The first slice supports archiving/unbinding, not irreversible erasure.”
- Use `ALBEDO_NO_BROWSER=1`; `./test.sh` is the repository gate. Default tests are real-daemon E2E with scripted providers; restart/global-state fixtures are `@exclusive`. Never nest E2E inside `gleam test` or rebuild while its build lock is held.
- Preserve existing Successor files and entrypoints, except an explicit top-level README addition identifying the separate subtree. Publish only a fresh branch of `testingtesttest123/successor`; no upstream push, main push, or automatic merge. Retain `LICENSE`, `THIRD_PARTY_NOTICES.md`, and vendored notices.
- This is a plan only. Wait for plan review and execution-method selection before installation, dependency fetching, project creation, or product implementation.

## Review Focus

1. Multi-byte UTF-8 at exact byte limits, including labels: reject over-limit mandatory state and drop whole optional records (Tasks 3, 6, 10).
2. A source row deleted, reordered during tool recovery, or replaced at the same sequence: never return different evidence under an old reference (Tasks 5, 11).
3. A child using existing `agents.messages`, `search_messages`, or `sessions` instead of personality recall: enforce the same bounded grants, without changing ordinary unbound behavior (Task 9).
4. Transport retry after a concurrent identity edit: resend the exact prepared snapshot; only the next preparation advances (Task 4).
5. Ordinary storage full during a correction, followed by corrective reserve exhaustion: preserve readability and atomicity, and report genuine refusal (Task 11).

---

## Ownership and file map

Paths in Tasks 1–11 are relative to the Albedo project root, eventually published as `albedo-personality/` in Successor. In task file lists, `personality/` abbreviates `src/albedo/harness/extensions/personality/`, `harness/` abbreviates `src/albedo/harness/`, and `daemon/` abbreviates `src/albedo/daemon/`; brace lists expand to the named files, not directories to stage wholesale. Do not edit the original Successor runtime.

New personality modules under `src/albedo/harness/extensions/personality/`:

- `types.gleam`: domain ADTs, revisions, errors, operation envelopes; no persistence or providers.
- `ledger.gleam`, `migrations/schema.gleam`: schema, short transactions, immutable records, heads, receipts, accounting, cleanup.
- `domain.gleam`: authority, editable fields, record transitions, revision validation; one mutation path for model/user adapters.
- `sources.gleam`: bounded source resolution, grants, digest/availability checks and provenance ceiling.
- `recall.gleam`: indexed candidates and deterministic whole-record selection.
- `projection.gleam`: immutable snapshot rendering and budget diagnostics; no writes.
- `working.gleam`: temporary-context attachment/refresh/closure and explicit report acceptance.
- `interchange.gleam`: versioned import preview/apply validation; inert JSON only.
- `extension.gleam`, `tools.gleam`, `service.gleam`: native registration, recoverable model tools, authenticated user page/API. Use direct tools rather than a second Python client API.

Shared changes:

- New `src/albedo/daemon/session_requirements.gleam`: generic core-required-capability table and connection-level helper, initialized by `conversation.gleam`.
- New `src/albedo/harness/request_context.gleam`: provider-neutral contribution types/composition, no personality imports.
- `harness/extension.gleam`, `extension/composition.gleam`, `runtime.gleam`, `loop.gleam`, `compaction.gleam`: loaded-active request contributions, admission, effective sizes, final request assembly and summary policy.
- `daemon/session.gleam`, `session_configure.gleam`, `session_deletion.gleam`, `context_snapshot.gleam`: idle mutations, human binding, lifecycle cleanup and actual-request inspection. Keep `session_prompt.gleam` static pinning behavior unchanged.
- `harness/extensions/lcm/extension.gleam`: preserve `SourcedEntry` boundaries into leaf/condensation envelopes; existing graph and fork transaction remain authoritative.
- `daemon/agents.gleam`, `registry.gleam`, `harness/extensions/agents/extension.gleam`: attach a delegate before submission, close receipts, constrain delegate read adapters. Do not change transcript fork algorithms.
- `harness/extensions.gleam`: install personality but leave ordinary Albedo default sessions unbound; explicit setup selects it and configures the one default identity.
- New `robot-docs/personality.md`, `docs/personality-interchange-v1.md`; update existing subsystem docs in the task changing that subsystem.

Tests:

- New `test/e2e/personality_support.py`: thin helpers on `harness.Albedo`, `Provider`, `Reply`, and `inspect_support`; no process/server/database replacement.
- New `test/e2e/personality_identity_test.py`, `personality_context_test.py`, `personality_memory_test.py`, `personality_lcm_test.py`, `personality_records_test.py`, `personality_delegation_test.py`, `personality_import_test.py`, `personality_recovery_test.py`.
- Extend `test/e2e/migrations_test.py`, `agents_test.py`, `session_delete_test.py` only for their owned regressions; retain existing LCM fork tests.
- Preserve `test/harness/api_docs_test.py` for Python bindings; test native tool discoverability through E2E by comparing actual request tool names/schema descriptions with the declared personality public API. Do not make a Python-namespace test pretend to enumerate Gleam native tools. An embedded no-strategy test belongs in `test/harness/personality_context_test.gleam` with a module comment explaining that the production daemon always chooses a strategy and E2E cannot reach this host configuration. Race/failure probes, if needed, follow existing typed Erlang test probes and stay in `test/e2e/`; no production HTTP fault-injection endpoint.

## Interface decisions used by the tasks

These are new interfaces, not claims that the baseline already provides them. Use qualified imports for the types below. Public JSON errors have `code`, `message`, and bounded `current_revisions` where relevant; codes are `unbound`, `required_capability_missing`, `forbidden`, `conflict`, `operation_id_reused`, `invalid_source`, `source_unavailable`, `limit_exceeded`, `capacity_exhausted`, and `store_unavailable`.

`personality/types.gleam` owns:

- IDs as opaque strings; revisions as nonnegative `Int`. `Actor` is `Human | OwnerAgent(session: String) | DelegateAgent(session: String, context_id: String)`, assigned by adapters, never decoded from model JSON.
- `Identity(description: String, values: String, communication: String, instructions: String)`; `Authority(agent_identity_edits: Bool, agent_memory_edits: Bool, locked_fields: List(String))`; both edit flags default true.
- `Binding(persona_id: String, session: String, mode: Mode, revision: Int, prebinding_seq: Int, context_id: Option(String))`, `Mode = Owner | Delegate`.
- `SourceRef` variants for transcript ranges `(source_id, session, first_seq, last_seq, digest, actor, availability)`, imports `(source_id, receipt_id, origin, external_id, digest, availability)`, and optional LCM hint attached to canonical transcript reference. Never accept a caller-chosen availability or origin actor as trusted metadata.
- `Mutation(operation_id: String, expected_persona_revision: Int, expected_records: List(#(String, Int)), reason: String, changes: List(Change))`; `Change` variants: identity patch; remember/correct/retract/contradict; relationship edit/merge; commitment create/adopt/status. Human-only authority/limits/binding changes use separate typed user operations.
- `Receipt(operation_id: String, event_ids: List(String), persona_revision: Int, identity_revision: Int, record_revisions: List(#(String, Int)))`; replay must return the same receipt even if the head subsequently advanced.
- `Snapshot(binding: Binding, persona_revision: Int, identity_revision: Int, identity: Identity, authority: Authority, records: List(Record), sources: List(SourceRef), usage: Usage)`; `Record` carries stable ID/kind/current revision, text, provenance origins, uncertainty, links, tags, importance, pin, entity IDs, temporal scope, lifecycle/contradiction, and typed relationship or commitment fields.
- `Page(items: List(Record), next: Option(String), bytes: Int)`; cursors are opaque and scoped to session/binding revision/query, not free SQL or arbitrary session IDs.
- `DomainError(code: String, message: String, current_revisions: List(#(String, Int)))`.

Small additional contracts are defined in their owning task. Do not create a universal event framework or a generic repository abstraction.

## E2E assertion idiom

Use the existing `Provider` and native `Reply("python", tool_name="persona_edit", tool_arguments=mutation)` encoding supported by the harness; its historical `python` reply kind can carry any native tool name. Keep result extraction/request inspection in `personality_support.py`, whose helpers are thin API wrappers: `inspect_persona(app, session) -> dict`, `edit_persona(app, session, mutation) -> dict`, `read_source(app, session, source_id) -> dict`, and `tool_result(app, session, call_id) -> dict`. Human service helpers cannot substitute for the fake model tool call in tests that require model authority.

The following are assertion excerpts to put inside the named E2E tests, with values obtained from real API/tool/provider results. They pin behavior, not generated prose:

```python
# Task 2: test_human_setup_creates_one_default_and_binding_survives_restart
assert after_restart["persona_id"] == before_restart["persona_id"]
assert second_workspace["persona_id"] == before_restart["persona_id"]
assert persona_count == 1
# Task 3: test_identity_edit_is_atomic_revisioned_and_idempotent
assert replay == first_receipt
assert changed_payload["code"] == "operation_id_reused"
assert sorted(outcomes) == ["conflict", "ok"]
# Task 4: test_tool_edit_refreshes_next_request_with_static_pin_intact
assert next_snapshot["identity_revision"] == first_snapshot["identity_revision"] + 1
assert retry_requests[0] == retry_requests[1]
assert kernel_pid_after == kernel_pid_before
# Task 5: test_correction_displaces_old_claim_but_keeps_history
assert recalled["id"] == corrected["id"]
assert recalled["revision"] == corrected["revision"]
assert superseded_revision in [r["revision"] for r in explicit_history]
# Task 6: test_recall_is_bounded_stable_and_correction_aware
assert observation["candidate_count"] <= 256
assert len(selected) <= 16
assert len(rendered_recall.encode("utf-8")) <= 8192
assert superseded_revision not in selected_revision_ids
# Task 7: test_automatic_and_forced_lcm_receive_captured_policy_and_real_sources
assert envelope["identity_revision"] == captured_identity_revision
assert envelope["source_ranges"] == actual_compacted_ranges
assert persona_head_after_summary == persona_head_before_summary
# Task 8: test_relationships_and_commitments_survive_correction_and_restart
assert imported_commitment["status"] == "proposed"
assert adopted_commitment["status"] == "open"
assert len(same_name_entities) == 2
# Task 9: test_fork_and_fresh_delegate_keep_one_identity
assert child_snapshot["persona_id"] == parent_snapshot["persona_id"]
assert child_snapshot["mode"] == "delegate"
assert forbidden_edit["code"] == "forbidden"
assert persona_count_after_closure == 1
# Task 10: test_import_preview_then_atomic_apply_preserves_origin
assert receipt_on_replay == receipt_on_apply
assert rejected_apply_head == head_before_invalid_apply
assert "imported" in accepted_record["origins"]
# Task 11: test_commit_receipt_recovers_after_caller_death
assert recovered_receipt == committed_receipt
assert matching_event_count == 1
assert exhausted_correction["code"] == "capacity_exhausted"
assert source_after_deletion["code"] == "source_unavailable"
```

## Verification workflow used for every product task

Run commands from the Albedo root with the validated Task 1 toolchain and `ALBEDO_NO_BROWSER=1`. Before E2E after changing compiled code:

`go -C cli build -o bin/albedo ./cmd/albedo`

`export ALBEDO_TEST_DAEMON="$(test/snapshot-daemon.sh /tmp/albedo-personality-daemon-<task>)"`

Each task's red run must compile and fail on its named behavioral assertion, not a missing interpreter, syntax error, or absent test discovery. Initial unimplemented API failures such as HTTP 404 or missing tool are legitimate red results. Run `gleam check`, format with `gleam format src test` and `ruff format priv/python test`, then `ruff check` and `ty check`. Before every product commit run `./test.sh` and inspect its actual result; report baseline blockers distinctly and do not label blocked suites passing. Stage only the task's listed paths. The commands below abbreviate repeated rebuilding as “refresh the daemon snapshot”; they do not permit using a stale binary.

### Task 1: Establish the isolated toolchain and baseline

**Files:** Read `agents.md`, `.agents/skills/writing-tests/SKILL.md`, `priv/skills/design-preflight/SKILL.md`, `robot-docs/{runtime,extensions,context,compaction,migrations,provider-requests,agents,commands}.md`, `flake.nix`, `flake.lock`, `test.sh`. No product changes. Keep baseline logs under `/tmp`.

**Interfaces:** Consumes the pinned checkout and execution approval. Produces an isolated implementation branch/worktree, reproducible tool environment, baseline gate results, and the original revision/file inventory used by publication.

- [ ] **Step 1:** After the review gate, use `superpowers:using-git-worktrees`; verify the baseline SHA and clean/known status, preserving the approved spec/plan and other agents' work. Record Successor base SHA and file hashes separately; do not modify it yet.
- [ ] **Step 2:** Discover `gleam`, `erl`, `nix`, `python3`, `go`, `cargo`, `ruff`, `ty`, `uv`, and repository-pinned glinter on PATH and in `/workspace/shared/tooling`, `/workspace/shared/pinned`, and standard official installation prefixes. Confirm origin/version before executing discovered tools. The planning shell currently lacks Gleam/Erlang/Ruff/ty/Nix on PATH; this is a blocker to establish, not a failing feature test.
- [ ] **Step 3:** Prefer the pinned `nix develop` environment. If absent, bootstrap from official vendor/package-registry distributions after execution approval, preserving OTP 29 and Gleam 1.19 requirements; use `uvx ruff@0.16.10` and `uvx ty@0.0.85` only as documented fallbacks. Fetch existing Gleam dependencies through Gleam; never hand-edit `manifest.toml`. Do not install a new runtime package for this feature. Stop and report exact acquisition/network blockers if a compliant toolchain cannot be established.
- [ ] **Step 4:** Verify `gleam --version`, OTP release, Python 3.11, pinned Go/tool consistency, Ruff/ty versions; run `gleam check`, then `./test.sh`. Expected: all baseline suites pass, or a documented reproducible baseline failure before feature work begins. No live provider credentials.
- [ ] **Step 5:** Record commands, versions, exit codes, and log paths in the task report. Commit only an intentional setup/documentation change if necessary; do not make an empty “baseline passed” commit or commit downloaded tools/builds/logs.

### Task 2: Add durable admission and user-only identity binding

**Files:** Create `daemon/session_requirements.gleam`, `personality/{types,ledger,extension,service}.gleam`, `personality/migrations/schema.gleam`, `test/e2e/personality_support.py`, `personality_identity_test.py`; modify `daemon/{conversation,session,session_configure}.gleam`, `harness/{command,extensions,runtime}.gleam`, `test/e2e/migrations_test.py`, `robot-docs/{extensions,migrations,personality}.md`.

**Interfaces:**
- `session_requirements.initialise(store.Store) -> Result(Nil, String)`; `set_in(sqlight.Connection, session: String, capability: String, required: Bool) -> Result(Nil, String)`; `check(store.Store, session: String, loaded: List(String)) -> Result(Nil, String)`. Capability key is `personality`; missing/unreadable core admission state is an error, never interpreted as no requirement.
- `ledger.initialise(store.Store) -> Result(Nil, String)`; `ledger.capture(store.Store, session: String, query: String) -> Result(Snapshot, DomainError)`.
- New generic `command.StateOp` case `ApplyIdle(run: fn(store.Store, String) -> Result(json.Json, String))`: daemon executes the bounded transaction callback only while not running or booting. Never call the bridge recursively or do network/source scanning in it.
- User service: `POST /extensions/personality/personas` creates one empty identity with operation ID/config; `POST /extensions/personality/sessions/{id}/binding` binds an explicitly selected existing identity after pre-binding-history disclosure; `DELETE` that binding unbinds while idle. `GET .../sessions/{id}` inspects. User setup can select the configured default for new explicitly personality-enabled owner sessions. `persona_create` is the user action name, not a model tool.

- [ ] **Step 1:** Write `test_human_setup_creates_one_default_and_binding_survives_restart` and `test_enabled_unbound_and_quarantined_bound_sessions_send_no_request`; assert `persona_count == 1`, same ID across workspaces/new owner sessions, explicit binding revision, `len(provider.requests) == 0` on blocked preparations, unbound ordinary session still answers. Add exclusive fresh/upgrade/interrupted migration cases; existing transcript bytes and LCM rows remain unchanged.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_identity_test` and `python3 test/e2e/run.py migrations_test`. Expected red: setup unavailable or admission missing.
- [ ] **Step 3:** Implement extension schema and user service/page registration; explicit creation/default selection, idle bind/unbind, pre-binding boundary, archive refusal with active bindings. Register personality installed, not automatically bound. Commit binding and core requirement in one transaction through `set_in`; do not let model-callable commands invoke creation/authority/default changes. Run requirement checks before any bound request even when the extension is absent/quarantined. A selected-but-unbound personality plugin reports setup required.
- [ ] **Step 4:** Repeat tests including busy bind/rebind rejection, user-only settings, no copying during additional human creation, unavailable binding store, failed schema installation with persistent guard, and ordinary extension reload. Run the full gate; expected pass with unchanged ordinary behavior.
- [ ] **Step 5:** Stage only listed changed paths; commit `feat: add explicit persona setup and fail-closed session admission`.

### Task 3: Implement atomic revisioned identity edits and receipts

**Files:** Create `personality/{domain,tools}.gleam`; modify `personality/{types,ledger,extension,service}.gleam`, `test/e2e/personality_identity_test.py`, `test/harness/api_docs_test.py` only if its scanner needs to see the new model-visible documentation file, `robot-docs/personality.md`.

**Interfaces:** `domain.mutate(store.Store, session: String, actor: Actor, mutation: Mutation) -> Result(Receipt, DomainError)`; `ledger.receipt(store.Store, session: String, operation_id: String) -> Result(Option(Receipt), DomainError)`. Register `persona_inspect` and `persona_edit` as native `extension.Tool` values with `invoke`/`recover`; tool call ID is the trusted origin receipt, user-supplied operation ID is idempotency identity, and the persisted result links both. `persona_edit` accepts no persona ID, actor override, ownership, binding, or permission fields.

- [ ] **Step 1:** Write `test_identity_edit_is_atomic_revisioned_and_idempotent`: same payload/operation returns equal receipt and one event; changed payload returns `operation_id_reused`; stale head returns `conflict`; lock and edit-flag tests return `forbidden`; identity fields totaling 12 KiB pass only when each is <=4 KiB, next UTF-8 byte fails without head advance. Race two real owner sessions using provider barriers and assert `sorted(outcomes) == ['conflict', 'ok']`.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_identity_test`. Expected red: tools missing or assertions fail on revision behavior.
- [ ] **Step 3:** Implement canonical payload hashing and single store transaction: validate binding/authority, check prior operation receipt before stale-head comparison, validate expected head and record revisions, append immutable event/revision, update pointers and aggregate head, account bytes, persist exact response. Identity head advances only for identity edits. Scope receipt keys to their persona/origin authority; no cross-persona receipt oracle. `recover` uses trusted tool-call origin and never repeats an unknown write. Human edits share `domain.mutate`, with separately authenticated actor assignment.
- [ ] **Step 4:** Run identity tests, docs invariant, and full gate. Expected: typed conflicts, no partial writes, no model actor spoofing, exact receipt recovery. Cancellation after commit leaves the committed edit visible.
- [ ] **Step 5:** Commit only changed task files as `feat: add optimistic persona edits and durable operation receipts`.

### Task 4: Refresh one bounded request snapshot on every preparation

**Files:** Create `harness/request_context.gleam`, `personality/projection.gleam`, `test/e2e/personality_context_test.py`, `test/harness/personality_context_test.gleam`; modify `harness/{extension,runtime,loop,compaction}.gleam`, `harness/extension/composition.gleam`, `daemon/context_snapshot.gleam`, `personality/extension.gleam`, `robot-docs/{extensions,context,provider-requests}.md`.

**Interfaces:**
- `request_context.Budget(capacity_tokens: Option(Int), capacity_source: Option(String), static_tokens: Int, remaining_tokens: Option(Int))`; `Input(store: store.Store, session: String, loaded: List(String), query: String, budget: Budget)`; query is a UTF-8-safe recent user/steering excerpt capped at 4 KiB.
- `Block(name: String, content: String, mandatory: Bool, estimated_tokens: Int)`; `Contribution(snapshot_id: String, instructions: List(Block), data: List(Block), summary_policy: Option(SummaryPolicy), diagnostics: List(String), selected_ids: List(String), candidate_count: Int, excluded_count: Int)`; `Prepared(contributions: List(Contribution), estimated_tokens: Int)`.
- `SummaryPolicy(id: String, revision: String, instructions: String, lineage: Lineage)`; `Lineage(subject: String, binding_revision: Int, role: String, supplied_through: Int, context_id: Option(String), grants: List(SourceGrant))`, `SourceGrant(session: String, first_seq: Int, last_seq: Int, digest: String)`. These generic types contain no domain validation or ledger access. Keep `request_context` independent of `compaction` to avoid an import cycle; runtime translates existing capacity metadata into Budget.
- New `extension.RequestContextPlugin(prepare: fn(request_context.Input) -> Result(request_context.Contribution, String))`; `composition.request_context(composition.Composition) -> List(fn(request_context.Input) -> Result(request_context.Contribution, String))` uses loaded-active only.
- `projection.prepare(request_context.Input) -> Result(request_context.Contribution, String)` captures once via `ledger.capture`. Add request-context data to `compaction.Prepared`, including the no-strategy result; all constructors get an empty default helper.

- [ ] **Step 1:** Write `test_tool_edit_refreshes_next_request_with_static_pin_intact` for both fake provider protocols; compare semantic identity field/revisions, stable static prefix, changed actual head hash, unchanged kernel PID, no duplicate block in transcript. Add steering/next-turn/restart boundaries; scripted 502 retry concurrent with a user edit must have equal prepared payloads on both attempts and a new revision on the following preparation.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_context_test`; run `gleam test` separately for the embedded no-strategy case. Expected red: missing contribution or old pinned identity remains.
- [ ] **Step 3:** In `runtime.view_scoped`, guard admission, capture contributions once before strategy/no-strategy branching, reserve mandatory/optional size in effective pinned estimate, then pass history to the existing strategy. In `loop.run`, retain `settle_pin` on original/prepared conversation history, append dynamic behavioral instructions only at final request assembly, and prepend separate data inputs before prepared history. Do not pass request-only data into transcript, LCM raw inputs, `PinnedPrompt`, or static capability diffs. Transport retries reuse the already assembled request. Projection/read-only inspection never invokes a summarizer; forced compact uses this same capture path.
- [ ] **Step 4:** Extend inspector with actual dynamic names, snapshot/identity/aggregate revisions, estimates, candidate/selected/excluded counts. Continue hashing the actual final instructions/input prefix and accounting actual provider requests; do not add a second request transcript or core schema migration. Snapshot IDs are in rendered metadata and inspector; hashes account for that content. Verify mandatory-fit refusal, uncertain unknown-window report, conflicting summary-policy contributors, callback/store error, loaded-versus-desired selection, no strategy, rolling, LCM, and switching. Full gate passes.
- [ ] **Step 5:** Commit `feat: compose immutable request-time personality context`.

### Task 5: Add source-backed curated memory and corrections

**Files:** Create `personality/sources.gleam`, `test/e2e/personality_memory_test.py`; modify `personality/{types,ledger,domain,tools,service}.gleam`, `robot-docs/personality.md`.

**Interfaces:** `sources.resolve(store.Store, binding: Binding, refs: List(SourceRef)) -> Result(List(SourceRef), DomainError)`; `sources.expand(store.Store, session: String, source_id: String, cursor: Option(String)) -> Result(SourcePage, DomainError)` where `SourcePage(text: String, source: SourceRef, next: Option(String), bytes: Int)`. `domain.inspect(store.Store, session: String, record_id: String, history: Bool, cursor: Option(String)) -> Result(Page, DomainError)`. `persona_edit` adds typed memory changes; `persona_source` accepts only a previously authorized source ID and bounded page cursor.

- [ ] **Step 1:** Write `test_memory_survives_restart_with_exact_sources`, `test_correction_displaces_old_claim_but_keeps_history`, and `test_source_scope_and_provenance_cannot_be_spoofed`. Assert stable memory ID, new revision, old history visible only explicitly, actual source range/digest/actor, retained conflicting origin, and rejection of guessed session/range/foreign persona source. A user's assertion is represented as being told, not independently verified.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_memory_test`. Expected red: memory/source operations unavailable.
- [ ] **Step 3:** Add revision/source/link tables and indexed persona scope. Validate source ranges against actual transcript rows and binding boundary, canonicalize digests, assign provenance ceiling from trusted origins, and recheck source/head validity inside the short commit after bounded prevalidation. Preserve multiple supports/contradicts/corrects links. Never decode actor or provenance elevation as authority. A missing LCM hint falls back to the exact canonical range; digest mismatch reports unavailable, never substitutes another row.
- [ ] **Step 4:** Run restart, hostile evidence, mixed-origin, pre-binding-history, retraction, explicit contradiction, missing hint, deleted/reordered source, and 16-link/16-tag/4-KiB boundary tests. Ensure history inspections are paged at 50 records/8 KiB and do not truncate origin labels. Full gate passes.
- [ ] **Step 5:** Commit `feat: persist source-backed memories and auditable corrections`.

### Task 6: Select bounded deterministic recall

**Files:** Create `personality/recall.gleam`; modify `personality/{ledger,projection,tools}.gleam`, `test/e2e/{personality_memory_test,personality_context_test}.py`, `robot-docs/personality.md`.

**Interfaces:** `recall.select(snapshot: Snapshot, query: String, budget: request_context.Budget) -> Selection`; `Selection(records: List(Record), source_ids: List(String), selected_reasons: List(#(String, String)), excluded_count: Int, rendered_bytes: Int)`; `recall.search(store.Store, session: String, query: String, cursor: Option(String)) -> Result(Page, DomainError)`. Native `persona_recall` exposes paged explicit curated/episodic search, never arbitrary session search. Add `recall.episodes(store.Store, session: String, query: String, cursor: Option(String)) -> Result(EpisodePage, DomainError)`; `EpisodePage` contains at most 50 results/8 KiB, each with optional LCM node hint, exact canonical source range, derived-evidence label, availability and next cursor. Page only across owner-authorized source sessions or delegate manifest/local scope; source expansion still uses `persona_source`. It does not duplicate the current frontier in automatic recall.

- [ ] **Step 1:** Write `test_recall_is_bounded_stable_and_correction_aware`: >256 eligible records, old exact-match claim corrected, tied recency/importance, open commitments, and oversized multi-byte records. Assert candidates <=256, selected <=16, rendered bytes <=8192, stable ID tie order, superseded ID absent, and unresolved contradiction accompanying its selected claim. Explicit paging reaches an otherwise excluded old record; episodic paging finds a previously authorized older session summary and refuses an unrelated session.
- [ ] **Step 2:** Refresh snapshot; run memory/context E2E files. Expected red: no recall or unbounded/incorrect order.
- [ ] **Step 3:** Query indexed categories within one captured head: pin/entity-tag/open-commitment/recency, de-duplicate to at most 256 total. Use existing lowercase/string matching; order by pin, match, importance, open/due relevance, recency, stable ID. Reserve contradiction/correction room before adding optional claims. Drop whole labeled records to the smaller of 8 KiB and remaining request allowance; mandatory identity failures are errors. Never scan full history or duplicate LCM frontier. Extend capture to return these bounded candidates under one store-owned read, rather than rereading heads during rendering.
- [ ] **Step 4:** Test unknown/small capacity, matching label bytes, query cap, source-scoped cursor tampering, no hidden expiry, inspector reasons and exclusion counts, unchanged transcript and no compaction requirement. Full gate passes.
- [ ] **Step 5:** Commit `feat: add bounded source-authorized persona recall`.

### Task 7: Make existing LCM compaction persona-aware

**Files:** Modify `harness/{compaction,loop,runtime}.gleam`, `harness/extensions/lcm/extension.gleam`, `personality/projection.gleam`, `daemon/context_snapshot.gleam`; create `test/e2e/personality_lcm_test.py`; update `robot-docs/{compaction,context,personality,provider-requests}.md`.

**Interfaces:** Add `summary_policy: Option(request_context.SummaryPolicy)` to `compaction.Context`, defaulting to existing generic instructions. Add `SummaryEvidence` to `SummaryRequest`: `Leaves(session: String, ranges: List(#(Int, Int)), lineage: Option(Lineage)) | Nodes(session: String, nodes: List(#(Int, Int, Int)), lineage: Option(Lineage)) | NoEvidence`. The node tuple is `(node_id, first_seq, last_seq)`. `SummaryEvidence` also carries `List(Attribution(first_seq: Int, last_seq: Int, origin: String, actor: Option(String)))` from retained sourced rows; no model-decoded attribution. `SummaryRequest` carries optional policy ID/revision for actual request inspection; summarizer rendering owns the typed envelope. `summarize_bounded(context: compaction.Context, inputs: List(types.Input), evidence: SummaryEvidence, limit: Int) -> Result(String, String)` and `attempt_summary(context: compaction.Context, inputs: List(types.Input), evidence: SummaryEvidence, limit: Int) -> Result(String, String)` preserve the captured values across shrink retry.

- [ ] **Step 1:** Write `test_automatic_and_forced_lcm_receive_captured_policy_and_real_sources`: trigger normal threshold and `/compact`; provider barriers permit a concurrent edit during compaction. Assert summary request has captured revision, actual leaf row bounds/actors, input excludes recall block, returned graph leaf ranges match source, and persona head is unchanged by summary generation. Unbound LCM keeps generic policy; rolling stays unchanged.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_lcm_test` and `python3 test/e2e/run.py lcm_preparation_test`. Expected red: policy/envelope absent.
- [ ] **Step 3:** Preserve `SourcedEntry` in `summarize_leaves` until typed evidence creation. Include branch-local bounds and overlapping supplied/owner/delegate intervals; original parent refs only from independently validated grants. At condensation pass each child node ID/range. Render evidence as data with captured instructions; count envelope cost in leaf/condensation input limits. Bound envelope to 4 KiB and 32 intervals; when detailed attribution cannot fit, include exact local range/node identity with `attribution=unknown`, requiring source expansion. Do not invent seq correspondence. Keep complete-unit boundaries, immutable sources, retries/output caps, graph commit/cursor rules and existing fork inheritance unchanged.
- [ ] **Step 4:** Test hierarchical condensation, pre-binding prefix, inherited prefix, report text hostile to policy, unknown-attribution fallback, summary growth retries, failed summarizer cursor unchanged, policy changes applying only to new calls, and old node provenance not relabeled current. Actual sent summarizer instruction/envelope metadata is inspectable and its existing request accounting hashes/cost reflect the complete request. No tools on summarizer, no curated-domain writes, no extra background call. Full gate passes.
- [ ] **Step 5:** Commit `feat: add trusted persona attribution to native LCM compaction`.

### Task 8: Persist relationships and explicit commitment adoption

**Files:** Modify `personality/{types,ledger,domain,tools,recall,service}.gleam`; create `test/e2e/personality_records_test.py`; update `robot-docs/personality.md`.

**Interfaces:** Extend Task 3 `Change` with `RelationshipEdit(id, expected_revision, label, aliases, description, sources)`, `RelationshipMerge(source_id, target_id, expected_revisions, reason)`, `CommitmentCreate(description, entity_id, owner, due_time, sources)`, `CommitmentAdopt(id, expected_revision, reason)`, `CommitmentStatus(id, expected_revision, status, outcome_sources, unverified_assertion)`. Due times are an optional ISO-8601 offset-bearing instant plus the supplied timezone label (preserve the label; do not guess a local-zone conversion); reject invalid/ambiguous unqualified local timestamps. Relationship and commitment revisions use the same receipt/head transaction.

- [ ] **Step 1:** Write `test_relationships_and_commitments_survive_correction_and_restart`: same-name entities remain separate; explicit merge produces audit links; imported/reported promise stays `proposed` until adoption; status changes require expected revision and completion evidence or explicit unverified assertion. Assert no schedule/reminder rows or background provider calls appear.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_records_test`. Expected red: missing record operations.
- [ ] **Step 3:** Implement source-backed revisions and transitions with human/model actor validation; aliases never imply automatic entity merge. Owner-origin explicit promises may create open commitments; imports/reports may not. Relationship merge is auditable and atomic; it does not rewrite historical source origins. Include relevant open/due commitments in bounded recall without execution.
- [ ] **Step 4:** Test stale merge/status, timezone rejection, hostile descriptions, correction/retraction, multiple source origins, and restart recall. Verify ordinary limits and edit flags. Full gate passes.
- [ ] **Step 5:** Commit `feat: track sourced relationships and adopted commitments`.

### Task 9: Attach temporary delegates and accept attributed reports

**Files:** Create `personality/working.gleam`, `test/e2e/personality_delegation_test.py`; modify `personality/{types,ledger,tools,projection,service}.gleam`, `daemon/{agents,registry}.gleam`, `harness/extensions/agents/extension.gleam`, `test/e2e/agents_test.py`, `robot-docs/{agents,personality}.md`.

**Interfaces:** `working.attach(store.Store, parent: String, child: String, operation_id: String, expected_parent_revision: Int, manifest: ContextManifest) -> Result(ContextReceipt, DomainError)`; `working.refresh(store.Store, parent: String, context_id: String, expected_context_revision: Int, expected_parent_revision: Int, operation_id: String, manifest: ContextManifest) -> Result(ContextReceipt, DomainError)`; `working.close(store.Store, context_id: String, expected_context_revision: Int, operation_id: String) -> Result(ContextReceipt, DomainError)`.
`ContextManifest(record_ids: List(String), sources: List(SourceRef))` is at most 128 records/256 KiB including captured text; snapshot instructions keep 12-KiB limit. `ContextReceipt` includes context ID/revision, persona ID, captured identity revision, parent/child IDs, supplied-through boundary and lifecycle. `Report` is version 1, context/revision, operation ID, candidates with exact child/granted sources. `working.report(store.Store, child: String, report: Report) -> Result(ContextReceipt, DomainError)`; `working.accept(store.Store, owner: String, expected_persona_revision: Int, operation_id: String, context_id: String, report_revision: Int, selected_ids: List(String)) -> Result(Receipt, DomainError)`.
Native tools `persona_report`, `persona_accept`; user/owner delegate creation goes through the authorized agent runner, never `persona_create`.

- [ ] **Step 1:** Write `test_fork_and_fresh_delegate_keep_one_identity`: compact a parent across a boundary, create existing native fork and fresh child, explicitly attach both before inference. Assert complete-prefix LCM inheritance unchanged, persona count exactly one through restart/report/closure, captured revision unchanged after parent edit, exact local supplied-prefix bounds, and no invented original-row mapping. Unattached personality-enabled child sends zero provider calls.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_delegation_test` and `python3 test/e2e/run.py agents_test`. Expected red: unsafe inherited owner behavior or missing attachment/report.
- [ ] **Step 3:** Split `registry.create_child` scheduling at its existing create-before-mail/submit boundary so extension-owned attachment succeeds before task submission. Extend `agents.Spawn` with `before_submit: fn(store.Store, String) -> Result(Nil, String)`; the agents extension supplies a closure over the validated manifest/parent/operation and `working.attach`, rather than importing personality domain into the registry. Add `before_close: fn(store.Store, String) -> Result(Nil, String)` to `agents.Close`; the agents extension supplies `working.close` and ordinary sessions supply no-op callbacks. Restart closure and session deletion invoke the extension cleanup owner directly through installed cleaners, not an in-memory callback registry. The callback is short and idempotent, commits captured identity/context, boundary, grants, binding and core requirement together; failure returns child ID + error and submits no task. Native forks remain unchanged and unbound until explicit attachment. Refresh changes only captured context revision, never authority. Close invokes its passed callback before family close/release; retry uses the same context receipt. Keep operations idempotent across failure between the two lifecycle transactions.
- [ ] **Step 4:** Implement reported candidate storage and explicit owner acceptance with expected parent and report revisions. Validate each accepted source; atomically grant only its exact child ranges with new reported memory revisions. Candidate commitments remain proposed. No completion auto-merge and no persona head change from local reports/closure. Replays return original receipts. Delegates cannot edit persona, promote owner, create identity, broaden grants, or accept their own reports.
- [ ] **Step 5:** Add only a delegate-specific guard at the existing agents extension dispatch branches for `agents.messages`, `search_messages`, and session discovery; preserve local/exact-granted ranges and prevent these convenience routes from bypassing personality grants. `persona_source` uses the same source validation. Keep ordinary unbound and owner agent behavior unchanged. Do not create a general authorization framework or alter unrelated tools. If existing loaded capability composition cannot support this narrow guard without broader host changes, stop and report that decision rather than silently building a sandbox. Test cross-persona guessed IDs, overlapping/out-of-range grants, stale refresh, failed attach retry, foreign report acceptance, source deletion, report replay/payload mismatch, and default-memory leakage through same persona ID. Arbitrary shell/database access remains outside this trusted local isolation claim. Full gate passes.
- [ ] **Step 6:** Commit `feat: add read-only temporary contexts and explicit report handbacks`.

### Task 10: Validate inert versioned imports and user inspection

**Files:** Create `personality/interchange.gleam`, `test/e2e/personality_import_test.py`, `docs/personality-interchange-v1.md`; modify `personality/{service,tools,domain,ledger}.gleam`, `robot-docs/personality.md`.

**Interfaces:** `interchange.preview(store.Store, session: String, json_text: String) -> Result(Preview, DomainError)`; `Preview(schema_version: Int, accepted: List(ImportRecord), rejected: List(#(String, String)), manifest_digest: String)`; `interchange.apply(store.Store, session: String, actor: Actor, expected_revision: Int, operation_id: String, manifest: List(ImportRecord), expected_digest: String) -> Result(Receipt, DomainError)`. Format version exactly `1`; top-level fields `schema_version`, `origin`, `records`, optional `identity_suggestions`; record external IDs are scoped to receipt/origin and never trusted as local IDs. User service `/extensions/personality/sessions/{id}/imports/preview` and `/apply`; native tool `persona_import_preview` only; apply is an authenticated user foreground operation validated by the same domain. Ordinary owner agents can deliberately remember imported evidence through `persona_edit`, but that does not authorize bulk import apply. Identity suggestions never silently become active instructions.

- [ ] **Step 1:** Write `test_import_preview_then_atomic_apply_preserves_origin`: imported hostile directives/actor/provenance fields cannot elevate authority; proposed commitments stay proposed; unknown schema/version, byte/record overflow, bad source, duplicate ID and mixed valid/invalid submitted manifest fail atomically. Assert equal replay receipt and `operation_id_reused` on changed payload.
- [ ] **Step 2:** Refresh snapshot; run `python3 test/e2e/run.py personality_import_test`. Expected red: unavailable import interface.
- [ ] **Step 3:** Implement bounded JSON decoding/preview before transaction, then revalidate manifest digest/source/head/authority inside one commit. Preview rejection does not authorize applying the original input; the user submits an explicit accepted subset as a new bounded manifest. No executable migration, SQL, code, capability, authority, lock or binding fields. Keep imported source payload ownership explicit, origin receipt and digest inspectable. Document valid examples, errors, identity suggestions, history/export inspection and lack of arbitrary Connectome/Successor compatibility.
- [ ] **Step 4:** Complete `/personality` page for inspecting/editing identity, source history, recent events, relationships, commitments, locks, usage/headroom, imports and working contexts using existing resource page/service/client contracts. Add ClientPlugin declarations and regenerate checked client artifacts with the existing generator if needed; do not hand-edit generated files. Verify model cannot invoke human-only actions. Run import and docs invariant tests, then full gate.
- [ ] **Step 5:** Commit `feat: add validated persona interchange and user review surfaces`.

### Task 11: Close restart, deletion, capacity and admission failure gaps

**Files:** Create `test/e2e/personality_recovery_test.py`; modify `personality/{ledger,sources,working,extension}.gleam`, `daemon/session_deletion.gleam`, `test/e2e/{session_delete_test,migrations_test}.py`, `robot-docs/{personality,migrations}.md`. Add narrowly scoped typed test probes only when necessary.

**Interfaces:** `ledger.forget_session(db: sqlight.Connection, session: String) -> Result(Nil, String)` as extension `CleanPlugin`, using the existing deletion transaction; revokes live grants, closes contexts, removes binding/derived caches and marks surviving source refs unavailable without deleting independent persona records. `ledger.usage(store.Store, session: String) -> Result(Usage, DomainError)` where `Usage(current_records: Int, ordinary_bytes: Int, corrective_bytes: Int, ordinary_limit: Int, corrective_limit: Int)` counts stored UTF-8 payload bytes consistently across revisions/events/receipts/imports/contexts. User-only limit changes are revisioned.

- [ ] **Step 1:** Write exclusive `test_commit_receipt_recovers_after_caller_death` and `test_precommit_failure_rolls_back_every_pointer`: use a typed test probe/barrier at transaction boundaries to kill caller after commit before response, then restart and recover. Assert same receipt and one event; injected SQL failure leaves head, pointers, receipt, source grants and byte counters unchanged. Do not use timing sleeps as proof of the boundary.
- [ ] **Step 2:** Write exclusive `test_capacity_reserve_and_deleted_evidence`: reach 10,000 records and ordinary 100-MiB budget using deterministic fixture setup in the exclusive database, then exercise real APIs at boundaries. New records/imports refused; old pages still read; corrections/identity/status/retractions use only additional 10-MiB reserve; reserve+1 refused without advancement. Raise capacity as user, verify recall remains <=8 KiB/16. Delete an evidence session, reuse/reorder candidate rows, and assert unavailable source rather than unrelated text.
- [ ] **Step 3:** Refresh snapshot; run `python3 test/e2e/run.py personality_recovery_test`, `session_delete_test`, and `migrations_test` separately. Expected red only on the newly exposed missing failure behavior; previously passing regressions remain green.
- [ ] **Step 4:** Complete cleanup/accounting and recovery paths, including retention of minimum receipts referenced by surviving records and no hidden deleted transcript copies. Test missing personality table, quarantined plugin, source/store read failure, failed migration/restart, busy bind, selection disable versus explicit idle unbind, provider failure with and without preceding committed tool, archive refusal, no silent downgrade/destruction, and warm replay not counted as autobiographical work.
- [ ] **Step 5:** Run every personality file and full `./test.sh`; inspect actual provider payloads, source IDs/ranges, errors, byte bounds, and revision transitions. Extend docs invariant to every public tool/capability. Review that no test is a prose snapshot/slogan test and no background extraction was introduced. Save gate output under `/tmp`; commit `test: verify personality recovery isolation and capacity boundaries` with any accompanying fixes explicitly described.

### Task 12: Stage the separate Albedo subtree and publish the review branch

**Files:** Successor `albedo-personality/` copied from the verified implementation, top-level `README.md` additive link, approved design/plan documents as agreed. No other existing Successor file changes.

**Interfaces:** Consumes baseline hashes from Task 1, verified Albedo commits and gate reports. Produces a fresh review branch and exact commit/tree/diff links; no merge.

- [ ] **Step 1:** Re-read the target repository instructions, verify authenticated repository `testingtesttest123/successor` and its current base SHA, and choose an unused branch such as `experiment/albedo-personality-implementation`. Preserve the already published design branch. Never repoint Albedo upstream or push its source checkout.
- [ ] **Step 2:** Build an explicit tracked-file export into `albedo-personality/`, excluding nested `.git`, toolchains, `build`, homes, credentials, caches, databases/WALs, transcripts and non-fictional fixtures. Include manifests, source, tests, native/client assets required by tests, spec/plan, license and all vendored notices. Add only the top-level README distinction and pinned upstream attribution.
- [ ] **Step 3:** Compare every pre-existing Successor path to base; assert unchanged hashes except the reviewed additive README and specifically authorized design/plan path updates. Scan exported files for secrets/private data; compare subtree notices and tracked inventory to verified Albedo. Run `./test.sh` from the copied subtree to prove relative paths work; run the existing Successor documented gate unchanged. Expected: both implementations remain usable independently.
- [ ] **Step 4:** Use `superpowers:requesting-code-review` for whole-branch review, and `superpowers:verification-before-completion` before any complete/passing claim. Resolve review findings under the selected execution method and rerun affected/full gates. Use `superpowers:finishing-a-development-branch` without choosing merge or main push.
- [ ] **Step 5:** Stage only the subtree and agreed documentation. Commit `feat: add isolated Albedo personality implementation`; push only the fresh Successor branch, return verified branch/commit/diff links and real gate outcomes. No automatic PR, merge, live-provider evaluation or credentials request unless separately requested.

## Self-review record and execution gate

Self-review performed against all 14 spec acceptance scenarios: identity/live refresh (2–4), compaction/strategies (4, 7), durable memory/correction (5–6), provenance/import/report (5, 9–10), relationships/commitments (8), concurrency/receipts (3, 11), forks/single identity (9), input/storage budgets (3, 6, 10–11), fail-closed admission (2, 4, 11), deletion (5, 11), public docs/actual request inspection (3–4, 10–11), packaging/licenses (12). The five Review Focus cases have explicit owning tests above.

Additional decisions made in this plan are implementation bounds rather than new product scope: recent query excerpt 4 KiB, trusted summary envelope 4 KiB/32 intervals with honest unknown attribution fallback, and version-1 import contract. Self-review corrected a potential request-context/compaction import cycle, made capture query-scoped, and added explicit authorized episodic paging alongside curated recall. Domain types have one owner; request-context types stay generic; tool writes and user edits share the same domain. No additional enduring identity, automatic report merge, source-row correspondence table, second harness, or hidden background extractor is introduced.

No product implementation, installation, dependency fetch, build, test pass, or publication is claimed by this document. Toolchain discovery/baseline verification is the first execution task. The parent should publish/link this plan for review, preserve the chosen environment (the assistant's container), and ask the user to choose an execution method before proceeding.

Recommended method: **Subagent-driven**, because admission, provenance, and transaction boundaries have meaningful independent review gates, and a missed isolation or recovery bug could silently corrupt durable identity. **Native** execution is also supported by the ordered interfaces, with one fresh whole-branch reviewer at the end.
