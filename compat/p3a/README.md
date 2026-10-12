# P3a native lifecycle seam

This is the approved bounded child/fork extraction, delivered as an external
acceptance consumer plus an explicit Albedo patch after P0. Successor remains
in `packages/successor_extension`; no product host source tree is vendored.
Albedo is pinned to e9df547f67f6819ebcd217649be326e53111027c.

The host owns native creation, family membership, initial inbox work and durable
prefix copying. An installed declaration may contribute connection-only
`Created`, `Child` and `Fork` callbacks. Lifecycle owners are captured once at
runtime installation, independently of per-session enablement. Canonical
quarantined declarations retain their read-only guards: needed state refuses
creation when its owner cannot apply. A false guard is an unrelated no-op.
Entirely absent declarations have no marker in this slice; protection against
removing an owner from a later composition remains pending.

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
catalog omits lcm-memory. No required-owner marker table, product identity
tables, origin fields, migration machinery or intermediate-store compatibility
promise is introduced.

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

`freeze.py` exports all checkpoint source and verifies all 1,013 exact host
Git blobs/modes before applying the hash-checked series. Build only that complete
export, so daemon priv assets cannot follow a changing working checkout.

```sh
python3 compat/p3a/freeze.py "$PWD" "$AUTHORIZED_HOST" "$EVIDENCE/candidate"
cd "$EVIDENCE/candidate/source/compat/p3a/fixture_app"
gleam test
gleam check
gleam format --check test
```

Acceptance is bounded P3a evidence. Historical qualification remains
FAILED/OPEN, including the two retained callback timing failures and the old
aggregate failures. No full host gate, product parity, deployment or migration
readiness is claimed.
