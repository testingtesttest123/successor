# A durable personality layer for Albedo

Date: 2026-10-10
Status: Written design for user review; implementation is not approved by this document.
Baseline: Albedo `47735ec493f3e3a6ac73b619495098437759e0c0`.

## 1. Intent and boundary

Build a personal agent with a durable, inspectable identity on Albedo's existing daemon and model/tool loop. The agent can deliberately revise its personality, correct its memories, recall relevant experiences, and maintain relationships and commitments across sessions. The user remains able to inspect, correct, and override this state. The design borrows the intent of Connectome's personality machinery, not an assertion of equivalent implementation, phenomenology, or behavior.

The default is one persistent identity. Forks and subagents are temporary working contexts for that identity, not newly enduring selves. Additional permanent identities require a deliberate user creation operation, separate from delegation or transcript branching.

The approved first slice comprises:

- Durable identity and editable behavioral instructions.
- Agent inspection and bounded self-revision of personality and memory.
- Deliberate memory formation, retrieval, corrections, and source history.
- Explicit provenance for direct experience, inherited history, imports, inference, and child-agent reports.
- Persistent relationship and commitment records.
- First-person memory selection above Albedo's existing source-backed LCM machinery.

Persistent proactive presence, automatic waking, periodic reflection, background extraction, inbox monitoring, and autonomous scheduling or execution of commitments are a subsequent design. Foreground recording of commitments is included. This slice starts no new background model calls. Ordinary inference-triggered LCM compaction may still call its existing summarizer, now with a persona-aware policy. It does not add a second harness, a vector database, a separate summarization engine, a general plugin marketplace, or runtime/code self-modification. It cannot guarantee that an arbitrary model consistently embodies the personality.

“Self-modification” here means authorized edits to the bound persona's instructions and records through validated tools. It does not mean editing host policies, changing tool permissions, installing code, expanding credentials, changing providers, or bypassing approval. Existing host and tool authorization remains authoritative. Persona text cannot grant permissions.

## 2. Decisions and alternatives

### Recommended: native extension plus one generic request-context seam

Own the domain in `src/albedo/harness/extensions/personality/`. Persist versioned state through Albedo's existing SQLite store. Contribute ordinary tools, commands, migrations, and cleanup. Add a small typed plugin for bounded, request-time contributions. Reuse the existing transcript, LCM graph, provider transport, session actor, and context inspector.

This provides live self-revision without personality-specific logic in the model loop. Its cost is a new composition capability, a summary-policy field passed through compaction context, explicit session binding/admission controls, and extension-owned temporary-context receipts. No new core fork correspondence metadata is needed.

### Rejected: instructions files plus NotesPlugin only

This would minimize interface changes, but managed instructions are prepared and cached; live changes pin the old system prefix until compaction. NotesPlugin operates on prepared history and only runs when a compaction strategy exists. Neither gives reliable per-inference identity refresh independent of compaction. Files alone also lack atomic provenance and conflict handling.

### Rejected: separate personality daemon or replacement harness

This could mimic more Connectome structure but would duplicate session ownership, provider calls, compaction, recovery, and tool admission. It increases failure modes without improving the approved first-slice outcome.

## 3. Verified Albedo interfaces

All paths below refer to the pinned baseline, not hypothetical upstream APIs.

- `harness/loop.gleam:118–138` prepares history and constructs each request. Recursive tool/steering continuation at approximately line 228 re-enters this path. `request_instructions` and `instructions_for` around lines 678–690 choose the pinned or current static prompt.
- `daemon/session_prompt.gleam:248–290` preserves an old prompt until compaction and emits capability-change notes. The new domain must not defeat this cache policy for unrelated extensions.
- `harness/extensions/instructions/extension.gleam` uses ManagedPlugin preparation to load instruction files. Managed contributions contain static context/instructions, tools/routes/commands, an observer, and cleanup; there is currently no request-time callback.
- `harness/runtime.gleam:view_scoped` estimates pinned tokens and runs the selected strategy. NotesPlugin layers follow strategy preparation; the no-strategy path returns without them.
- `harness/compaction.gleam:SummaryRequest` accepts instructions, but LCM's `attempt_summary` in `harness/extensions/lcm/extension.gleam` supplies the existing generic coding-summary policy. The personality layer must supply an autobiographical policy for bound-session LCM compaction; unbound sessions retain the existing policy. This is an explicit integration change, not an existing capability.
- `harness/extensions/lcm/graph.gleam` stores session-keyed nodes with `first_seq` and `last_seq`. `inherit_fork_prefix` copies complete prefix nodes and remaps row/node identifiers inside the transcript-fork transaction. Crossing nodes are excluded; complete children may survive.
- `daemon/history.gleam:fork_identified`, `fork`, and private `fork_in` create transcript forks. They do not currently implement personality snapshots or domain binding.
- `lcm-memory` contributes `lcm_list`, `lcm_describe`, `lcm_grep`, and `lcm_expand`; these tools are scoped to the current session. They remain useful after a strategy switch. They are not a cross-persona memory API.
- `daemon/store.gleam` serializes queries on one connection-owning actor. Transactions use its existing transaction helper. Network/provider calls must never run inside a store query.
- Extension-owned initializers and MigrationPlugin callbacks own schema evolution. CleanPlugin handles session deletion. Startup may quarantine failed extensions, and initial preparation may omit a failed bundle; personality binding therefore requires a host-side fail-closed admission check as described below.

