---
name: fix-bug
description: Use when asked to pick up an open bug issue in getmydia/mydia and ship it end to end, to fix the oldest unclaimed bug, or to take a specific bug issue number through to a merged PR.
---

# Fix a bug end to end

Takes one open bug issue authored by the maintainer, fixes it, opens a PR,
resolves Copilot feedback, and merges once CI is green. One invocation handles
exactly one bug. Do not start a second one.

**Core principle:** master is unprotected and requires no review, so nothing
stops a bad merge except this skill's own gates. Never weaken a gate to make a
merge possible.

## Invocation

- `/fix-bug` takes the oldest eligible issue.
- `/fix-bug 286` forces that issue number, skipping selection only.

## Halt conditions

Stop and report **without merging** when any of these hold:

- The same problem survives 3 fix attempts.
- CI is still red after the bounded re-runs in Phase 8.
- The triage gate in Phase 3 routed the run to the draft path.
- The work needs credentials or infra access you do not have.

Never resolve a halt by editing CI workflows, adding skips to tests, or
changing branch protection.

## Phase 1: Select

```bash
gh issue list --repo getmydia/mydia --author @me --label bug --state open \
  --limit 100 --json number,title,body --jq 'sort_by(.number)'
```

Walk the list ascending and take the first issue that is **not already
claimed**. An issue is claimed if either check finds something:

```bash
# A PR already linked to it
gh api graphql -f query='{repository(owner:"getmydia",name:"mydia"){issue(number:NNN){
  closedByPullRequestsReferences(first:10,includeClosedPrs:true){nodes{number state}}}}}' \
  --jq '.data.repository.issue.closedByPullRequestsReferences.nodes'

# A branch already staked out for it
git ls-remote --heads origin "refs/heads/fix/NNN-*"
```

If nothing is eligible, say so and stop.

## Phase 2: Isolate

Use `EnterWorktree` on branch `fix/<N>-<slug>` (matches existing repo practice,
e.g. `fix/189-media-import-log-level`). Never edit the shared checkout, never
commit to master, never force-push.

## Phase 3: Triage gate

Before writing code, confirm all four hold:

1. Root cause is locatable in this repository's code.
2. The fix stops short of a cross-cutting refactor.
3. No product decision or schema-design call is required.
4. The result is verifiable with the existing test suite.

If any fails, take the **draft path**: commit your analysis plus any partial
fix, open a draft PR naming the specific blocker, stop the run. Do not merge and
do not silently move to a different issue.

## Phase 4: Diagnose and fix

**REQUIRED SUB-SKILL:** Use superpowers:systematic-debugging for root cause.
**REQUIRED SUB-SKILL:** Use superpowers:test-driven-development for the change,
so a failing test lands before the fix.

Repo constraints: batch `./dev` calls (each costs ~2min of shell startup), no
dual SQLite/Postgres code paths, migrations must handle both adapters, and read
the **last line** of build output for the error count.

## Phase 5: Verify locally

```bash
./dev mix precommit   # read the final line for the error count
```

`./dev` intercepts this and runs `run_precommit()` (`./dev:169`), a
hand-maintained mirror of the `precommit` alias in `mix.exs:276` carrying a
"KEEP IN SYNC" comment. If a check looks missing, compare the two before
trusting a green result.

## Phase 6: Commit and PR

Conventional message (`fix(scope): ...`). No AI or model attribution anywhere in
the commit or PR. Author email `arsfeld@gmail.com`.

The prek pre-commit hook stashes unstaged changes. Stage everything first,
commit one at a time, then verify with `git show --stat` because the hook can
drop unstaged edits while still exiting 0.

Open the PR with `Fixes #<N>` in the body.

## Phase 7: Copilot review

`copilot-pull-request-reviewer` reviews automatically, leaving a review body
plus 1-2 inline comments. Poll for it, with a timeout so a missing review cannot
hang the run.

```bash
gh api repos/getmydia/mydia/pulls/NNN/reviews \
  --jq '.[] | select(.user.login|test("[Cc]opilot")) | {state, body}'

gh api graphql -f query='{repository(owner:"getmydia",name:"mydia"){pullRequest(number:NNN){
  reviewThreads(first:20){nodes{id isResolved comments(first:1){nodes{author{login} path body}}}}}}}'
```

**REQUIRED SUB-SKILL:** Use superpowers:receiving-code-review. Evaluate each
comment on merit. Implement the ones that are right; reply on the thread with
your reasoning when declining. Every thread gets a response and is resolved.
Copilot being confident is not evidence it is correct.

## Phase 8: CI gate

```bash
gh pr checks NNN --repo getmydia/mydia --watch --interval 30
```

Exit codes: `0` all passed, `8` pending, `1` something failed.

**Late-registration guard (do not skip).** Checks register in waves. A PR mid-run
showed 10 checks while the same repo's completed PRs show 16, with
`Test / NixOS Module (SQLite)` and `(PostgreSQL)` absent from the early read.
After `--watch` returns 0, wait, re-read, and compare the check count. Only
treat the PR as green once the count is **stable across two consecutive reads**.
A single green read is not green.

On failure, get the log and classify it:

```bash
gh pr checks NNN --repo getmydia/mydia --json name,state,link --jq '.[] | select(.state!="SUCCESS")'
gh run view <runId> --repo getmydia/mydia --log-failed
```

| Known flake signature | Job |
|---|---|
| `Database busy` in `ClientHealthTest` | Test (SQLite) |
| `GenServer.stop` no process in `SingleFlightTest` | Test |
| crates.io `403` during Nix cargo-vendor | Build / Packages |

Matches a signature: `gh run rerun <runId> --repo getmydia/mydia --failed`, at
most **2 attempts per job**. Anything else is a real regression: fix it in code,
push, and re-enter this phase.

## Phase 9: Merge

Preconditions: check count stable and green, every Copilot thread addressed, no
halt condition outstanding.

```bash
gh pr merge NNN --repo getmydia/mydia --merge
```

Merge commit is the only enabled method (squash and rebase are both disabled).
The branch auto-deletes.

## Red flags

Any of these means stop, not proceed:

- "The only failing check is a known flake, I'll just merge." Re-run it or halt.
- "Checks look green" after one read. Confirm count stability first.
- "Copilot's comment is minor, I'll skip replying." Every thread gets a reply.
- "I'll disable that test to get CI green." Never.
- "The triage gate is borderline, I'll push through." Borderline means draft path.

## Common mistakes

- Reading `gh pr checks` once and merging before NixOS checks register.
- Using `gh pr merge --auto`: with no required checks configured on this repo it
  merges immediately rather than waiting for CI.
- Forgetting `--repo getmydia/mydia`, which can target a fork if origin differs.
- Committing without staging everything, so prek silently drops edits.
