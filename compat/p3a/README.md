# P3a native lifecycle seam

This is the approved bounded child/fork extraction, delivered as an external
acceptance consumer plus an explicit Albedo patch after P0. Successor remains
in `packages/successor_extension`; no product host source tree is vendored.
This development fixture targets the adapted Albedo worktree based on
`e086179bbaa8beda2b2a20e688dfa86bfe39b190`. The historical patch series remains
reference material; do not run the historical `freeze.py` on this worktree.

The host owns native creation, family membership, initial inbox work and durable
prefix copying. An installed declaration may contribute connection-only
`Created`, `Child` and `Fork` callbacks. Lifecycle owners are captured once at
runtime installation, independently of per-session enablement. Canonical
quarantined declarations retain their read-only guards: needed state refuses
creation when its owner cannot apply. A false guard is an unrelated no-op.
The host now independently persists generic session capability requirements.
Required sessions fail closed if the entire owner disappears. Native child, fork
and rewind operations reject required sessions until inheritance is supported.

The callback contract is trusted host code: bounded reads in `needed_in`, only
SQL on the supplied connection in `apply_in`, no nested transactions, store
actor reentry, bus notifications, process/actor creation, kernel/provider calls
or external effects. Catchable callback crashes become transaction errors.
Native notifications and activation follow commit. Identified callbacks run
inside the admission mutation and never during receipt recovery; existing and
deleted session preconditions retain their earlier behavior.

Fork maps contain exact ordered source/branch `SourceRef` pairs for copied rows.
They exclude synthetic tool completions. The existing direct stock LCM call
and both LCM modules remain unchanged, including inheritance when the runtime
catalog omits lcm-memory. The generic host requirement table is independent of the fixture identity
tables; this fixture does not implement product identity inheritance.

Connectome comparison: actual connectome-host
c1203a5a7d75fddb7ab1c93d95987b6fb015fc75 (tree
69a3f17bdef6e83401a316af59fbd6c13b897d1e),
`src/modules/subagent-module.ts` creates fresh ephemeral agents for spawn and
adds their task before compilation. Its fork resolves the actual caller,
structurally cuts compiled messages at the matching fork call, removes sibling
dispatch and later messages, remaps the participant and adds fork framing.
`src/recipe.ts` and `test/witnessed-identity.test.ts` provide the previously
reviewed personality inheritance reference. Albedo adapts these prerequisites
to a durable native SQL transaction and exact transcript positions. This seam
does not port Connectome's ephemeral-agent strategy, message transformation,
product identity, narration or provider behavior. The separate identity-module
is deployment authentication and is not treated as a personality binding.

The development fixture resolves `../../../../albedo`. Run against that local
worktree with the isolated Gleam 1.19 / OTP 29 toolchain:

```sh
cd compat/p3a/fixture_app
gleam deps download
gleam test
gleam check
gleam format --check test
```

The final review snapshot and source inventory are produced by the integration
workspace, rather than by the historical exact-tree freeze script. Focused tests
are bounded lifecycle evidence, not whole-host qualification or deployment.
