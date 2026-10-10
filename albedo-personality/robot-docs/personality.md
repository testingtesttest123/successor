# personality

`personality` is installed and disabled by default. Installation creates its
extension-owned tables, never an identity or a session binding. Workspaces,
ordinary session creation, transcript forks and delegation do not create
permanent identities. An ordinary session with personality disabled and no
binding continues to behave as before.

This first setup layer persists empty identities, human configuration, explicit
owner bindings, operation receipts and audit events. It validates admission on
each request. Revisioned identity edits and native inspect/edit tools use the
same domain transaction as authenticated human edits. Dynamic identity projection
and source-backed curated memories are available. Automatic recall and delegate
working-context APIs remain separate additions. No new background model call,
worker or scheduler is started.

## Human setup

Enable the extension globally through the existing extension settings API to
make its authenticated service and `/personality` resource page available.
Session selection remains independent. Selecting personality without a binding
reports `setup_required` and refuses request preparation before dispatch.

All service operations require the daemon bearer token. Bodies are limited to
64 KiB and unknown fields are rejected. The adapter supplies user authority;
`author`, `mode` or authority assertions in a body do not confer permissions.
There is no model-callable creation, default-selection or binding command.
`persona_create` is a human page action. As elsewhere in Albedo, this is a
convenience-API authority boundary, not a sandbox against arbitrary Python or
filesystem access the host has separately granted.

- `POST /extensions/personality/personas`: `operation_id`, `name`, optional
  `make_default`, `agent_identity_edits`, and `agent_memory_edits`. The two agent
  edit settings default to true. Creation always stores a new empty identity;
  it copies no instructions, memories, relationships or commitments. The first
  setup action on the page explicitly creates and selects the default.
- `POST /extensions/personality/default`: `operation_id`, an existing
  `persona_id`, and its `expected_revision`. Selection changes configuration
  without creating or cloning an identity.
- `GET /extensions/personality/sessions/{id}`: the current binding and revisions,
  bound identity, edit controls/usage, configured default, human page actions,
  and a pre-binding history disclosure with the exact current transcript
  high-water position.
  These values are captured together on one store turn, including when unbound.
- `POST /extensions/personality/sessions/{id}/binding`: `operation_id`, exactly
  one existing `persona_id` or `use_default: true`, `expected_binding_revision`,
  and `acknowledge_history_through` copied from the disclosure. History or
  binding changes reject the operation. The authenticated adapter opens only
  the session actor and uses its idle mutation bridge; it does not start Python.
- `DELETE /extensions/personality/sessions/{id}/binding`: `operation_id` and
  `expected_binding_revision`. Unbinding advances the binding revision and
  atomically clears its core admission requirement. If personality remains
  selected, setup is required again before another request.
- `POST /extensions/personality/personas/{id}/archive`: `operation_id` and
  `expected_revision`. Any active session binding refuses archival. Archival
  retains revisions, receipts and events and clears that identity as default;
  irreversible erasure is not supported.

A configured default is reused by explicit default-binding operations across
workspaces and new owner sessions. It is never automatically created or bound.
Binding existing history explicitly makes that session history visible while
retaining its `pre_binding` provenance and exact boundary. No transcript byte
or LCM row is rewritten or retroactively claimed as direct experience. Owner
binding refuses a family child; authorized read-only delegate attachment belongs
to its separate parent path.

Setup operations commit their result with their changes. Identical operation-ID
retries return the original result; reuse with different content is a conflict.
Binding revisions remain monotonic after unbinding. Identity revisions and
aggregate persona revisions are separate: setup starts both at one, and domain
configuration/binding changes advance only the aggregate revision. Agent edits
honor the human edit configuration and field locks.
A rebind to a different persona advances and audits both the removed and added
associations atomically. A same-persona rebind advances that persona once;
receipt replay changes neither head nor event trail.

## Admission and storage

The extension owns `personality_persona`, `personality_revision`,
`personality_default`, `personality_session`, `personality_event`, and
`personality_operation`, plus identity controls, capacity and trusted call
receipt tables. Its schema migration is one transaction and validates
the real table identity and every used column of all thirteen tables before
installation succeeds. A failure quarantines the whole bundle, including its
service and commands. Neither migration nor reload copies identity state or
touches transcript and LCM storage.

The daemon owns the generic `session_requirements` table. Binding/unbinding and
its `personality` requirement commit on the same connection in the same
transaction. Required capability checks use the loaded-active composition,
independently of personality activation or tables, before invoking request-time
callbacks. A quarantined, absent, disabled or failed bundle cannot silently
remove a bound identity's requirement. Missing, unreadable or view-replaced core
admission state fails closed, including for ordinary requests. Every requirement
read checks the real main-schema table on the same store turn. The applied core
migration marker prevents startup from recreating a missing guard as empty;
restore the database rather than silently repairing authority state.

