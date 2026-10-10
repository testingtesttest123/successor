# Albedo coding machinery reuse

The user explicitly chose an independent successor with agent-owned Python
workspaces, and encouraged substantial Albedo code reuse. Albedo is reusable
source, not merely architectural inspiration. Avoid unnecessary reinvention.

Reference pin: `8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450`,
https://tangled.org/okami.mom/albedo. Its root license is WTFPL v2. Retain source
pin/path and applicable third-party notices whenever code is actually copied.
Successor's small workspace bridge was independently implemented. The files,
jobs, bounded output and checked process-cleanup cohort is now actually adapted
locally; this is **not clean-room work**. See
[the notice inventory](../THIRD_PARTY_NOTICES.md),
[helper contract](coding-helpers-contract.md) and
[local evidence](coding-helpers-results.md). Trace and provider cohorts below
remain future work.

## Cohort map (coding helpers implemented locally; trace/providers later)

| Cohort | Pinned source paths | Adaptation boundary |
| --- | --- | --- |
| Files | `priv/python/albedo_plugins/files.py` | Lift stdlib read/write/exact-edit/line paging; retain useful diagnostics. Connect rg/diff search to owned jobs, not anonymous subprocesses. Keep per-agent scratch vs explicit project path distinct. |
| Jobs | `priv/python/albedo_plugins/run.py`, `albedo_proc.py`, `albedo_output.py` | Extract Job/Outlet/Feed core and asyncio lifecycle. Replace Albedo loop/capture/send/host hooks with successor-owned interfaces; preserve group cleanup, pipeline ownership and cancellation. |
| Bounded output | `priv/python/albedo_capture.py`, `albedo_output.py`, portions of `albedo_api.py` | Reuse bounded first+tail retention, spill, paged reads, atomic saving and refusal of incomplete output. Separate bytes/retention from trace and image dependencies. |
| Process cleanup | `priv/python/albedo_proc.py`, `albedo_signal.py` | Nearly standalone stdlib/POSIX cleanup: start tokens, zombie-aware group probes, TERM/KILL verdicts. Integrate survivor reporting rather than blindly declaring cleanup complete. |
| Trace | `priv/python/albedo_trace.py` and related value types | Keep stable cell/job correlation and useful history while making the DeploymentStore authoritative for successor intent/results. Do not introduce another durable writer. |
| Provider transports | `src/albedo/openai_api/`, `src/albedo/harness/extensions/{openai,claude,codex,...}/` and associated request/wire fixtures | Adapt transports and fixture coverage to successor's typed provider/capsule boundary. Explicit credentials only; retain our pre-dispatch intent and uncertainty rules. |

Jobs also depend on `albedo_shell`, `albedo_shims`, `albedo_trace` and small
`albedo_api.py` protocols/constants. Files intentionally route search through
those jobs. Port these dependencies deliberately as a cohort or split pure
utilities; do not accumulate copied but unreachable modules.

## Do not drag in the entire daemon

`albedo_cells.py`, `albedo_link.py`, `albedo_python.erl` and detached recovery
are coupled to Albedo's store, daemon routes, background wakes, SSH, plugins,
images and replay policy. Do not transplant these wholesale just to gain one
helper. The current successor transport remains small. Broader asynchronous
Python support/tool projection should reuse the relevant mechanisms and tests
without replacing stable agent identity, source-before-dispatch journaling,
incarnation fences, or honest unknown effects.

The coding cohort is implemented; remaining rows are inputs for subsequent slices;
model tool dispatch, inference subagents, remote workers and UI are separate
capabilities, not implied by copying helper code.
