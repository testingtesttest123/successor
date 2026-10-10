# Shared conformance test bridge

The portable scenario corpus and comparator live in
[Home](https://github.com/testingtesttest123/home/tree/phase-0-conformance/conformance).
Do not copy scenarios or synthesize reference baselines in this repository.
The accepted scope is `provider/mock-text-turn` and
`storage/restart-after-committed-turn`; other scenarios remain unsupported.

## Wire contract

Build/run the development-only bridge with `gleam run -m conformance_host`.
Send one JSON object per stdin line. Replies begin with `@@SUCCESSOR@@` and
contain `{op, ok: true, ...}`. Other stdout/stderr is diagnostic output, never
an observation. Malformed/unknown requests or operation failures terminate
nonzero; no success envelope is fabricated.

- `start`: `dataDir`, unmodified recipe JSON in `recipe`, optional `sessionId`.
  Loads the compatibility recipe, starts the real supervision tree, creates a
  session or opens the exact supplied durable ID. Returns `snapshot` and the
  real compatibility `recipeWarnings`.
- `text`: `content`. Submits through the public session API and waits for
  correlated `TurnStarted` and `TurnCompleted`. Returns activation, events,
  completed status and a durable snapshot. Failure/timeouts terminate nonzero.
- `snapshot`, `describe`, `readReceipts`: return the real durable `snapshot`.
- `command`: only `line: "/history"` is supported and returns a durable
  snapshot. This is a test adapter mapping, not legacy display-prose parity.
- `stop`: performs ordered host termination, returns `exitCode: 0`, then ends
  the BEAM process. The driver must independently check the actual OS exit.
- `inspect`: first/only command in another fresh process, with `dataDir` and
  `sessionId`. Opens the existing database using SQLite `mode=ro`, returns a
  snapshot, and exits without starting a host or provider. A missing database
  fails; it is never initialized or migrated.

All commands reject unknown keys. `start` cannot replace a live host.
`inspect` cannot run inside a live host process. An EOF stops a live host.
The driver must use a fresh process for the next scenario `start` after `stop`.

Snapshots preserve actual deployment/session/branch/record/receipt IDs, full
catalog and branch relationships, branch head, ordered records and raw payloads,
receipt activation/provider/model/status/usage, and the actual OS process ID.
Persisted record/session creation and provider-attempt start/finish timestamps
are included raw, so restart checks detect rewritten timestamps as well.
They do not reconstruct hypothetical provider requests from a transcript.
Receipt request/response capture, production wire compatibility, and the other
eleven Home scenarios are outside this bridge's scope.

## Verification

```sh
gleam test
python3 -m unittest discover -s conformance -p 'test_*.py' -v
gleam format --check src test
```

These run in Successor CI and check bridge strictness, ordered shutdown,
read-only inspection, missing-store refusal and unchanged durable snapshots.
The **shared acceptance gate runs in Home**, with this exact Successor revision
and the pinned reference host. Home reports fresh execution separately from
explicit checked-in-baseline mode. Passing baseline-only acceptance never
establishes that the reference was executed in that environment.