The personality request-context callback captures its binding and current
identity together on the store owner and validates an active owner binding.
Missing binding storage is a preparation error. Current identity fields are
validated at 4 KiB UTF-8 each and 12 KiB total. Request-time projection renders
the one captured identity snapshot within the shared prompt budget. Curated
memory inspection does not automatically add claims to request context.
Normal preparation, explicit compaction/project inspection and managed background
request admission all use the generic loaded-composition guard. No provider or
network work runs inside capture, transactions, or observers.

Session deletion removes the session's binding and core requirement through
existing cleanup/cascades; it does not erase the permanent identity or audit
history.


## Revisioned identity edits

`POST /extensions/personality/sessions/{id}/identity` is an authenticated human
adapter to `domain.mutate`. It supplies the user actor independently of the
request body. Required fields are `operation_id`, `expected_revision`,
`expected_identity_revision`, and `reason`; `changes` is an object containing
any of `self_description`, `values`, `communication`, and `instructions`.
Each field is limited to 4 KiB UTF-8 and the resulting current identity to
12 KiB total. The whole mutation is at most 64 KiB. The reason is nonempty and
at most 4 KiB; operation IDs are nonempty and at most 128 UTF-8 bytes.

Only this human adapter accepts `controls`: optional `field_locks` (an array of
unique editable-field names), `agent_identity_edits`, and `agent_memory_edits`.
Controls are revisioned domain mutations. Control-only changes advance the
aggregate head and leave the identity revision unchanged. Users can correct a
locked field; owner agents cannot. There is no model permission-setting API.
The same mutation may include curated memory changes, described below.

Native tools are available only through the selected personality bundle:

- `persona_inspect`: optional integer `cursor`, initially zero. Each page contains
  current aggregate/identity heads, binding revision, edit controls, usage and
  one identity field chunk with its `scalar_offset`. Follow `next_cursor` and
  join chunks belonging to the same field. Pages contain at most one record and
  8 KiB rendered UTF-8, including labels and JSON escaping. The native inspection
  captures identity, controls and usage on one store turn and performs no write.
- `persona_edit`: `operation_id`, `expected_revision`,
  `expected_identity_revision`, `changes`, and `reason`. It accepts no free
  persona ID, actor, binding, owner, controls, or permission fields, including
  unknown nested fields. The host context supplies both the bound owner session
  and trusted tool-call ID. Unbound, archived and temporary-child contexts cannot
  edit an owner identity.

An edit checks authority and both expected heads, appends an immutable identity
revision when fields are edited, appends an event, updates pointers/settings,
accounts its payload, and stores the exact operation response in one immediate
store transaction. A failure, including receipt/mapping persistence or reserve
exhaustion, rolls back every change. There is no network/provider work in the
transaction and no new actor, worker, scheduler or background model call.

Receipts include `operation_id`, `persona_id`, `actor`, `origin_session`,
`origin_call_id`, `event_id`, `revision`, `identity_revision`, and canonical
SHA-256 `payload_hash`. Object-key and field-lock set order do not affect the
canonical payload. The operation receipt is checked before stale heads, so an
identical retry returns its original receipt. Changed content or actor with the
same scoped operation ID returns `operation_id_reused`. Stale heads return
`conflict` with structured `current_heads`. Locks or disabled agent identity
edits return `forbidden`; there is no automatic merge.

Operation keys are scoped to current persona and origin session using an
injective encoding. `GET /extensions/personality/sessions/{id}/receipts/{operation}`
returns only a receipt in that current binding/origin scope. Changing bindings
cannot disclose an old persona's receipts, and another owner session cannot use
an operation ID as a receipt oracle. Human-only setup receipts retain their
existing contract.

For native writes, the transaction also persists a trusted call-to-operation
mapping and exact response. An identical operation retried by a different native
call can map to the same response without a second event/revision. Reusing a
trusted call ID for a different operation rolls back the attempted edit.
At absolute reserve exhaustion, replay still returns the original operation
receipt without writing an alias for the new call. The original trusted call
remains recoverable. Recovery of an unmapped retry returns no saved result and
never repeats a write; if publication of that retry is lost, inspect its scoped
operation receipt. The host recovery callback has only trusted context/call ID,
not original arguments, so it cannot infer an operation ID safely.
Recovery looks up only the trusted current-persona/session/call mapping and
returns its exact saved response; it never invokes a mutation for an unknown
call. Cancellation after a commit leaves the identity edit and receipts visible.
These API authority checks do not sandbox separately authorized arbitrary
Python or filesystem access.

## Payload accounting

