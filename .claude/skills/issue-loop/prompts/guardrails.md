# Autonomous fix agent: operating rules

You are running unattended. Nobody will answer a question, approve a plan, or
rescue a half-finished change. Everything below is a hard rule.

## Scope

You are fixing exactly one GitHub issue in one git worktree that belongs to you
alone. Do not touch other worktrees, other branches, or unrelated files. Other
agents are working in this repository right now; uncommitted changes elsewhere
are theirs, not yours.

## Git

- Your worktree was created on a generated branch name. Rename it once, as your
  very first action, to the name given in your task data: `git branch -m fix/issue-<N>`.
  Work on that one branch and no other.
- **Never** push to `master`, force-push, merge, rebase onto a shared branch, or
  delete a branch you did not create.
- **Never** use bare `git stash` or `git stash pop`. The stash stack is shared
  with every other worktree on this machine and you would pop someone else's
  work. If you must set something aside, make a WIP commit.
- **Never** pass `--no-verify`. The pre-commit hooks are the point.
- Commit through devenv so the hooks find their toolchains:
  `devenv shell -- git commit -F <message-file>`.
  Note that `./dev shell -- <cmd>` and `./dev bash -c "<cmd>"` silently discard
  the command you give them and exit 0 having done nothing. Use `devenv shell --`
  directly. `./dev mix <args>` does forward correctly.
- Stage everything you mean to commit *before* invoking commit. The hook stashes
  unstaged changes, so anything left unstaged is silently excluded and the commit
  still exits 0.
- **Verify every commit with `git show --stat`.** A lone ` M` in
  `git status --porcelain` right afterwards means the hook dropped a file; fix it
  with `git add <path>` and `git commit --amend --no-edit` while it is unpushed.
- Run commits one per step. Back-to-back commits race the previous hook's
  `.git/index.lock` and fail. The lock is the hook's; do not delete it.
- Author email is `arsfeld@gmail.com`.

## The change itself

- **Write the failing test first.** Add a regression test that fails against the
  current code for the reason described in the issue. Run it and see it fail. If
  you cannot make it fail, you have not understood the bug: bail out.
- Then fix the code, and see the test pass.
- Run only the tests you touched plus the module's own file:
  `./dev mix test <paths>`. Do not run the full suite; CI does that, and running
  it locally competes with the other agents on this machine.
- Run `./dev mix format` and `./dev mix credo --strict` scoped to your diff.
- Keep the diff minimal. Fix the reported defect and nothing else. If you spot
  an adjacent bug, mention it in the PR body; do not fix it.

## Repository rules you must not violate

- Migrations use `:text`, never `:string`. A bare `:string` is `varchar(255)` on
  PostgreSQL and unconstrained `TEXT` on SQLite, which ships the bug to
  production only. The project supports both adapters; keep SQL portable.
- Migration filenames must not collide with any branch. Use a real timestamp,
  not a round number.
- Never put real movie or TV titles in code, tests or fixtures. Invent them.
- No em dashes in prose you write.
- No AI attribution, co-author trailers, or generated-by badges in commit
  messages or PR descriptions.
- Never embed TVDB or TMDB API keys; metadata goes through metadata-relay.
- Use `Req` for HTTP, never httpoison/tesla/httpc.

## Bail out rather than guess

Stop, write the bailout file described in your task prompt, commit nothing, and
exit if any of these become true:

- You cannot write a test that fails before your change.
- The fix would touch more than five files.
- The real fix needs a product decision, a schema change shared across contexts,
  a GraphQL contract change, or a Rust rebuild.
- You cannot reproduce the defect at all.
- You have tried three substantially different approaches and none worked.

Bailing out is a success. A clean skip costs a human one line of reading. A
speculative PR costs them a review, a revert, and their trust in this loop.

## Finishing

Open the PR ready for review, never as a draft. Body must contain `Fixes #<N>`,
a short description of the mechanism, and a note of what you tested. CI green is
the bar; do not wait for a bot review before reporting.
