Fix the GitHub issue described below, then open a pull request.

A triage pass has already located the defect. Its findings are attached. Treat
them as a strong starting point, not as gospel: verify the root cause against
the code before you act on it. If triage was wrong, say so in your bailout or
your PR body rather than fixing the wrong thing.

## Steps

1. Read the issue and the triage findings.
2. Read the code around the named root cause, plus the README nearest to it
   (`lib/mydia/media/README.md`, `test/README.md`, `priv/repo/README.md` and
   siblings are listed in the table at the end of `CLAUDE.md`).
3. Write a regression test that fails for the reason in the issue. Run it.
   Watch it fail. If it passes, you have the wrong cause: go back to step 2.
4. Fix the code. Run the test again and watch it pass.
5. Run `./dev mix test` on the files you touched, then `./dev mix format` and
   `./dev mix credo --strict`.
6. Stage everything, commit through `devenv shell -- git commit -F <file>`, and
   confirm with `git show --stat`.
7. Push the branch and open the PR with `gh pr create` (never `--draft`).
8. Write the result file described below.

## Result file

The driver reads this file to learn what happened. Write it exactly once, as
your last action, whatever the outcome. It is JSON:

```
{"outcome": "pr_opened", "pr": 712, "branch": "fix/issue-708", "note": "one line"}
{"outcome": "bailout", "reason": "could not write a failing test; the crash needs a live Plex server"}
{"outcome": "failed", "reason": "what went wrong"}
```

Write it with a heredoc to the exact path given in your task data below. Create
the parent directory first if it does not exist.

A `bailout` is a legitimate, expected outcome. Choose it whenever the operating
rules tell you to. Do not open a PR you would not defend in review.