The additive extension tables `personality_controls`, `personality_capacity`,
and `personality_tool_receipt` persist locks, usage/reserve configuration and
trusted call receipts. Schema installation validates every used column of all
thirteen extension tables in the same transaction and backfills capacity rows for
existing identities without rewriting their identity, history or setup receipts.
New human creation initializes capacity on its existing transaction. Inspection
and recovery never initialize or change persistent state.

The ledger exposes ordinary setup/memory payload usage and the
100 MiB ordinary limit separately from corrective payload usage and its further
10 MiB reserve. All identity edits/control changes and their complete canonical
request, event/revision metadata, operation receipt and trusted-call mapping
payloads are charged to the corrective reserve. Accounting is conservative
logical payload accounting, not a measurement of SQLite pages. Identity edits
remain available when ordinary admission is full and consume no new curated
record slots. Reserve exhaustion returns `capacity_exceeded` with an actionable
user-maintenance diagnostic; it retains readable history and never silently
expires data. Capacity settings have no model mutation surface. Curated record
and source payloads use the ordinary admission guard described below; bulk
import and delegate handback remain separate additions.


## Source-backed curated memories

Curated formation is deliberate foreground work through `persona_edit` or the
human API. If no memory operation runs, no curated claim is created. There is
no extraction worker, background model call, automatic recall/ranking, or changed
LCM summarization policy in this layer. Persona/source text is inert evidence,
never a grant of tool authority or independently verified truth.

Both `POST /extensions/personality/sessions/{id}/memories` and the existing
`.../identity` route accept the shared mutation envelope: `operation_id`,
`expected_revision`, `expected_identity_revision`, `reason`, optional identity
`changes`, optional human-only `controls`, and optional `memories`. The native
`persona_edit` accepts the same envelope except controls. There are at most 32
total changes and 64 KiB per request. Agent identity and memory edit controls
are enforced independently. Native writes retain the same trusted call mapping,
operation receipt, atomic rollback and recovery semantics as identity edits.

Each memory change accepts:

- `text` (nonempty, at most 4 KiB UTF-8), `provenance` and `uncertainty`
  (nonempty, at most 128 bytes). Provenance is one of experienced, imported,
  inferred, reported or inherited. It is capped by actual source/binding origin;
  a requested label cannot raise supplied or reported material to experience.
- Optional `importance` (0–3), at most 16 distinct `tags` (128 bytes each), and
  `temporal_scope` (128 bytes). Temporal scope is an explicit assertion, not a
  parsed or invented date.
- `sources`: at most 16 evidence links. A link's `relation` is supports,
  contradicts or corrects. For new evidence, give inclusive `first_seq` and
  `last_seq` in the trusted current owner session, optional expected `digest`,
  and optional `lcm_hint` (128 bytes). No session, persona, actor or origin can
  be supplied. Alternatively give only an already-authorized `source_id` and
  optional expected digest; its exact saved range and lineage cannot be changed.
- New records omit `id`, use action `remember` (the default), expected revision
  zero, and require evidence. Existing records require their stable `id`, exact
  `expected_revision`, and action `correct`, `contradict` or `retract`.

A correction appends a new revision at the same stable ID, retains every old
origin with corrects links, and replaces the current claim. An explicit
contradiction preserves previous supports/contradicts and marks the new current
revision unresolved. A later correction converts previous links to corrects;
only newly supplied contradictions keep that correction unresolved. A retraction
appends a retracted head, with its evidence and reason retained. No old revision
is rewritten or erased. Active/current inspection excludes superseded and
retracted claims; explicit history inspection preserves their audit trail.
The 16-link bound includes retained evidence, so an oversized correction fails
atomically rather than dropping origins. Revisions record user/owner-agent
actor, origin session, event, reason, uncertainty and current metadata.

Source resolution validates the actual endpoint rows and ordered payloads, not
numeric guesses. It captures trusted durable submission origins where available:
chat assertions, owner-agent output, tool reports, persisted mail sender/kind,
and host notes. Text that resembles mail or a host note cannot choose its actor.
Actual anonymous Note/Chat submissions persist display metadata in their existing
transcript commit. Namespaced host-note identity distinguishes supplied notes
even when an origin happens to be named chat or mail. Legacy User rows without
trusted submission metadata have `unknown_origin` and imported provenance; a
wrapper or saved User role alone cannot certify the original submitter.
A user assertion is labeled as being told and an unverified claim; its contents
are never certified merely by persistence. Pre-binding rows remain imported
supplied history. A range crossing the disclosed boundary must be split.
Tool/mail reports are capped as reported, and administrative host notes as
supplied/imported. Mixed revisions retain all source actors and origins.

Canonical integrity is SHA-256 of compact JSON triples in row order:
`[actual_seq, lowercase_hex_of_saved_payload, trusted_actor_label]`.
Source IDs additionally bind persona, session, exact boundaries, digest, origin
and binding revision. The source row retains that exact range, actors, binding
revision/boundary and optional LCM hint. An LCM hint is never authority; missing
or reorganized hints use the canonical transcript range. Changed/reordered rows,
changed actor metadata, invalid endpoints or unreadable rows return
`source_unavailable`; no different row is substituted.

