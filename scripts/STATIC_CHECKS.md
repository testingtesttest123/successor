# Current integration static checks

Run from this Successor checkout, with Python 3.11, Gleam 1.19.0, OTP 29,
rebar3 3.25.1 and Go 1.26.8 on PATH. Install Ruff 0.16.10 and ty 0.0.85 in
your tool environment, then run:

```sh
python3 scripts/prepare_static.py
python3 scripts/static_checks.py
```

Preparation creates the sibling `../albedo` only when it is absent, checks out
`upstream/albedo-current.pin.json`, and applies its cumulative patch. An existing
host must already match; preparation refuses discrepancies rather than resetting
local work. It also builds glinter in `.cache/static/glinter` from the exact
revision in the verified host's `flake.lock`. Initial dependency downloads and
compilation need network access; subsequent checks reuse local caches. Normal Git,
Hex and Go dependency verification remains enabled. An unavailable example-image
LFS object in a Go dependency can be skipped with process-local
`GIT_LFS_SKIP_SMUDGE=1`; Go module checksum verification remains active.

The static command covers:

- Current host HEAD, base tree, patch SHA-256 and reconstructed patched tree;
  every expected file's bytes, executable bit or symlink target; extra source
  modules; project and lockfile local dependencies; dependency direction from
  daemon to extension to host, with the standalone root kept independent.
- Fourteen verifier tests, including mismatched patch, file bytes/modes, extra
  source, stale dependency paths and forbidden reverse imports.
- Gleam format and compiler checks for the standalone root, extension package,
  daemon app, P0/P1/P3a fixture apps, and the actual sibling host. This includes
  their source and tests. No frozen snapshot substitutes for the sibling host.
- Focused Ruff correctness rules (`E4`, `E7`, `E9`, `F`), formatting and ty for
  active Successor Python in `priv/python`, `test`, `conformance`, `scripts`,
  `compat`, `packages` and `apps`. Generated build directories are excluded.
  Narrow inline exceptions describe deliberate invalid-input/fault-injection
  tests and imports after standalone fixture path setup; there are no blanket
  error-code exclusions.
- The host's existing Ruff/ty rules for `priv/python`, `test` and Python
  maintenance scripts, plus its strict
  glinter policy. Ten missing test return annotations in our maintained patch
  were corrected without relaxing that policy.
- Host CLI generated API consistency (`go run . -check` from `cli/tools/apigen`)
  and `go vet` for both the CLI and its nested generator module.

The new `static` workflow runs this same command for branch pushes and pull
requests with read-only repository permission and no persisted checkout
credentials. It is separate from the existing runtime-test workflow. Workflow
execution is not verified until these local changes are published and CI runs.

This command does not run daemons, providers, browser suites, Rust tests, Nix
formatters, or the full host `test.sh`. Those remain separate qualification.
In this workspace Nix is unavailable and Chromium's system sandbox helper is
misowned; neither is required by this static job. The archived
`albedo-personality`, old `upstream/albedo.pin.json`, historical six patches and
previous verification inventories remain historical evidence, not current gate
inputs. `verify_extension_slice1.py` is a compatibility entrypoint for the new
verifier, no longer a freeze of obsolete slice assumptions.
