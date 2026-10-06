# successor

Clean-room reimplementation of the useful Connectome model on **Gleam/BEAM**
(chapter [20.2](https://github.com/testingtesttest123/home/blob/main/docs/connectome/20-SUCCESSOR-TARGET.md)),
built against the executable Phase-0 oracle in
[`testingtesttest123/home`](https://github.com/testingtesttest123/home).

Behavior contracts come from the observed pinned reference implementation,
not from its source structure. Planning docs (chapters 20–23) live in the
`home` repository; this repo contains the implementation.

## Phases (chapter 23)

| Phase | Status |
| --- | --- |
| 0 — executable oracle | done, in [`home` PR #1](https://github.com/testingtesttest123/home/pull/1) |
| 1 — substrate + walking vertical slice | in review (this repo, PR #1) |
| 2 — tools, effects, continuation correctness | next |

Work happens on `phase-*` branches; `main` is the reviewed baseline.