Bounded metadata prevalidation runs without a write transaction. Unique exact
ranges in one mutation have a combined limit of 256 rows and 256 KiB of packed
transcript/submission metadata. Each range is materialized/digested once per
validation; repeated links do not multiply body reads. Complete actor labels
have a 1-KiB rendered metadata limit. Wider evidence must be split into narrower
operations/ranges; labels are never clipped. The short final transaction checks
the binding, persona/identity/record heads, source ranges and digests again before
committing revisions, links, sources, head/event, usage and exact receipts.

## Memory and source inspection

Human reads use `GET .../sessions/{id}/memories`, or append a stable record ID.
`history=true` explicitly includes old revisions; default false reads only active
heads. `cursor` is an opaque scoped continuation. Native `persona_inspect` adds
`view="memories"`, optional `record_id`, `history=false`, and `memory_cursor`.
The existing default identity view retains its integer cursor contract.

Memory pages contain one complete labeled fragment, so are always below the
50-record cap, and at most 8 KiB rendered UTF-8 including the JSON envelope.
They return `records`, `fragment`, `next_cursor` and exact rendered `bytes`.
Concatenate `text` and `reason` for each ID/revision in fragment order; collect
its tags/evidence links across fragments. Text/reason chunks contain at most 128
Unicode scalars, with at most one full tag and evidence link per fragment.
Every fragment carries the same complete-revision `attribution`, `source_origins`,
`source_actor_kinds` and `evidence_source_ids`, computed before fragmentation.
`being_told` therefore never changes on later parts of a user-sourced claim.
Actor kinds preserve user/owner/tool/system-note/agent-report/external-report/
unknown distinctions. `evidence_details="separately_paged_exact_labels"` explicitly
locates full origin names, reporter labels and exact range metadata in the
evidence fragments identified by those source IDs. Collect these full labels
across pages; they are never clipped. This compact stable envelope adds no new
mutation admission cap and preserves all sixteen evidence links.
Cursors bind current persona, owner session, binding revision, aggregate head,
record filter and history choice. A changed head or different scope is an explicit
conflict; it never silently continues into another persona/history.

Native `persona_source(source_id, cursor)` and human
`GET .../sessions/{id}/sources/{source_id}?cursor=...` accept only a previously
persisted source authorized for the currently bound owner persona. There is no
free session or persona search parameter. They return text, full source metadata,
next cursor and exact rendered bytes, capped at 8 KiB. Text chunks are at most
768 Unicode scalars, with actual row/actor labels. Cursors bind the exact source
ID and digest. Sources can span different deliberately bound owner sessions,
without granting access to any other range or identity. Temporary child contexts
have no owner source/read/write authority in this layer.

The existing extension cleanup marks that deleted session's surviving source
references unavailable before removing its binding. Records, receipts, source
metadata and revisions remain; no hidden copy of transcript text is kept.
Expansion reports deleted or invalid evidence unavailable. Recreating unrelated
rows cannot revive a source retired by cleanup.

## Memory capacity and migration

The existing extension-owned atomic schema migration now validates thirteen
real tables, including `personality_memory`, `personality_memory_revision`,
`personality_source` and `personality_memory_source`, with persona-scoped indexes.
It adds memory payload accounting and a default 10,000-record limit to the
existing capacity table; existing setup/identity rows and receipt format remain
compatible. Identity-only canonical requests keep their prior representation,
so existing receipts replay after this additive upgrade. No core schema,
transcript, LCM row or required-capability policy is changed.

New records, including mixed requests that also correct existing records, charge
the ordinary 100-MiB budget. Corrections/retractions and identity/control-only
writes use the separate 10-MiB corrective reserve and add no record slots.
Accounting includes complete canonical requests, current/revision/link/source
metadata, events, receipts and native call mappings, conservatively including
serialization overhead. Later setup accounting preserves all memory charges.
Usage inspection includes both headrooms, current retained record count and
record limit. Retracted stable IDs retain their slots and audit history; no age
expiry or silent forgetting is performed. Exhaustion rolls back every write and
returns `capacity_exceeded`. Existing records/receipts remain readable.
Increasing persistent capacity does not enlarge per-operation or page budgets.

Real HTTP scenarios live in `test/e2e/personality_memory_test.py`. Its separate
provider class retains both protocol native-tool/kernel lifecycle assertions;
under the documented restricted executor those remain unverified. Socket-free
native transaction/publication invariants live in
`test/harness/personality_memory_test.gleam`. A passing adapter test is not a
claim that the unavailable provider/kernel lane passed.
