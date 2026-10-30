# Design docs

Specs, implementation plans and the notes behind them. Committed with the
feature they describe, never published: mkdocs reads only `docs/`.

| Folder | Holds | Name |
| --- | --- | --- |
| `specs/` | what we decided to build and why | `YYYY-MM-DD-<topic>-design.md` |
| `plans/` | step-by-step implementation plans | `YYYY-MM-DD-<topic>.md` |
| `brainstorms/` | requirements and early exploration | `YYYY-MM-DD-<topic>-requirements.md` |
| `solutions/` | write-ups of problems solved, by area | free-form |
| `research/` | background investigation | free-form |

A doc records the decision at the time it was written. When the code moves
on, the code and its tests win; update or delete the doc rather than citing
a stale one. Code comments may cite a doc here by path.

Never put these under `docs/`: a pre-commit hook rejects it, because anything
there is published to docs.mydia.dev.
