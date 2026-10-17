# Successor daemon composition

This entrypoint appends the external `personality` declaration to stock Albedo and preserves every stock default. Personality remains opt-in. Storage CLI arguments retain the stock dispatch path.

The app depends directly on the sibling development Albedo checkout and `packages/successor_extension`. Run `gleam check`, `gleam format --check src test`, and `gleam test` here. Its composition test verifies declaration order and unchanged default selection.

Actual-daemon acceptance lives in `compat/live_identity`. Initializing and binding the single main identity requires the authenticated setup API; this app does not create identities or bind sessions at startup.
