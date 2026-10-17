# Current P0 composition acceptance

The fixture now uses the sibling current Albedo checkout at
`e086179bbaa8beda2b2a20e688dfa86bfe39b190` plus
`patches/albedo-current/0001-durable-main-identity.patch`. Its real-daemon cases
cover custom/stock composition, authenticated services, quarantine, home ownership,
registry/listener recovery, parent death, storage helpers and copied asset identity.
The listener restart probe selects the published daemon port because current
Albedo also owns a webhook listener. Tests request an ephemeral webhook port.
Asset comparison uses Git-tracked source assets rather than generated runtime caches.

Build `compat/p0/fixture_app` with `gleam build`, then use `snapshot.py` to copy
all compiled packages and assets into a fresh snapshot directory. Run
`test_composition.py` through the host Python runner with `P0_SOURCE_ROOT`,
`P0_SNAPSHOT`, and a fresh `P0_TEST_EVIDENCE` directory. This container requires
a process-owning subreaper wrapper so orphaned test children are reaped; it changes
neither assertions nor timeouts. The current fixture passes all 12 cases.

The old `freeze.py` below this directory targets historical e9df547 and is retained
only as historical evidence. Do not use it to freeze the current host. Current
qualification uses copied snapshots and recorded source hashes. A passing P0
fixture is not a complete host gate or production deployment qualification.
