# Third-party source notices

## Albedo

Source: https://tangled.org/okami.mom/albedo
Pinned revision: `8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450`
Copyright (C) 2026 albedo contributors (okami.mom & ptr.pet).
License: WTFPL version 2; verbatim pinned license in
[`licenses/Albedo-WTFPL-2.txt`](licenses/Albedo-WTFPL-2.txt).

Actual copied/adapted source, not clean-room work:

| Successor file | Pinned Albedo source | Changes |
| --- | --- | --- |
| `priv/python/successor_tools/api.py` | `priv/python/albedo_api.py` | Small text/list/excerpt/output protocols; removes host/remote/image coupling. |
| `priv/python/successor_tools/capture.py` | `priv/python/albedo_capture.py` | Per-capture ownership, bounded prefix spill; removes pruning, trace/image/host hooks. |
| `priv/python/successor_tools/output.py` | `priv/python/albedo_output.py`, registry behavior from `priv/python/albedo_cells.py` | Local bounded read/atomic save and incarnation-local registry; removes daemon/SSH callbacks. |
| `priv/python/successor_tools/files.py` | `priv/python/albedo_plugins/files.py` | Local supervised rg, atomic bounded writes/edits, bounded diagnostics, no host/trace callbacks. |
| `priv/python/successor_tools/jobs.py` | `priv/python/albedo_plugins/run.py`, `priv/python/albedo_output.py` | Job/Command/Outlet/Feed mechanics, per-runtime admission/retention, successor independent guardian/lease ownership; no shell/remote/daemon/hooks. |
| `priv/python/successor_tools/proc.py` | `priv/python/albedo_proc.py` | Verbatim source after a three-line provenance header. |

`guardian.py` and `command.py` are new successor adapters around the copied
process primitives. The small Gleam/Erlang workspace transport is independently
implemented, not copied from Albedo's daemon. Each adapted module also records
its provenance. This cohort uses Python stdlib only; Albedo's vendored/nonstdlib
renderer, image, shim, SSH and tracing dependencies are not bundled.
This notice describes imported source licensing, not a new repository-wide
license grant for otherwise independent successor code.
