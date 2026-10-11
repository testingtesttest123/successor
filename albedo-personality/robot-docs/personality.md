# personality

`personality` is an opt-in native LCM bundle. Ordinary Albedo keeps rolling.
Selecting personality requires `lcm-memory` and displaces another compaction
strategy through native selection. Switching explicitly to another strategy
suspends the bundle without changing its identity binding or retained history.
`personality-lessons` is separately installed and disabled by default.

## Living document

An identity has one free-form UTF-8 document, a stable ID, name, document
revision and writable setting. There are no mandatory fields, lifetime quotas,
claim taxonomy, source registry, signed pages, field locks or adoption workflow.

Each provider preparation captures the live document exactly once. Retries and
inspection retain that immutable value; the next preparation sees edits. It is
a request-only behavioral overlay and never a copied transcript row. Historical
revisions remain historical data. Identity and recalled text cannot grant tool
or external-action authority.

Albedo adapter defaults are 1 MiB stored UTF-8 per document and 32,768 bytes
projected per request. These are per-operation settings, not claims of upstream
storage parity. Projection cuts only at whole UTF-8 codepoints and visibly
reports omitted bytes and the pinned revision/offset needed to read the rest.
The common request budget still includes metadata and rendered wrappers. A
known window too small for the mandatory identity fails before dispatch.

Model tools:

- `persona_read(revision?, offset=0, limit=32768)` returns `revision`, `text` and
  `next_offset`. Offsets are UTF-8 bytes; follow the pinned revision. Old revisions
  remain readable after edits. A limit too small for the next codepoint refuses.
- `persona_write(content, expected_revision?)` intentionally replaces the whole
  document. The optional revision is the document revision alone.
- `persona_edit(old_string, new_string, replace_all=false)` requires a nonempty
  uniquely matched old string unless replacement of all matches is requested.
  Missing or ambiguous text refuses atomically.
  Result UTF-8 size is checked from non-overlapping matches before allocating
  replacement text, so individually bounded inputs cannot amplify into an
  oversized document inside the shared store.

These document tools advertise `strict=false`, following the existing native
optional-argument convention. Omitted revision, paging and `replace_all` values
keep their decoder behavior. Both provider wire protocols carry valid non-strict
schemas rather than marking optional properties as strict-but-not-required.
Native document/binding authority and write receipts are unchanged.

Native authenticated context supplies actor, session and call ID. Model inputs
cannot supply these, permanent identity IDs, creation, rebinding, operation IDs,
aggregate heads or reasons. A committed `(session, call_id)` receipt, document
revision, actor and timestamp are atomic. Duplicate calls return their exact
receipt; changed call reuse is refused. Recovery reads committed receipts only
and never replays an unknown write. Binding and lesson activity do not conflict
with a document edit. Read-only documents refuse model writes; human editing
remains available.

## Human setup and page

The daemon-token service is mounted at `/extensions/personality`. It rejects
unknown fields and supplies human authority. Its bounded JSON envelope allows
worst-case escaping of document/edit text; the domain independently enforces
the stored 1-MiB limit. This convenience API is not a sandbox against separately
granted arbitrary Python, filesystem or daemon-token access.

- `POST /sessions/{id}/setup`: `name`, `content`, optional `writable=true` and
  transport `retry_key`. The idle owner-session bridge creates the first default
  and binds a fresh session atomically. It requires no existing default, binding
  or transcript. The page chooses retry keys internally.
- `POST /personas`: deliberate additional creation with `name`, `content`, optional
  `writable` and `retry_key`. It copies no prior identity or memories.
- `POST /default`: `persona_id` selects an existing default. It affects future
  fresh sessions, not existing bindings.
- `GET /sessions/{id}`: concise metadata, current binding, exact pre-binding
  history boundary, default, bounded owner-session pointers and `/personality`
  page actions. It is read-only and does not implicitly attach history.
- `POST /sessions/{id}/binding`: `persona_id` (empty uses the configured default),
  `expected_generation`, `acknowledge_history_through`. The idle bridge validates
  the current boundary. The page fills generations/boundaries internally.
  Setup and binding refuse atomically if another native compaction strategy is
  explicitly selected. Select personality through the existing `/extensions`
  action first; suspended bindings and native choices remain unchanged on refusal.
- `GET /sessions/{id}/document`: optional `revision`, `offset`, `limit`.
- `POST /sessions/{id}/document`: `content`, optional `expected_revision` and
  transport `retry_key`.
- `POST /sessions/{id}/edit`: `old_string`, `new_string`, optional `replace_all`
  and transport `retry_key`.

Managed preparation resolves a fresh selected owner session to the configured
default before the first transcript admission and before its selection snapshot.
Resolution is idempotent and never creates a persona. It pins native selection
so later global defaults do not replace an already bound identity. Existing
unbound transcripts require deliberate idle attachment; their exact boundary
remains witnessed history. Children never create permanent identities. Pinning
advances the native session configuration revision only when that choice changes;
it does not introduce an identity-wide head.

## Selected failures and storage

Mandatory request context is declared with `required_when_selected=true`.
Admission resolves raw persisted native selection using original declarations,
including quarantined declarations, before checking the loaded composition.
A quarantined extension may be absent from `composition.requested`; that alone
cannot establish availability. Selected personality failures are explicit.
Ordinary unselected requests never query personality tables or depend on the
removed global session-admission table. This selected fail-closed policy is an
Albedo adaptation; the audited source InstructionsModule fails open.

The extension owns identity, document revision, default, binding/binding history,
trusted call receipt and human setup receipt tables plus a schema marker. The
fresh experimental schema is supported. An incompatible legacy or damaged schema
is detected before any rewrite and left intact, quarantining this bundle. No
claim-to-memory conversion or destructive migration is provided. Real user data
requires a separately reviewed lossless migration. Session cleanup uses the
native graph cleaner and removes current session bindings; permanent identities,
revisions and receipts remain.

Native LCM remains the sole episodic store. Its tools, raw transcript, actor
attribution and source boundaries remain intact. Narration/background/delegation
corrections are separate stages; this document surface does not establish those
later behaviors or real-model narrative quality.

## Optional lessons

`personality-lessons` provides `lesson_create`, `lesson_read`, `lesson_query`,
`lesson_update`, `lesson_deprecate` and `lesson_history`. Creation requires only
content and tags; confidence defaults to 0.5 and evidence to `[]`. Ordinary
external reference strings are valid evidence. Updates merge evidence and retain
revision history; deprecation records a reason without deleting history. Native
actor/session metadata and trusted-call receipts are automatic.

Lessons are identity-scoped and bounded per record/page, with no lifetime quota.
Query/history pages contain at most 20 records; follow `next_offset`. No automatic
lesson injection, provenance category, uncertainty prose, exact transcript range
or report acceptance is required. Optional state owns its own tables and cannot
repair a damaged schema or add tables to a quarantined legacy identity. Core
identity capture works without this extension or any lesson table.

The authenticated optional service exposes `/extensions/personality-lessons/
sessions/{id}/lessons`, item read/update, `/deprecate` and bounded `/history`.
Model tools remain the main direct lesson interface. This correction does not
port the source's optional intelligent retrieval module.