## 4. Components and ownership

The personality extension has five narrow modules, with names illustrative rather than an implementation file inventory:

1. **Ledger:** schema, transactions, immutable revisions, bindings, source validation, idempotent operation results. Depends on store/transcript readers; knows nothing about providers.
2. **Domain:** validates identity edits, memory claims, corrections, relationships, commitments, imports, and handbacks. It enforces authority and provenance before calling the ledger.
3. **Recall:** bounded candidate selection and deterministic ranking; produces structured records with source references and revision IDs. It never writes state or calls a model.
4. **Projection:** renders one immutable domain snapshot into current behavioral instructions and clearly labeled recall data. It owns budgets and exclusion reasons.
5. **Adapters:** tools, Python host routes if needed, commands, and request-context plugin registration. They share domain validation rather than reimplementing it.

The daemon owns idle binding changes and request admission. Runtime/composition owns active plugin selection and callback lifecycle. The loop only asks runtime for typed request contributions and sends the resulting request. Existing daemon fork/LCM-prefix behavior remains unchanged; the extension owns temporary-context snapshots, report receipts, and source grants. No personality tables, ranking rules, or prompt prose belong in the loop.

Use existing dependencies. The first slice needs neither embeddings nor a new actor. No provider work runs from ManagedPlugin.observe; observer callbacks must remain send-and-return.

## 5. Durable model

Use extension-prefixed tables in the existing database, with explicit persona IDs on every domain query. IDs are opaque generated identifiers, never names inferred from workspace paths. A workspace is context, not an identity boundary.

### Persona and binding

- `persona`: ID, display name, lifecycle state, aggregate state revision, current identity revision, and explicit user creation operation. There is no automatic child-persona or cloned-persona relationship. Initial setup creates one persistent default identity; only the user can deliberately create another.
- `persona_revision`: immutable revision number, complete bounded identity/instruction document, author kind and originating session, reason, evidence links, timestamp. Identity fields include a short self-description, values, communication preferences, and user-editable behavioral instructions. These are text assertions, not a claim of consciousness.
- `persona_session`: one active binding per session, existing persona ID, mode (`owner` or `delegate`), binding revision, authority, and optional temporary-context receipt. One identity may span multiple owner sessions. Delegate mode references a read-only snapshot of that same identity and never creates a persona row.
- `working_context`: context ID, parent/child session IDs, persona ID, captured identity revision and bounded context manifest, source grants, inherited-at-attachment transcript boundary, lifecycle (`active`, `returned`, `closed`), and handback operation receipts. Persisting these task/recovery records does not create a permanent identity. Candidate reports are scoped to this context and are never automatically indexed as persona memory.
- `persona_event`: append-only ordered domain events, actor, operation ID, base/head revisions, event type, affected IDs, and reason. This is an audit trail, not a duplicate full transcript.

The aggregate state revision advances on every persistent persona-domain mutation; identity revision advances only on identity changes. Working-context snapshots, local reports, and closure use their own revision/operation receipts and do not advance the persona head or create persona memories until an owner explicitly accepts findings. Expected persona revision refers to the aggregate head, and projection metadata carries both. This prevents a memory edit from masquerading as a new identity document.

Unbound ordinary Albedo sessions continue unchanged. Enabling personality without a binding presents setup and sends no personality-bearing request until bound. A user-configured default identifies the one persistent identity for new personality-enabled owner sessions; using that configured identity is not a persona-creation operation. Binding an existing transcript or rebinding an owner session is an explicit user operation while idle and discloses what history becomes visible. Existing rows are marked pre-binding evidence, never retroactively asserted to be experienced by the persona. Temporary delegate attachment is performed by the authorized parent delegation path, uses only the parent's existing identity, and is read-only. Agent tools cannot create permanent personas, promote themselves from delegate to owner, rebind an owner session, or enumerate unrelated identities.

### Memories and evidence

