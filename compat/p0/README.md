# P0 composition acceptance

The production patch is `patches/albedo/0001-configurable-server-start.patch`
against unpatched Albedo e9df547f67f6819ebcd217649be326e53111027c. Its only
production owner is daemon/server; the adjacent extension document describes
ownership. The explicit series leaves the immutable Slice1 Git dependency and
reference untouched. No later seam or product extension is installed.

The independent fixture app uses one local Albedo dependency. It supplies only
declarations before home locking; installation effects are invoked by the host
after locking. The complete startup, native VM wrapper and actual app entrypoint
are used. There are no model turns, provider accounts or Python kernels.

From the repository root, with an existing authorized exact-host Git checkout:

```sh
python3 compat/p0/freeze.py "$PWD" "$AUTHORIZED_HOST" "$EVIDENCE/candidate"
cd "$EVIDENCE/candidate/source/compat/p0/fixture_app"
gleam build
gleam check
gleam format --check src
cd "$EVIDENCE/candidate/source"
python3 compat/p0/snapshot.py "$PWD" "$EVIDENCE/candidate/snapshot"
P0_SOURCE_ROOT="$PWD" P0_SNAPSHOT="$EVIDENCE/candidate/snapshot" \
P0_TEST_EVIDENCE="$EVIDENCE/candidate/cases" \
python3 build/upstream/albedo-p0/test/python_test_runner.py compat/p0/test_composition.py
```

Outputs must be new directories. Freeze verifies all 1,013 host Git blobs/modes
and exports all task source before compilation. Snapshot copies compiled code
and dependency assets, so no running daemon reads a changing source tree.
The host test loader rejects an empty selection. The 12 cases cover custom and
stock startup, disabled/quarantined services, exclusivity before effects, helper
JSON/EOF, core-storage failure, registry/listener recovery, parent ownership,
VM defaults and source-derived asset identity. Caller-owned child cleanup runs
on failed assertions; diagnostic files are retained.

`--red-control` is test-only API scaffolding that ignores supplied composition.
It is never part of the shipped host patch. The recorded assertion control has
6 passes/6 failures; the patched candidate has12 passes. Preserve full logs and
source hashes; package acceptance is not the broad host/full gate. Historical
qualification remains FAILED/OPEN. Build-digest semantics remain host ebin/priv;
this checkpoint makes no composition-aware distribution identity claim.
