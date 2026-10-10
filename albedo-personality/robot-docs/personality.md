# personality

`personality` is installed and disabled by default. Installation creates its
extension-owned tables, never an identity or a session binding. Workspaces,
ordinary session creation, transcript forks and delegation do not create
permanent identities. An ordinary session with personality disabled and no
binding continues to behave as before.

This first setup layer persists empty identities, human configuration, explicit
owner bindings, operation receipts and audit events. It validates admission on
each request. Revisioned identity edits and native inspect/edit tools use the
same domain transaction as authenticated human edits. Dynamic identity
projection, memory and delegate working-context APIs remain separate additions. No new background model call,
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
the real table identity and every used column of all nine tables before
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
validated at 4 KiB UTF-8 each and 12 KiB total. Its initial contribution is empty
apart from snapshot identity; later projection owns prompt text and budgets.
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
The first slice still has no memory mutation API.

Two native tools are available only through the selected personality bundle:

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
nine extension tables in the same transaction and backfills capacity rows for
existing identities without rewriting their identity, history or setup receipts.
New human creation initializes capacity on its existing transaction. Inspection
and recovery never initialize or change persistent state.

The current identity-edit slice exposes ordinary setup payload usage and the
100 MiB ordinary limit separately from corrective payload usage and its further
10 MiB reserve. All identity edits/control changes and their complete canonical
request, event/revision metadata, operation receipt and trusted-call mapping
payloads are charged to the corrective reserve. Accounting is conservative
logical payload accounting, not a measurement of SQLite pages. Identity edits
remain available when ordinary admission is full and consume no new curated
record slots. Reserve exhaustion returns `capacity_exceeded` with an actionable
user-maintenance diagnostic; it retains readable history and never silently
expires data. Capacity settings have no model mutation surface. General record,
source/import accounting and the current-record admission guard belong to the
later record-domain slice.