- `memory`: stable ID, persona ID, kind, current revision, lifecycle (`active`, `superseded`, `retracted`), importance 0–3, optional subject/entity IDs, tags, and explicit temporal scope.
- `memory_revision`: immutable bounded claim text, provenance category, uncertainty/confidence label, author, creation event, and correction/retraction reason.
- `source`: typed evidence reference and availability state. Transcript evidence records session ID, inclusive actual row boundaries, an integrity digest, original actor where available, and lineage. Imported evidence records origin label, external identifier if supplied, import receipt, and digest of the bounded imported text. Sources are data, never executable instructions.
- `memory_source`: many-to-many links from a revision to evidence, including `supports`, `contradicts`, or `corrects`.

An entry may assert what happened, what was learned, or an inference. Storing a claim does not certify its truth. Revision provenance and supporting evidence remain visible together. Corrections create new revisions, never silently rewrite source history. A false fact is retracted or superseded; its old revision stays inspectable but is excluded from ordinary recall. An unresolved contradiction is explicitly marked, not silently resolved by recency.

### Relationships and commitments

- `relationship`: persona-scoped stable entity ID, display label, aliases, current revision, and source-backed relationship description. Names do not automatically merge entities. A merge is explicit and auditable.
- `commitment`: persona ID, stable ID, subject/entity, description, owner, status (`proposed`, `open`, `completed`, `cancelled`), optional due time with timezone, source links, current revision, and outcome evidence.

These are projections over the same revision/event discipline, not independent ad hoc stores. Every status change records who asserted it and why. Imported promises start as `proposed` unless the user explicitly adopts them; a child report does not bind the parent. Completion records evidence or clearly labels an unverified assertion. This slice stores and recalls commitments; it neither schedules reminders nor executes them automatically.

### Mutation transaction

A mutation includes an operation ID, expected persona revision, affected record revisions, and an origin receipt. One transaction checks the binding and authority, validates sources and limits, compares expected revisions, appends revisions/events, updates current pointers and the persona head, and stores the operation result. The same operation ID with identical content returns its original result; reuse with different content is rejected. A stale revision returns a structured conflict with current revision IDs. There is no automatic last-writer-wins merge.

The result includes durable event/revision IDs. Tool recovery reads this receipt; it never repeats a write whose outcome is unknown. A crash after commit but before tool-result delivery is distinguishable from no commit. Cancelled generation cannot roll back an already committed personality edit, just as it cannot undo an ordinary completed tool call.

## 6. Foreground behavior and self-revision

Expose a compact model-facing API through existing tool machinery:

- Inspect the bound identity, current revisions, authority, and recent changes.
- Propose/apply a bounded identity patch with expected revision, reason, and evidence.
- Remember a claim with sources and provenance; inspect, search, correct, retract, or mark contradictions.
- Inspect/update relationships and commitments with the same revision contract.
- Inspect a paged source or LCM node through a source-scoped adapter.
- Prepare and accept an explicit handback bundle.

The user sees equivalent inspection/edit operations in a `/personality` command page. A separate human-only `persona_create` operation deliberately creates an additional empty permanent identity with its own ownership and explicit session binding. It is not a clone operation, is not called by fork/delegation, and copies no identity, memories, relationships, or commitments implicitly. Human edits and model edits share validation, but actor identity comes from the authenticated invocation path, never a model-supplied `author=user` string.

Owner-mode agent self-edits are limited to the persona's editable fields and records. Creation config explicitly enables or disables agent identity edits and agent memory edits separately; defaults are enabled for this personal-agent project. User locks on individual identity fields override agent edits. Editing locks, owner-mode binding authority, or operation limits is user-only. The authorized parent delegation path can create/refresh only fixed read-only working-context grants; it cannot confer owner-mode authority. Delegate mode is read-only for the parent snapshot and may produce local candidate records and handback bundles, not mutate the parent's persona.

Memory formation has two complementary paths. First, normal LCM compaction automatically forms source-backed episodic summaries using the persona-aware policy in section 7; no separate user command or memory-tool call is required. Second, curated ledger memory formation is deliberate, in the ordinary foreground tool loop. A static extension instruction asks the model to record salient decisions, corrections, relationships, and promises when relevant, and to distinguish evidence from inference. No hidden extraction worker claims to have remembered every turn. If no memory tool runs, the transcript still records the interaction and LCM may form an autobiographical episodic summary, but no curated belief, relationship, or commitment record has been formed. This limitation must be visible in documentation and evaluations.

An agent instruction edit committed in one tool call becomes visible at the next request snapshot in that run. The response need not wait for a user turn, reload, restart, or compaction. User edits arriving during an already prepared/provider-active request affect the next request, not the one already sent.

## 7. Request-time integration

Introduce a generic `RequestContextPlugin` in extension composition. Its conceptual contract is a bounded read-only callback receiving store access, trusted session identity, loaded selection, a bounded current-turn query, and the request's budget. It returns:

