# Successor bounded main identity extension

This package implements one durable, explicitly initialized main identity on the
adapted Albedo host based on commit `e086179bbaa8beda2b2a20e688dfa86bfe39b190`.
Its `gleam.toml` currently uses the sibling development host at `../../../albedo`;
the Gleam-generated manifest records that local dependency. Qualification runners
freeze both sources together; this package does not work against unpatched
historical Albedo.

The external extension owns fresh v2 identity storage, immutable document
revisions, explicit bindings, document tools, projection and an authenticated
service. Albedo owns idle ordering, persistent admission requirements, request
capture, capacity enforcement and descendant refusal. The separate
`apps/successor_daemon` composition installs this declaration explicitly.

## Verification

Activate the isolated toolchain, then run from this directory:

```sh
gleam check
gleam test
gleam format --check src test
python3 ../../compat/main_identity/run.py
```

The fixture runner uses a fresh temporary home and strips provider credentials.
Package tests cover real SQLite transactions, restart, schema refusal, document
limits, receipt replay, native tool authority and complete projection. HTTP and
scripted-provider integration lives in `compat/live_identity`; host lifecycle and
captured-request contracts are exercised in `compat/p3a` and `compat/p1`.
Package success alone is not whole-host qualification. Current evidence and
remaining baseline failures are recorded by the integration run.

## Setup and operation

The opt-in `successor/personality/extension.extension()` declaration supplies the
`personality` required request contributor. It is never added to stock defaults.
The user must explicitly POST a setup request through the daemon-token service,
`/extensions/personality/sessions/{session}/setup`, with `name`, `content`,
`writable` (optional, default true), and a required `retry_key`.

Only one main identity can be initialized. Setup creates its explicit default,
owner binding, immutable first revision, replay receipt and host requirement in
one transaction. Existing identity tables are validated without migration;
existing bindings missing their host requirement refuse capture, without backfill.

Authenticated session routes also provide GET inspection and paginated
`/document`, POST `/document` (`content`, `expected_revision`, `retry_key`), and
POST `/edit` (`old_string`, `new_string`, `replace_all`, `expected_revision`,
`retry_key`). Model tools derive session, actor and call ID from host context;
write/edit require an expected revision and expose no identity creation or binding.
Model recovery accepts only stored owner-agent receipts for the exact native
session and call; user receipts cannot report success for a model call with a
colliding ID. Provider call IDs remain opaque, including `human:` prefixes.
Documents are limited to 1 MiB UTF-8; read pages to 32 KiB. Request projection
includes the complete mandatory identity document, and the host refuses overflow.

User-only `/binding` accepts the main identity ID (or the configured default),
`expected_generation`, and `acknowledge_history_through`. `/unbind` accepts
`expected_generation`. Both run through the native idle session bridge. Unbind
retains documents and history, atomically releases the host requirement, and
leaves personality selected in setup-required state until the user explicitly
changes selection. Binding generations survive unbinding, preventing stale rebinds. GET inspection
returns `binding_generation` independently of nullable `binding`: zero before the
first binding and the latest retained binding revision after unbind. Fresh clients
use this field as `expected_generation` when binding again. Inspection reads the
binding, generation and history boundary in one database transaction.
Saved choices and a retained kernel's composition may differ until the user
explicitly reloads the session. If binding enables personality on an already
running stock composition, requests refuse with `reload required`; the native
session reload then installs the required contributor. Deselection likewise
cannot dispatch a stale captured identity. Unbinding keeps personality selected:
requests refuse on the stale composition and, after reload, require setup rather
than silently becoming stock requests.

There are no additional-persona, default-switching, delegate, migration or memory
APIs. Bound child/fork/rewind rejection belongs to the host requirement layer.

Recovered candidate modules are adapted with original attribution preserved in
`UPSTREAM-LICENSE.txt` and per-source hashes recorded in `provenance.json`.
The native SQLite test fixture is run by `compat/main_identity/run.py`.

## Historical extraction and attribution

The original slice extracted `types`, `domain`, and read-only schema validation
from reference commit `fb1f4dc4099d915ee926139fc49a5c55bb63eac4` against historical
Albedo `e9df547f67f6819ebcd217649be326e53111027c`. Its historical
`verify_extension_slice1.py` checks that old extraction and host pin; it is not a
verification gate for this implemented adaptation. Historical Successor aggregate
qualification remains FAILED/OPEN, distinct from the bounded slice's evidence.

This is attributed copied/adapted source, not a clean-room implementation.
`provenance.json` retains historical source hashes and recovered candidate hashes;
`UPSTREAM-LICENSE.txt` preserves upstream attribution. No repository-wide license
grant, general persona management, migration, or background-memory support is
introduced.
