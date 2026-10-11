# Shared runtime helpers

## clocks

`albedo/clock.gleam` owns Gleam clock access. Use `system_ms` or
`system_seconds` for durable timestamps and expiry, `monotonic_ms` for elapsed
time and deadlines, and `os_system_ms` only when OS-clock semantics are required.
Store slow-query timing uses `clock.monotonic_ms`. Reuse these functions instead
of adding local clock externals or wrappers. Erlang native time units are
VM-dependent; request an explicit unit rather than dividing native ticks.

## Unicode scalar limits

`albedo/text_scalars.gleam` owns scalar counting and slicing. Its `length`,
`take`, `drop`, and `tail` scan UTF-8 without creating a whole codepoint list;
retained slices are copied so they release the source binary. Scalars are not
graphemes. Use these helpers for bounded previews and names, including from
Erlang through `'albedo@text_scalars':take(Text, Limit)`. The kernel job summary
retains at most 4096 scalars; truncating it must not allocate a list for the
entire command.

## shared values

`albedo/shared.gleam` owns values every process reads without copying.
`publish` stores one in a persistent term and answers a `Shared(a)` handle;
`read` returns the literal, which a spawn or send does not copy (a sublist of
it copies cons cells only). Publishing and `release` each scan every process:
publish once per lifetime, release in the owner's `stop`. Reading a released
handle panics. `runtime.Runtime` holds its installed extensions this way, so
a runtime copied into an HTTP request or a turn's worker costs a few words;
`test/harness/runtime_test.gleam` fails when the handle or a selection over
the installed list carries a copy. A literal references module code, so the
daemon does not hot-load a module while a shared value from it exists.

## native boundaries

Keep process state, ports, monitors, ETF, and native binary matching in their
Erlang owners. Reuse Gleam owners for pure validation and text projection.
A new Erlang shim should supply a native capability, not duplicate an existing
Gleam helper. Keep typed values through internal projections and encode JSON at
the wire boundary; see [command state projections](commands.md#contributing-commands).

`daemon/active_output.gleam` owns unfinished response identities, limits, and
projection transitions. Its native helper owns buffered spill file I/O, range
reads, leases, and filesystem cleanup. Capture flushes by absolute offset so
capturing the same immutable projection cannot append its buffered tail twice.
Do not move projection policy into an opaque Erlang map or reconstruct output
from replay events. The [session attachment contract](sessions.md) defines
cursor consistency, commit replacement, and reference lifetimes.

## session diagnostics

`daemon/session_diagnostics.gleam` owns named facts from `session_state.State`
for native probes: watcher owners, sequence, history residency, tool progress,
and the current run's worker. Erlang probes must call these typed accessors
instead of indexing the state tuple or searching its fields by constructor tag.
The memory inspector reports numbered fields and sizes; it must not mirror
Gleam record names or create atoms for field labels.

## finite actor calls

`albedo/actor_call.gleam` owns monitored calls that return `TimedOut` or
`CalleeDown` and remove their monitor on every outcome. Reuse `try_call` for
finite waits instead of copying subject lookup, reply selection, and monitor
cleanup. Callers own deadlines and translate failures into their domain errors;
a timeout does not cancel accepted work.

Kernel upgrade completion keeps its repeated wait until completion or owner
death. Session closure also waits for owner termination after the acknowledgment.
These lifetime protocols need more than a finite request/reply call.

## autobiographical memory jobs

`daemon/session_memory.gleam` owns one monitored background memory job per
session, separate from foreground `turn.Activity` and cache-warming calls. The
worker captures runtime/session handles and scalar configuration, not the actor's
resident history. `runtime.prepare_composition` uses the existing owned
composition preparation queue without opening Python; the same captured
compaction policy/settings seam serves foreground and memory preparation.
Native Summarizer calls run outside the session actor. Memory never emits
foreground status or replaces foreground usage.

`session_history.remember_response` notifies only after a durable nonempty
commit; candidate/timestamp-zero projections do not schedule work. Actor start
reconsiders the durable backlog. True graph progress yields another mailbox
tick, while no progress/error quiets that source watermark. New durable input,
configuration invalidation, or actual successful composition/kernel adoption
can rearm it. Adoption preserves a retry even if an earlier timed-out job has
not yet terminated. Errors and ignored kernel arrivals do not rearm. There is
no daemon-wide scheduler or recurring failed-job timer.

Composition-only preparation retains a host completion callback on its existing
waiter. Actual successful asynchronous installation notifies the session even
after its synchronous deadline; cached replies, failures, abandoned or stale
preparations do not. The private session completion message checks the captured
memory lifecycle generation and latch, so a cancelled or closed owner cannot
start work from a late notification. Cached preparation never notifies, avoiding
a no-progress rearm loop.

Cancellation raises the host latch before teardown; the retiring worker still
owns its slot until its exact monitor terminates. The graph's transaction guard
checks that latch and actor liveness with its other stale-result checks. Closing
waits briefly for native provider accounting, terminates any remaining worker,
then places a no-op store fence before acknowledgment. Previously queued
closures cannot commit after that acknowledgment, even when their callers died.
A transaction already past its guard can finish only before the fence. Unload
refuses a live memory worker. Normal actor/load recovery rebuilds pending work
from durable source and the saved graph; jobs have no persistent table.

## registry host lookup

`daemon/registry.host` owns the five-second runtime-host lookup. Callers retain
`Result(Runtime, String)` and map failures at the HTTP boundary. Reuse this
function rather than sending `Host` with a local copy of its timeout. Page
contributors construct `page.Row` directly; forwarding constructors add no policy.

## closure registry tables

`daemon/albedo_registry.erl` creates closure-registry ETS tables lazily. A
registering caller monitors the creator and waits for a tagged readiness
acknowledgment or explicit startup failure before inserting. The winning owner
outlives the callers; concurrent losing creators acknowledge the existing
table and exit. Keep this lifetime independent of daemon boot so embedded
runtimes work too. Never replace readiness with a sleep or bounded polling.