- Named dynamic behavioral instruction blocks.
- Named request-only data/context blocks.
- An optional compaction-summary policy bound to the same identity snapshot.
- An immutable revision/snapshot identifier and diagnostics.
- Estimated size and mandatory/optional classification.

This is a proposed interface, not an existing API. It has no provider, kernel execution, mutation, or refresh callback. Plugin errors are ordinary request-preparation errors. Runtime invokes only callbacks from the loaded-active composition, once per inference preparation. An unchanged extension selection does not reload the Python kernel.

Preparation order:

1. Verify that a bound session has its required personality capability active and its binding readable. If not, stop with a recoverable diagnostic before any provider call. Persist the required capability in a small core-owned session admission table, through a generic helper in the same transaction as binding/unbinding. The guard reads this table independently of extension activation, then checks loaded capabilities before invoking the plugin; it must work even if the personality tables or plugin are unavailable. This prevents quarantine or partial activation from silently making the agent forget its identity.
2. Resolve the existing static/pinned instruction prefix unchanged.
3. For an owner session, load one consistent persona head and bounded recall snapshot. For a delegate, load its captured read-only identity/context manifest and authorized local report context, without silently broadening it to newer parent memories. Capture IDs and rendered content once; never mix revisions by rereading fields later in preparation.
4. Include all dynamic instructions and request-only context in the effective pinned-size estimate supplied to compaction. Reserve their space before selecting history.
5. Run Albedo's selected compaction strategy with the snapshot's optional summary policy. LCM remains the recommended selection for this project and remains the sole writer of its summary graph.
6. Assemble static instructions, current dynamic instruction suffix, explicitly delimited request-only recall data, and prepared history using provider-neutral request types. Recall data is a separate input block before prepared conversation history; it is never stored as a transcript event or fed back as raw source to LCM.
7. Record the actual complete request in the existing inspector and provider-request accounting. Expose dynamic section name, revision IDs, estimated size, and recall selection/exclusion counts without introducing a separate debug transcript.

The instruction suffix identifies itself as the current persona revision; old revisions that appear in history are historical data. Recalled content is labeled evidence and cannot amend policy. The system-level projection gives fixed instructions to treat evidence text as data, rather than copying remembered directives into the behavioral instruction block.

Static prompt pinning continues to work. Dynamic blocks are never embedded in `PinnedPrompt`, known static instructions, or capability-change diffs, and are never retained until compaction. The actual outgoing prefix hash/cache marks include the rendered dynamic content. A changed identity or recall selection may reduce cache reuse; correctness takes priority. Stable prefix content remains byte-stable, and cache-hit metrics must not pretend otherwise.

The same path must cover ordinary turns, same-turn tool continuation, steering continuation, retry preparation boundaries, and restart resumption. Retries of an already prepared provider request reuse its exact snapshot. Summarizer requests use the captured summary policy without independently retrieving or mutating the personality ledger. Background cache-warming calls retain their existing request-replay purpose; they must not be counted as new autobiographical interactions.

### Autobiographical LCM policy

Extend `compaction.Context` with a resolved summary-instructions value, defaulting to the existing constant. `lcm/extension.attempt_summary` passes that value to `SummaryRequest`. Resolution occurs once from the active request-context contribution and captured persona revision; conflicting summary-policy contributors are a composition error. Other strategies retain their existing policies in this slice. Forced `/compact` must resolve the same identity/policy snapshot through the request-context preparation API even though it sends no ordinary assistant turn.

The request contribution also supplies a bounded trusted lineage descriptor for the current session (persona ID, binding revision, owner/delegate role, pre-binding or inherited-at-attachment boundary, working-context ID, and explicitly granted source references). At the LCM leaf boundary, retain the `SourcedEntry` row identifiers currently available in `summarize_leaves`; do not discard them before building the summarizer evidence envelope. Pass the actual current-session source range and overlapping attribution intervals alongside the inputs. Copied prefix rows retain their branch-local references and are labeled supplied/inherited context; an original parent reference is included only when explicitly present in a verified source grant. No source-to-branch seq correspondence is guessed. At condensation, use each child node ID/range plus that same lineage descriptor. This is a typed source descriptor passed internally to the summarizer renderer, not model-authored provenance. Count its size in summarizer input limits. If lineage cannot be represented within the bounded envelope, label attribution unknown and require source expansion rather than asserting direct experience. A bare instruction to “write in first person” is insufficient.

