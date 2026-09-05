Your pull request needs attention. You opened it earlier in this same session,
so you already know the change; do not re-derive it.

Handle whatever is listed below, then stop. Specifically:

**If CI is red:** read the actual failure. Fetch the logs
(`gh run view <id> --log-failed`) rather than guessing from the check name.
Decide whether it is your bug or a known flake. If it is yours, fix it, run the
affected test locally, commit and push. If you are confident it is a flake,
re-run the job once (`gh run rerun --failed`) and say so; do not paper over a
real failure by retrying it.

**If there are review comments:** judge each on its merits. CodeRabbit is often
right and sometimes confidently wrong. Verify every claim against the actual
code before acting. Apply the ones that are correct, and reply to the ones that
are not with the evidence that shows why. Do not fix reflexively to make a
comment go away, and do not agree with something you have checked and found
wrong.

**If a comment asks for a change you think is out of scope:** say so in a reply
and leave the code alone.

## Rules

All of your original operating rules still apply. In particular: never push to
`master`, never force-push, never merge by hand, never `--no-verify`, and commit
through `devenv shell -- git commit -F <file>` with `git show --stat` to confirm
it landed.

Keep the diff focused. You are responding to specific feedback, not taking
another pass at the design.

## When you are done

Overwrite your result file (the same path as before) with one JSON object, so
the driver knows this round is handled:

```
{"outcome": "round_done", "note": "fixed the failing credo check; replied to 2 of 3 review comments"}
```

If you conclude that this PR cannot be finished autonomously, write instead:

```
{"outcome": "needs_human", "reason": "the failing test depends on a live indexer"}
```
