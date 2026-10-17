# Current Albedo integration patch

Apply `0001-durable-main-identity.patch` only to Albedo
`e086179bbaa8beda2b2a20e688dfa86bfe39b190`. It is a cumulative local adaptation,
including host tests and documentation; it does not require the historical six
patches in `../albedo/` and must not be stacked on top of them.

The patch adds configurable daemon startup (including both listener ports),
transactional external lifecycle callbacks, generic persistent session capability
requirements, an authenticated service idle-mutation bridge, and captured native
request context. Required context is checked for foreground calls, summary calls,
retries and warming. Identity-specific documents and SQL remain in the external
Successor package. Until inheritance exists, any session with persisted
requirements cannot create a child, fork or rewind/archive descendant.

Required contributor selection is checked against the retained composition even
when a session has no persisted requirements. A changed required selection
refuses provider entry with a reload-required diagnostic until the user performs
the native session reload. This preserves Albedo's explicit reload semantics;
an idle service mutation does not silently rebuild every session kernel.
Saved background requests carry the configuration revision captured with their
observer handle. The session actor rejects a stale revision before provider
lookup, so unbind/rebind invalidates old warming requests without recapturing
their dynamic context. Document-only edits retain exact saved-request semantics.

The host requirement schema has a core migration marker. After initialization,
a missing or incompatible requirement table refuses startup rather than becoming
an empty set of requirements. Fresh identity schema initialization and explicit
setup belong to the external package; this patch does not migrate Successor data.

The historical patch series remains reference evidence: 0003 corrects 0002 and
0005 corrects test-only 0004. Current source changed substantially, so the new
patch was adapted and tested against the exact pin rather than applying that
series blindly. Patch application and reconstructed Git tree equality are
verified by the setup workspace's source export inventory.

For a new local checkout, verify its HEAD, then run `git apply --check` followed
by `git apply` on this cumulative patch. Keep the patched host as the sibling
`albedo` directory of this Successor checkout, matching local dependency paths.
Use Gleam to regenerate manifests if directory topology changes.

Qualification is bounded: focused external fixtures, the native host suite and
scripted local-provider identity acceptance. The unchanged full `./test.sh` gate
requires the remaining Nix/glinter/browser infrastructure. No upstream push,
provider account, deployment or production-state migration is part of this work.