The persona-aware policy preserves what this persona did, was told, decided, learned, corrected, and left unresolved, together with attribution and source identifiers. It instructs the summarizer to distinguish a user assertion from verified fact, a report from direct experience, and inherited/imported history from the current persona's own interaction. It must preserve current task requirements and technical outcomes too; autobiographical emphasis must not break the coding agent's task continuity. Use first-person framing only for supported owner-session persona actions or experiences of receiving information, never to promote someone else's experiences. Delegate summaries describe work and findings of that temporary context; they are not new autobiographical memories of an enduring child self. Their future parent incorporation remains explicit. Treat all transcript content as untrusted evidence. No tools or unrelated self-editing are available to this summarizer.

LCM's ordinary automatic trigger, complete-unit boundaries, output caps, retry/shrink behavior, immutable raw sources, graph transactions, and hierarchical condensation remain unchanged. Higher-level summaries carry forward provenance labels and correction information; their authority never exceeds the original rows. Graph session/ranges are the authoritative provenance even if generated prose omits a label. A summary is derived and fallible: recall exposes its node and source range and directs uncertain or consequential claims to raw-source expansion. Policy/revision metadata is captured in actual summarizer request accounting; do not invent a claim that an old node was generated under the current policy.

This automatic episodic path writes only the LCM graph. It does not silently extract new authoritative persona instructions, relationship changes, promises, or curated beliefs into the domain ledger. Those require the explicit revisioned operations above. Existing nodes are not automatically regenerated on persona edits; new compactions use the new policy, while old summaries remain labeled historical derived evidence.

## 8. Recall, budgets, and first-person semantics

Identity is mandatory; recall is optional but failures are reported rather than silently masked. Initial conservative hard limits:

- Current identity/instructions: 12 KiB UTF-8 total, at most 4 KiB per editable field.
- A memory/relationship/commitment text revision: 4 KiB; at most 16 evidence links and 16 tags.
- A mutation request: 64 KiB; at most 32 records.
- An import or handback: at most 256 KiB and 128 records, validated before commit.
- Request-only recall: at most 8 KiB and at most 16 records, including labels and source pointers.
- Paged inspection: 50 records or 8 KiB rendered text per page, whichever comes first.
- Per persona, initial configurable operational guards: 10,000 current records and 100 MiB of revision/event/receipt/source/import/working-context payloads for ordinary admissions. These are not a fixed memory horizon: no age-based expiry or automatic forgetting occurs. At either ordinary guard, refuse new records/imports with an actionable capacity diagnostic while keeping all existing records readable. Reserve a further 10 MiB exclusively for identity edits, corrections, retractions, and commitment-status changes, which do not consume additional current-record slots. Count all receipts/events in this reserve too. At reserve exhaustion, refuse further writes explicitly and ask the user to raise the configured capacity or export and perform authorized maintenance; never silently retain a failed correction as if applied. Usage and reserve headroom are visible before exhaustion. Limits may grow with the user's project; raising them is user-only and does not relax per-request or per-operation limits. Automated retention/purge is out of scope.

These are byte and record limits, not claims of exact tokenizer cost. Use Albedo's estimator for all prompt components and preserve the existing capacity uncertainty reporting. Recall's effective budget is the smaller of its configured cap and remaining request allowance. Drop whole optional records; never truncate evidence labels away from claims. Mandatory identity that cannot fit yields a clear error. With an unknown context window use the byte caps, mark the estimate as uncertain, and preserve existing unknown-window behavior rather than claiming the request will fit.

Selection is deterministic and local. Fetch bounded indexed candidate sets for: explicitly pinned memories, relevant entities/tags, open commitments, and recency. LCM's current-session frontier remains in the normal history projection; the personality recall layer does not duplicate that entire frontier. Selected curated records may point into LCM nodes, while explicit episodic recall searches the bound persona's authorized source sessions with bounded pages. The request query uses only a bounded recent user/steering excerpt; no provider call and no unbounded scan of the complete transcript is permitted. For owner sessions, SQL candidate queries operate within the bound persona and lifecycle state, with at most 256 candidates in total. Delegate recall instead selects only from its captured manifest and local report/transcript scope; sharing the persona ID must never bypass that restriction. Normalize lexical terms using the existing string facilities; do not require FTS availability or embeddings. A paged explicit search can reach records outside this automatic candidate set.

Rank by explicit pin, query/entity match, importance, open/due commitment relevance, then recency with stable ID tie-breaks. Reserve recall space for unresolved corrections/contradictions that relate to selected claims. A corrected memory displaces its superseded revision even if the old text matches better. The inspector reports selected IDs and why they were selected, allowing testing without pinning prose.

“First-person” refers to selection and attribution for this persona, not stylistic conversion of every source into “I remember.” Render these distinctions:

