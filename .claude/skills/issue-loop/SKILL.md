---
name: issue-loop
description: Fan Claude Code out over open GitHub issues, one background agent per issue, taking only straightforward bugs and crashes and carrying each to a merged PR. Use when asked to work through the issue backlog in bulk, batch-fix issues, or run agents on many issues at once.
---

# Issue loop

Runs three phases over the open issue list. Every phase is resumable and keeps
its state in the main checkout, so an interrupted run continues rather than
restarts, and deleting a worktree loses nothing.

```
triage  ->  [human gate]  ->  fix  ->  babysit
read-only     you approve     1 agent    poll PRs, wake
~10 at once   the worklist    per issue  an agent when red
```

## Running it

```bash
.claude/skills/issue-loop/scripts/run.sh              # the whole loop
.claude/skills/issue-loop/scripts/run.sh 706 707 708  # only these issues
.claude/skills/issue-loop/scripts/run.sh --yolo       # no human gate
.claude/skills/issue-loop/scripts/status.sh           # where everything stands
.claude/skills/issue-loop/scripts/stop-all.sh         # kill switch
```

Phases can also be run on their own: `triage.sh`, `fix.sh`, `harvest.sh`,
`babysit.sh`. `babysit.sh` is the one worth re-running later on its own, since
PRs keep moving after the loop exits.

`run.sh` blocks on a `read` prompt at the human gate, so run it in a terminal
the user can see, not as a background job. If you are driving this from a Claude
session, run the phases separately and present the triage table yourself instead
of using `run.sh`.

## What each phase does

**Triage** fetches open issues labelled `bug` or `crash` and gives each one a
read-only agent (`--restricted --tools Read,Grep,Glob`, so it has no Bash and no
Edit and structurally cannot change anything). Each returns a schema-validated
verdict: take or skip, a confidence, a located root cause, the files a fix would
touch, and a test plan.

An issue is auto-approved only if **all** of these hold:

| gate | default | override |
| --- | --- | --- |
| verdict is `take` | | |
| confidence | `>= 0.7` | `ISSUE_LOOP_MIN_CONFIDENCE` |
| risk | `low` | |
| files to change | `<= 3` | `ISSUE_LOOP_MAX_FILES` |
| labelled `bug` or `crash` | | |

Everything else lands in the table as `skipped` with a one-line reason. That is
the design: a wrong `skip` costs a human one line of reading, a wrong `take`
costs them a bad PR review.

**Fix** gives each approved issue its own worktree and background agent via
`claude --bg -w issue-<N>`, with a pre-generated `--session-id` so phase 3 can
resume that exact session later. The agent gets the issue, the triage findings,
and `prompts/guardrails.md` as an appended system prompt. It writes a failing
regression test first, fixes, runs only the touched tests, commits through
`devenv shell --`, and opens a PR ready for review. If it cannot write a failing
test, or the fix exceeds five files, it bails out and commits nothing.

`harvest.sh` waits for the agents. An agent that goes idle without writing a
result file is marked `needs_human` rather than waited on forever.

**Babysit** polls `gh pr checks` itself, which costs no tokens, and only wakes
an agent when CI goes red or someone comments. It wakes it with
`claude --bg --resume <uuid>`, so the agent still has the whole change in
context. Three rounds, then `needs_human`.

## Tuning

| variable | default | notes |
| --- | --- | --- |
| `ISSUE_LOOP_FIX_CONCURRENCY` | `4` | a fresh worktree pays a full Elixir recompile plus a Rust NIF build before its first test |
| `ISSUE_LOOP_TRIAGE_CONCURRENCY` | `10` | read-only and cheap, can go higher |
| `ISSUE_LOOP_MODEL` | `sonnet` | do not put Opus on fan-out |
| `ISSUE_LOOP_FIX_BUDGET` | `8` | dollars per fix agent |
| `ISSUE_LOOP_MAX_ROUNDS` | `3` | babysit rounds before giving up |
| `ISSUE_LOOP_REPO` | current repo | the local remote may be a fork |

## When something goes wrong

`status.sh` prints every issue's phase, agent id, PR and note. From there:

- `claude attach <agent>` drops you into a stuck agent's session interactively.
- `claude logs <agent>` tails its output without attaching.
- `$STATE_DIR/logs/` holds every rendered prompt and launch log.
- `stop-all.sh` stops every agent but keeps the conversations; `--rm` also
  deletes the sessions and their worktrees.

State lives in `.claude/issue-loop/` in the main checkout. Delete an issue's
JSON file to make the loop forget it entirely.

## Phases and their meanings

| phase | meaning |
| --- | --- |
| `new` | fetched, not yet triaged |
| `approved` | cleared the gate, waiting for a fix agent |
| `skipped` | triage said no, or the agent bailed out |
| `fixing` | an agent is working in its worktree |
| `pr_open` | PR is open, auto-merge enabled |
| `babysitting` | an agent is handling CI or review feedback |
| `merged` | done |
| `needs_human` | stuck; read the note |
| `failed` | the agent reported an error |
