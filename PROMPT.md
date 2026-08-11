# Task: Remove the Trakt.tv integration

Execute the implementation plan at `docs/superpowers/plans/2026-08-11-trakt-deprecation.md`.

The design rationale is at `docs/superpowers/specs/2026-08-11-trakt-deprecation-design.md`. Read both before starting.

## Scope

Do **Tasks 2 through 6** in order, plus **Task 7 Steps 1 through 6**.

**Skip Task 1.** The worktree already exists; you are in it, on branch `remove-trakt` off `origin/master`.

**Stop after Task 7 Step 6.** Do not run Task 7 Steps 7, 8, or 9. Specifically:

- Do NOT `git push`
- Do NOT open a pull request
- Do NOT close PR #401

Those are outward-facing and are handled separately after review. Commit locally as the plan directs, then stop and report.

## Rules

- Work only inside this worktree. Never `cd` to the main checkout.
- Do the tasks in order. Each one ends with a commit, as the plan specifies.
- Run Mydia commands through `./dev` (for example `./dev mix test`). Each `./dev` call costs about two minutes of startup, so batch commands into one invocation where the plan allows.
- Run metadata-relay commands with plain `mix` from inside `metadata-relay/`.
- Commit with the email `arsfeld@gmail.com`.
- Never add model, AI, or tool attribution to commit messages.
- Never use bare `git stash` or `git stash pop`; the stash stack is shared with other worktrees.
- `credo --strict` is a hard gate. Unused private functions and unused `require` statements will fail it, so remove them as the plan directs.
- Migrations must work on both SQLite and PostgreSQL with no adapter branch.

## Verification before you stop

All of these must pass:

1. `./dev mix precommit` (compile, deps.unlock --unused, format --check-formatted, credo --strict, test)
2. From `metadata-relay/`: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`
3. `grep -rn -i trakt lib/ test/ config/ metadata-relay/lib/ metadata-relay/config/ infra/` returns only the new migration file `priv/repo/migrations/20260811000000_remove_trakt_oban_jobs.exs`, whose module name and moduledoc legitimately mention Trakt.

If a step in the plan refers to something that does not exist in this branch, that is expected: several items exist only on the separate PR #401 branch. The plan marks those skip-if-absent. Skip them and note it.

## Report when done

State which tasks completed, the commit SHAs, the results of the three verification commands above, and anything you skipped or that did not go to plan.