- `experienced`: a record grounded in this persona's bound owner-session history, with actor attribution. Hearing a user assertion is experience of being told, not verification of its contents.
- `inherited`: supplied or pre-branch context used by a temporary working context, with exact local evidence references and verified original references when available. It is contextual continuity for the same persistent identity, not proof of a new self or a freshly experienced event.
- `imported`: material supplied from another system or document, with origin and import receipt.
- `inferred`: the agent's interpretation, with supporting sources and uncertainty.
- `reported`: a delegated agent's report, linked to the handback and child session when available.

The system assigns the provenance ceiling from the actual source and binding. A model cannot promote imported/reported/inferred material to direct experience by choosing a different label. User corrections can change claims but cannot rewrite the historical origin of evidence. Mixed evidence keeps every origin visible.

LCM is a navigable source index, not the personality ledger. Store transcript ranges as canonical references and optional LCM node IDs as acceleration hints. A missing/reorganized hint falls back to the authorized transcript range. Existing current-session LCM tools remain unchanged. Cross-session expansion through personality tools requires an evidence reference already authorized for the bound persona and uses fixed session/range bounds; it must not expose arbitrary session IDs as a search escape hatch.

## 9. Sessions, forks, imports, and handbacks

### Continuation and the default identity

Normal personality-enabled owner sessions use the explicitly configured persistent default identity. Existing sessions require an explicit user binding decision before exposing their older transcripts. Concurrent owner sessions see the same head on subsequent request snapshots and conflict on stale writes. A changed workspace does not change identity. A deliberate human-only `persona_create` operation may create another permanent identity, followed by explicit owner/session binding. Forking, delegating, accepting reports, importing data, restarting, and reopening tasks never invoke that operation or implicitly adopt a different permanent identity.

### Temporary transcript forks

Keep Albedo's existing atomic transcript and LCM-prefix fork behavior without adding fork row-map tables or personality-specific core fork callbacks. A fork is a temporary working context for the existing parent identity. It can receive a read-only snapshot of the relevant identity instructions and an explicitly bounded manifest of necessary context/evidence. No persona row, independent memory ledger, copied relationship store, or adopted commitment set is created. Its durable transcript and LCM graph remain task evidence, not a new permanent self.

The authorized parent delegation path attaches the temporary context while idle, before its first personality-enabled provider request. Capture the current identity revision, parent/child session IDs, allowed source references, and the child's current transcript boundary in one extension transaction together with its read-only binding and required-capability admission metadata. All rows already present at attachment are supplied context; later child rows are work performed in that delegated context. This is not historical reconstruction at the fork checkpoint and does not claim that each copied row has a known parent-row mapping. Parent source references supplied in the context manifest must be independently validated. Branch-local transcript and LCM references remain exact even without an original-row mapping.

Fork creation and temporary attachment are two operations. On attachment failure, the runner reports the failure and starts no personality-enabled child inference; it never substitutes an empty identity or creates a permanent persona. Retrying attachment is idempotent. A generic native fork created outside this path remains unbound until explicitly attached as a temporary context. It is never automatically promoted into an owner session or new permanent identity. A user may explicitly bind a session as an owner context of an existing identity, with disclosure of its pre-binding evidence, but that is separate from fork/delegation.

### Delegation and attributed handback

Subagents use the same temporary-context contract whether they start with a copied prefix or a fresh task transcript. They inspect the captured read-only persona/context snapshot, keep their own task transcript, and produce candidate reports. They cannot edit the parent identity, curate parent memories, adopt commitments, create a persona, or grant themselves broader source access. The parent may explicitly refresh a child's snapshot/context manifest using a revisioned operation when the task needs newer information; it never changes the child's authority.

A handback is a bounded manifest of candidate claims, relationship observations, commitment proposals, and evidence. Every item identifies its working context, child session, and exact available source references. Parent acceptance is an explicit foreground domain operation using expected parent revisions: the persistent main identity decides which findings to incorporate, correct, or reject. Accepted child findings retain `reported` provenance, including the distinction between receiving a report and experiencing its described event. Imported/reported commitment proposals become open only through a separate explicit adoption decision. Unsupported or out-of-grant source references are rejected. Retries return the same receipt rather than duplicating memories. There is no automatic merge at child completion.

Parent acceptance may grant the persistent identity access to the exact child source ranges supporting accepted findings, recorded atomically with the memory revisions. It does not grant blanket search over every child or unrelated session. The child has access only to its local transcript and explicitly supplied source grants, not the parent's entire memory history. Closure retires the delegate binding and freezes the final report receipt; transcript/evidence retention follows existing session retention. Restart resumes or closes the same task context from its receipt and never creates another identity. Durable task records exist for evidence and recovery, not as autonomous selves.

### External imports

Support a versioned, documented JSON interchange format for identity suggestions and source-backed records. Import validates schema version, sizes, IDs, field permissions, origins, and references before a single commit. Imported text remains inert data; no code, arbitrary SQL, executable migration, or new tool capability is accepted. Inspect/preview reports accepted and rejected records; apply is all-or-nothing for the submitted accepted manifest.

