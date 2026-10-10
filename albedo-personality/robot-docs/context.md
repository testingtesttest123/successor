# Context inspector

`/context` opens a read-only view of the most recently prepared model request for the current session. It does not prepare history, compact the transcript, invoke a tool, or contact the provider. Before the first provider request, and after a model, workspace, or extension reload changes request composition, the inspector remains explicitly pending until the next request is prepared.

The daemon records the same `Request` value passed to the provider on every model/tool-loop iteration. Recording occurs after extension context and any selected compaction strategy have prepared history, immediately before the provider call. A refresh therefore observes the last actual request; it does not predict the next one.

## Request composition

Sections appear in provider request order:

1. system instructions
2. named immutable dynamic instruction sections, after the static prefix
3. named request-only data sections, before prepared conversation history
4. prepared conversation history
5. enabled tool schemas

Each section names its source and reports exact item and byte counts for its underlying prepared request value. Byte counts measure UTF-8 request content or the exact encoded provider tool schema, not displayed terminal width. The compaction observation keeps its local `estimated_input_tokens` and method. Once the provider completes that prepared request, `/context` also reports `provider_input_tokens` and, when available, `provider_cached_input_tokens`; the inspector displays the measured input instead of the estimate. Cached tokens are a subset of the reported input, not an amount to add. A provider that omits usage leaves the estimate as the fallback, and a new request starts without the preceding request's measurement. The configured context-window limit is shown only when it is known.

The summary endpoint returns only bounded previews. Full inspectable text is available in bounded pages. Dynamic instruction/data
sections use at most 8 KiB of rendered UTF-8 text, including their revision
labels, with whole codepoints and exact reconstruction. Legacy history and tools
keep their 8,000-scalar / 32,000-byte bound. Counts and reads use identical page
boundaries; bounded previews retain their existing 180-scalar limit. Image base64 bodies and opaque provider replay bodies are never copied into inspector pages; the page names each omission while preserving its position and available image metadata. Provider credentials are not part of the recorded request.

## Local API

Authenticated local clients use GET requests only:

- `GET /sessions/{session_id}/context?view=summary` returns pending state or request metadata and ordered section summaries.
- `GET /sessions/{session_id}/context?view=section&snapshot_id={snapshot_id}&section_id={section_id}&page={page}` returns one bounded, zero-based content page.

The session actor owns the immutable prepared snapshot and returns it to the caller. Summary and page rendering run in the calling process, so rendering does not occupy the session actor. Section reads pin the observed snapshot ID; replacement returns `410 context_changed`.

The `context: 1` server capability indicates support. Invalid section or page identifiers return an error without changing session state.

The skills and instructions management catalog at `GET /sessions/{session_id}/catalog` is a fresh discovery view, separate from this prepared request snapshot. A candidate can appear there before a session reload makes it available at runtime; reloads can also update live commands while the cached system prompt remains pinned until compaction.

## Immutable request context

The captured preparation metadata is carried into the existing snapshot; the
inspector never invokes request-context callbacks or queries the personality
ledger. `request_context` lists the exact contribution snapshot IDs, instruction
and data names, mandatory classification, rendered-size estimates, diagnostics,
and candidate/selected/excluded counts. Personality snapshot IDs explicitly
include persona ID, identity revision, aggregate revision and binding revision;
the rendered identity section includes those same named JSON fields. A later
edit cannot change an earlier inspector snapshot. It reaches the next ordinary,
steering, tool-continuation or restart preparation without reloading Python.

Static instruction and dynamic suffix sections preserve exact byte boundaries,
including the two-newline dynamic separators. Separate request-only data is
excluded from the conversation section and never saved as history. Estimates
cover the actual final outgoing instructions, data, history and tool schemas,
including no-strategy requests and a static pin released during compaction.
A final known-window guard checks the complete actual estimate, including all
selected history and request-only data, after a current static prefix replaces
a released pin. It fails before ordinary dispatch, forced-compaction inspection
recording or read-only rebuild returns, and reports the complete estimate and
known capacity. It never recaptures personality to repair an oversized result. A missing model window remains unknown; contribution diagnostics disclose the
local estimate's uncertainty. Provider measurements remain authoritative when
available. Forced compaction records its final composed inspection snapshot;
read-only inspection itself never compacts or sends provider work.

The callback budget and history selection share one resolved strategy settings
snapshot. Rolling/LCM explicit contextWindowTokens overrides catalogs;
snapcompact retains its existing catalog-first visual policy and resolved rolling
text fallback. The captured known capacity on `compaction.Prepared` remains
separate from a strategy's temporary estimated window for forced unknown-model
compaction. Such estimates never become a known final request admission limit.

## Native summarizer inspection

An already prepared snapshot includes `summary_policy` metadata for each request
contribution and up to 32 captured native summary-attempt entries. Each entry names a
`summary-N` section, records its output cap and instruction/evidence byte counts,
and reconstructs the exact captured instruction head and bounded trusted
source envelope through UTF-8-safe section pages of at most 8 KiB. Both original
and shrink attempts are shown. `summary_calls_omitted` reports additional calls;
the inspector never implies complete coverage when collection was bounded.
These are read-only observations from preparation, not later ledger rereads or
claims that historical LCM nodes were generated under the current policy.

A generic preparation observer retains the bounded capture before each native
summarizer invocation, independently of eventual provider, strategy or final
ordinary-request admission failure. Both ordinary and forced runs retain these
summary-only snapshots on failure; successful ordinary preparation replaces
that provisional view with its actual final request. The summary-only source
explicitly says the ordinary request was not admitted, and each call's
`status="attempted"` is not proof of network transmission or provider completion.
Durable provider-attempt records remain the completion/error authority. An
unrenderable envelope refuses before invocation and creates no attempted-call
observation. Inspection never rereads identity or performs provider work.