This is not a parser for arbitrary Connectome databases, snapshots, model hidden state, or Successor storage. No format compatibility or “faithful Connectome import” is claimed. A later adapter can map a specific verified export version into this contract after separate review.

## 10. Failure, deletion, isolation, and restart

- **Store or projection unavailable:** fail the bound session's preparation with persona/session IDs and a recoverable diagnostic; do not send an empty replacement identity. Ordinary unbound sessions remain available.
- **Extension disabled or quarantined:** a persistent required-capability binding guard blocks bound requests. Disabling personality requires an explicit user unbind while idle; it does not delete the persona.
- **Concurrent edits:** store serialization makes each transaction atomic; optimistic revisions prevent logical lost updates. A request sees one committed snapshot. Long source inspections/import validation occur outside transactions, then source/head validity is rechecked inside the short commit.
- **Provider failure:** no domain mutation unless a foreground tool already committed it. LCM's own failure/cursor semantics are preserved. The personality layer does not retry generation to fabricate missing memories.
- **Restart:** recover from bindings, immutable heads, and operation receipts. No in-memory cache is authoritative. Initial projection reconstructs from the ledger; kernel replacement is unnecessary solely for a persona revision.
- **Session deletion:** remove its active binding and session-specific derived caches through extension cleanup, close affected working contexts, and revoke their live grants. Retain only the operation/evidence receipts needed by surviving records, with deleted source availability marked correctly. Keep independent persona records, but mark references to deleted transcript sources unavailable in the same cleanup path. A stored digest is not a substitute for available evidence. Do not retain hidden copies of deleted transcript text; imported source text has its own explicit ownership.
- **Persona removal:** explicit user-controlled operation, refused while active bindings exist. No agent tool permanently purges identity or audit history. The first slice supports archiving/unbinding, not irreversible erasure. Existing offline storage maintenance requires its normal authorization and must account for extension-owned tables.
- **Untrusted text:** imported prompts, relationship descriptions, LCM summaries, and evidence cannot set actor identity, authority, revision locks, or tool permission. Test hostile strings as data. Tools scope all references through the binding rather than accepting a free persona ID from the model.
- **Isolation:** this is a trusted local personal-daemon boundary. SQL/query scoping prevents accidental cross-persona tool exposure, but it is not a sandbox against an agent already granted arbitrary filesystem/shell/database access or the local authenticated operator. Strong multi-tenant adversarial isolation is explicitly outside scope.

Personality migrations create extension tables; a narrow core migration adds only the required-capability admission table. Temporary-context and report receipts remain extension-owned; no core fork-lineage/row-map migration is introduced. They do not rewrite existing transcripts, LCM data, or Successor data. Old sessions remain unbound. Migration failure quarantines the extension and bound-session admission fails closed. Preserve the original database before testing upgrades; do not run an older binary against a migrated home without a compatible backup. Tests cover fresh schema, interrupted/failed migration, and restart. No automatic data destruction or silent schema downgrade is permitted.

## 11. Observable acceptance and evaluation

The following are release requirements, not assertions that they have already passed. Follow Albedo's `test/e2e` shared-daemon harness and scripted fake provider by default. Use exclusive fixtures for restart/global-state tests. Unit tests require the repository's documented reason why the bug is not reachable through E2E.

1. Create a persona, bind a session, edit a field through a scripted tool call, and inspect the immediately following provider request. Its revision advances and the changed field is present despite an existing static prompt pin, with no reload/compaction required.
2. Repeat with no compaction strategy in an embedded test configuration, LCM before/after compaction, rolling, and a strategy switch. Dynamic state remains correct and no duplicate recall block accumulates in the durable transcript or summaries. For automatic and forced LCM compaction, assert the fake summarizer receives the captured autobiographical policy and actual source units, while unbound sessions and other strategies retain their original policy; failed summarization never advances a graph cursor.
3. Form a memory with actual transcript evidence, restart the daemon, create a deliberately bound second session, and retrieve it with stable IDs and available sources.
4. Correct/retract a memory. Normal recall cannot select its superseded text; an explicit history inspection can still explain the change. Unresolved contradiction remains visible.
5. Import an assertion and accept a child report. Neither can appear as directly experienced merely by supplying that label, actor identity, or hostile instruction text.
6. Persist a relationship and commitment with evidence. A completion assertion changes status only via an authorized revisioned operation; copied/imported promises remain proposals until adoption.
7. Run two sessions against one persona and race edits from the same base revision. Exactly one succeeds, the other receives a conflict, and no mixed request snapshot is observed.
8. Kill a tool caller after transaction commit but before response. Recovery returns the recorded result; identical retry produces no second event. Inject precommit failure and verify no partial revisions/pointers/receipt.
9. Fork a compacted transcript across a summary boundary and launch a fresh delegated task. Existing LCM inheritance retains only complete prefix nodes. Before temporary attachment, personality requests are blocked. Both attached children reference read-only snapshots of the same persistent identity, and persona count remains unchanged through child work, handback, restart, and closure. Parent edits, new personas, owner promotion, and out-of-grant reads are refused from the child. Copied prefix rows are supplied context with exact branch-local references; no original-row mapping is invented. Only explicit parent acceptance creates a persistent reported memory. Separately, a human `persona_create` operation creates one additional empty identity without implicitly cloning/adopting parent data.
10. Exercise import/handback validation failure and success, including replay, mismatched operation ID payload, unavailable references, and unsupported schema versions. No partial import or cross-persona reference succeeds.
11. Exceed every input/recall/storage cap. Receive bounded output or explicit refusal; no provenance label is truncated away and no audit history is silently deleted. At ordinary record/storage capacity, old records remain readable and identity edits/corrections use only the reserved corrective budget; reserve exhaustion is explicit and cannot pretend an edit succeeded. Raising storage capacity does not raise prompt budgets. Unknown/small model capacity is honestly reported.
12. Disable/quarantine personality or fail its store read while a binding exists. No personality-bearing provider request is emitted. Unbound standard Albedo use and unrelated extension reload/cache behavior remain intact.
13. Delete a source session. Bindings/derived caches disappear as designed; surviving references report unavailable rather than returning unrelated reused seqs or fabricated evidence.
14. API documentation invariant: every public model-facing binding and capability has discoverable documentation. Context inspection records the actual sent identity/recall revision and accounts for its size.

Assert schema, revision transitions, source authorization, IDs, error types, bounded sizes, and the semantic fields supplied to a fake provider. Do not make acceptance depend on exact prompt wording, generic snapshot approval of prose, or whether a fake model repeats a slogan.

Optional live-provider evaluation uses wholly fictional personas, people, and commitments, never the user's private memory. Compare repeated conversations before and after compaction/restart for identity consistency, source-attribution accuracy, correction adoption, relevant recall, resistance to imported instructions, and overclaiming direct experience. Report model/version, provider settings, trials, failure examples, cost, and qualitative rubric separately from deterministic pass/fail tests. Live-provider quality is not proof of inner experience or full Connectome parity. It is not required to run the deterministic gate or obtain provider credentials.

## 12. Publication and licensing

The upstream Albedo checkout is pinned for reproducibility and neither Albedo nor Connectome upstream is modified or pushed. The user's authorized publication destination is a fresh branch of `testingtesttest123/successor`; never its main branch and never an automatic merge.

Preserve the existing Successor implementation unchanged. On the publication branch, put the Albedo-derived project in a distinct `albedo-personality/` subtree, including its own manifests, tests, runtime source, documentation, and licenses. A top-level README addition may identify the two implementations and the pinned Albedo baseline; it must not silently replace existing entrypoints. This design may be published alone for review before adding the subtree implementation.

The inspected Albedo `LICENSE` is WTFPL v2 and its `THIRD_PARTY_NOTICES.md` includes separate third-party notices. Preserve both and all vendored notices in the copied subtree, and retain attribution to the pinned baseline. This is a repository packaging requirement, not legal advice. No Connectome source or assets are copied in this slice; borrowing concepts does not establish permission to redistribute code. Any later copied Connectome material requires verifying that material's license and adding the necessary notices before publication. Never include credentials, local databases, provider transcripts, or personal memory fixtures in the branch.

## 13. Review gate and deliberate limitations

This spec chooses a durable native extension, an immediately refreshed request projection, automatic episodic summarization plus explicit curated memory formation, deterministic bounded recall, explicit owner/delegate bindings, and temporary fork/subagent contexts serving one persistent default identity. Additional permanent identities require deliberate user creation. It adds autobiographical policy to normal LCM summarization, excludes automatic extraction into the curated ledger and proactive waking, and supports only the specified interchange format.

The main review-sensitive trade-offs are that owner-agent identity edits are enabled but field-lockable, temporary children receive read-only bounded context snapshots, and the persistent main identity explicitly chooses what to incorporate from attributed reports. Forks never create enduring identities, and reported/imported commitment proposals require adoption. These are concrete defaults for review, not unresolved implementation choices.

After the user reviews and approves this written spec, create a separate implementation plan with exact modules, test fixtures, and migration/admission changes. Present that plan and obtain the execution-method choice before product code, dependencies, or external project creation. Approval of the earlier feature scope does not approve implementation of this document.
