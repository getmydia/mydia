# CI mechanics

How the workflows in this directory actually behave, including the parts that let
breakage sit unnoticed. For the catalogue of known flakes and how to read a red
check, see `ci-flakes.md` next to this file.

This file is deliberately **not** called `README.md`. GitHub picks the repository
landing page from `.github/README.md` before the root `README.md`, so a README
here silently replaces the project's front page with this document. It did, from
46cbdfdb0 until it was noticed. Any new doc in this directory needs a name other
than `README.md`.

## The Nix jobs never run on pull requests

Both jobs in `ci-nix.yml` carry `if: github.event_name != 'pull_request'`:

- `Test / NixOS Module (SQLite)`, running `nix build .#checks.x86_64-linux.nixos-module`
- `Test / NixOS Module (PostgreSQL)`, running `nix build .#checks.x86_64-linux.nixos-module-postgres`

They show as skipping on every PR. The comment in the file says this is
deliberate: they are the slowest and least reliable jobs, and breaking the NixOS
module is rare enough to be worth catching on master. The former
`Build / Packages` job no longer exists, deleted as redundant because these two
build `packages.default` and `packages.postgres` as inputs via
`nix/checks/flake-module.nix`. So a green PR says nothing about whether Nix
builds.

For any `.nix` or `assets/` change, verify locally before merge and then watch
master's push-triggered `CI / Nix` run after. Do not report a nix fix as proven
on PR green.

Local pre-merge verification that actually proves a `fetchNpmDeps` hash, without
a full build:

```
nix run nixpkgs#prefetch-npm-deps -- assets/package-lock.json      # prints the hash
nix build --impure --expr '
  let f = builtins.getFlake (toString /abs/path/to/worktree);
      pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in pkgs.fetchNpmDeps { src = /abs/path/to/worktree/assets; hash = "sha256-..."; }'
```

Use the flake's own pinned nixpkgs for the second step, not whatever `nix run`
resolved, so a `prefetch-npm-deps` version skew cannot give a false pass. Then run
`nix build --dry-run .#default` and grep the resulting `mydia-*.drv` for the
npm-deps store path to confirm the package consumes it.

## npmDeps.hash must move with package-lock.json

`npmDeps.hash` in `nix/packages/flake-module.nix` is a fixed-output derivation
hash and must be bumped in the same commit as any `assets/package-lock.json`
change. A stale value fails as
`error: hash mismatch in fixed-output derivation '...npm-deps.drv'` with
`specified:` and `got:` lines, and the `got:` line is the correct value. Read it
straight out of a failed CI log rather than computing anything.

This has drifted twice unnoticed, because of the push-only rule above. `d1109d65c`
(2026-08-23) changed the lockfile and left the hash, then `f00681d22` (2026-08-26)
changed it again. `CI / Nix` was red on master for 15 consecutive runs across
three days before anyone bumped it, fixed in #584 as `e5fd485f0`.
Lockfile-touching commits are usually chores nobody watches CI for, which is
exactly why this hides.

When triaging a red `CI / Nix`, grep the job log for `hash mismatch` first. It is
a one-line fix and it masks everything downstream, since the build aborts before
the Rust crate vendoring even starts.

## The Elixir and OTP pins each live in one file

`.elixir-version` holds the Elixir minor and `.otp-version` the OTP major, and
nothing else may name either. `beam-version.nix` resolves the pair from one
nixpkgs beam set and throws when the pinned nixpkgs lacks the OTP set or the
Elixir attribute under it. `devenv.nix` imports that resolver and is the
toolchain for both local development and all three Elixir jobs in `ci.yml`,
which run their steps inside `devenv shell`. `nix/packages/flake-module.nix`
imports it too, for the release build and the NixOS module VM tests.

The Dockerfile's builder is digest-pinned and cannot read a file, so
`ci-nix.yml`'s `Check / BEAM Pin` job (`scripts/check-beam-pin.sh`) parses its
`hexpm/elixir` tag instead and asserts three things: the Elixir minor matches
`.elixir-version`, the OTP major matches `.otp-version`, and the builder's
Alpine minor matches the runtime stage's `FROM alpine:`, because the release
carries the builder's ERTS into the runtime image. Patches differ by design:
devenv and the Nix release take whatever their lock resolves, and the
Dockerfile names its own, because only it builds against musl, where OTP 29.1
is the floor (the Dockerfile's builder comment explains why).

This replaced a comment in `devenv.nix` asking three files to be kept in sync
by hand. That comment omitted `nix/packages/flake-module.nix`, which floated
to whatever `beam.packages.erlang_28` defaulted to and drifted onto Elixir
1.18.4 while `devenv.nix`/CI held 1.19.5 and the Dockerfile ran 1.19.x. The
visible symptom was the `Test / NixOS Module (SQLite)` and `(PostgreSQL)`
jobs (see above) going red on master with every other job green, unnoticed
pre-merge because neither runs on pull requests.

The OTP major had the same problem in a different shape: it was written by
hand as a nixpkgs attribute name in `devenv.nix` (twice), the Elixir resolver
and `nix/packages/flake-module.nix`, plus the Dockerfile tag, and nothing
checked that they agreed. Bumping it now means editing `.otp-version` and the
Dockerfile's builder tag and digest.

The Rust pin has the same shape and one more consumer, since the wasip2 plugin
guests' WASI version tracks it. See `plugins/README.md`.

nix and Docker also share the repo `tmp/` (ExUnit's `:tmp_dir`) unless isolated.
`compose.yml` mounts `tmp_dir_cache:/app/tmp` so Docker running as root and nix
running as the local uid do not leave each other root-owned leftovers, which
surfaced as `File.Error: permission denied` during test cleanup.

## A caller granting too few permissions kills the whole run

A job calling a reusable workflow must grant every permission the callee's own job
declares. GitHub validates that subset while building the run graph, before any
`if:` is evaluated, so a caller job that would have been skipped still fails the
whole workflow run with `startup_failure`.

This bit `ci-security.yml`, fixed in PR #590. `scan-fork` granted only
`actions: read` and `contents: read`, while the callee
`google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml` hard-codes
`security-events: write` on its `osv-scan` job. Every run of `CI / Security`
startup-failed for two days, including same-repo PRs where `scan-fork` was
skipped. Declaring the permission anyway is safe on fork PRs, since GitHub caps
the `GITHUB_TOKEN` to read-only there regardless of the `permissions:` block.

Diagnosing `startup_failure` is awkward: it produces no jobs, no logs and no check
runs, so `gh run view`, `gh api .../jobs` and `.../logs` all come back empty or
404, and `actionlint` does not catch it. Use `gh run list --workflow=<id>` to find
the last run that was not a startup_failure, then
`git diff <last-good-commit> <first-bad-commit> -- <workflow-file>` to isolate the
change. Reaching `queued` instead of dying within a second is the signal the graph
validates.

## Dependabot merges through a gate, not GitHub's auto-merge

`dependabot-auto-merge.yml` no longer calls `gh pr merge --auto`. That waited on
**required** checks only, with no flag to widen it, so PR #613 merged 2026-08-29
with seven red advisory checks and broke the master Docker image. Supplementing it
would not have helped either: `--auto` fires the moment the required checks go
green and beats any custom gate.

The workflow now runs `scripts/dependabot-gate.sh`, which reads a PR's whole
`statusCheckRollup` and prints one line:

- `MERGE` -- every context concluded `SUCCESS`, `SKIPPED` or `NEUTRAL`. Merges,
  but only when `mergeStateStatus` is `CLEAN` or `HAS_HOOKS`. `UNSTABLE` means
  "mergeable with non-required checks failing", which is literally the state #613
  merged in, and never merges.
- `WAIT` -- something is still running, or no checks are registered yet. No
  action, no comment.
- `BLOCKED` -- everything concluded and something failed. Upserts one comment
  naming the blocking contexts, rewritten in place rather than appended.

Three details the data forces, each with a test fixture in
`scripts/tests/fixtures/`: a rollup mixes `CheckRun` entries (`name`/`status`/
`conclusion`) with `StatusContext` entries (`context`/`state`, no `status` field
at all -- CodeRabbit posts one of these, and reading only `.status` waits
forever); `SKIPPED` and `NEUTRAL` are normal and must count as passing; and an
empty or null rollup means `WAIT`, never `MERGE`.

### It cannot merge PRs that touch `.github/workflows/`

This is structural, not a bug. `GITHUB_TOKEN` is a GitHub App token, and GitHub
refuses to let an App land workflow-file changes without `workflows` permission:

```text
GraphQL: refusing to allow a GitHub App to create or update workflow
`.github/workflows/<file>.yml` without `workflows` permission (mergePullRequest)
```

In practice that is dependabot's **actions group**. Confirmed 2026-08-31 on #627:
the gate logged `PR #627: MERGE`, the merge failed, and the run continued. Merge
that class by hand.

There is no workflow-level escape hatch: `workflows` is not a valid key in a
`permissions:` block, so this cannot be fixed by widening the job's permissions.
It would take a GitHub App installation token or PAT carrying the repository's
Workflows permission, wired in as a secret in place of `GITHUB_TOKEN`.

That is deliberately not done. It would hand an auto-merging bot a credential
that can land changes to CI configuration itself, which is a materially larger
privilege than merging dependency bumps, and it would sit in a workflow that
merges without human review. Merging that class by hand is the cheaper trade.

### The trigger, and why not `check_suite`

`workflow_run` over the workflows that run on pull requests, including `Dependabot fixup`. `check_suite`
was tried first and reverted. GitHub documents that it "does not trigger workflows
if the check suite was created by GitHub Actions", which reads as though it never
fires here -- but it does, for suites created by *other* apps. That is worse than
not firing: those suites conclude on their own schedule, typically well before CI,
so the gate would evaluate early, log `WAIT`, and never be woken when the last
Actions workflow finished.

Missing a workflow from the list cannot cause a wrong merge -- the gate re-reads
the full rollup rather than trusting the event, so an unlisted workflow still
counts toward the verdict. What it can cause is a stuck PR. If the omitted
workflow is the last to finish, every listed one has already fired, the gate has
already logged `WAIT`, and nothing wakes it again. The PR sits green and open
until someone re-runs a listed workflow. Keep the list complete, and when a
green dependabot PR is not merging, check whether a workflow it runs is absent
from it.

### It is edge-triggered, so a green backlog sits

The gate only evaluates a PR when one of those workflows *completes*. A PR that
was already green before the gate existed has no event to fire for it and stays
open indefinitely. Re-running any one of its workflows is enough to trigger a
verdict. New dependabot PRs are unaffected.

### Every fallible call in the loop is guarded

The gate script call, `gh pr merge`, and the comment API calls all use
`cmd || status=$?`, log to stderr, and continue. Under `set -euo pipefail` an
unguarded failure -- a 409 because someone merged by hand, or the workflow-file
refusal above -- would abort the step and leave every later dependabot PR in that
run unevaluated. Do not remove those guards.

### A failed job is re-run once before BLOCKED

When the verdict is `BLOCKED`, the gate asks `dependabot-gate.sh reruns` for
the Actions runs behind the failing contexts, reads each run's `run_attempt`,
and re-runs the failed jobs of any run still on attempt 1. It logs `RETRY`
instead of commenting, and the re-run's completion wakes the gate again. Only
when every failing run is on attempt 2 or later, or the failure is not from
Actions at all (CodeRabbit, CodeQL, osv-scanner), does the BLOCKED comment
appear. With the App token it says the checks already failed twice; without it
the comment keeps the old advice to re-run by hand.

The re-run goes through a GitHub App token, not `GITHUB_TOKEN`, because the
completion has to fire `workflow_run` and events caused by `GITHUB_TOKEN`
mostly start nothing. The token is minted with `continue-on-error`, so a gate
without the App's secrets still works; it just never retries.

## Dependabot: cadence, groups and the fixup

`.github/dependabot.yml` runs monthly, in five multi-ecosystem groups plus
actions:

| Group | Covers |
|---|---|
| `backend` | mix `/`, npm `/assets` |
| `relay` | mix and npm under `/metadata-relay`, npm `/relay-worker` |
| `player` | pub, the player's Rust crate, both fastlane Gemfiles |
| `rust` | `/server`, `native/*`, `plugins/*` |
| `tooling` | `/site`, `/docs` |
| `actions` | github-actions, alone because the gate cannot merge it (above) |

Majors are ignored everywhere except actions, and every entry has a seven-day
`cooldown`. Both settings apply to version updates only, so security updates
still open immediately, majors included. Take a major deliberately: bump it on
a branch of your own.

Some dependencies are ignored by name because their bumps need work nothing
automates: `fine`, `lazy_html`, `wasmex` and `heroicons` (hand-pinned hashes
in `nix/packages/flake-module.nix`), `tailwindcss` (pinned across npm, config
and nix), and `flutter_rust_bridge` on both sides (needs a codegen run). The
comments in `dependabot.yml` say what each one moves.

### The fixup regenerates derived files

`dependabot-fixup.yml` runs `scripts/regenerate-derived.sh` on every Dependabot
pull request. The script rewrites `deps.nix` from `mix.lock` with `mix2nix`,
refreshes every Cargo.lock listed in `scripts/lib/cargo-lock-dirs.sh`, and
recomputes `npmDeps.hash` with `prefetch-npm-deps`, then runs
`check-generated-freshness.sh`. Run it locally the same way.

If anything changed, the workflow pushes one commit,
`chore(deps): regenerate derived files`, with the App token. A push made with
`GITHUB_TOKEN` would start no CI, so the gate would never see the fixed
commit. The App credentials are Dependabot secrets, the only secrets a
Dependabot-triggered workflow can read, which keeps this on `pull_request`.

After that push Dependabot no longer rebases the pull request. If it goes
stale or conflicts, comment `@dependabot recreate`: Dependabot rebuilds it
from scratch and the fixup runs again on the new commit.

### The GitHub App

One App, installed on this repository only, with repository permissions
**Contents: read and write** (the fixup's push) and **Actions: read and write**
(the gate's re-run), no webhook. Its client ID and private key are stored
twice, as Actions secrets for the gate and as Dependabot secrets for the
fixup:

```
gh secret set DEPENDABOT_APP_CLIENT_ID --repo getmydia/mydia --body <client id>
gh secret set DEPENDABOT_APP_PRIVATE_KEY --repo getmydia/mydia < key.pem
gh secret set DEPENDABOT_APP_CLIENT_ID --repo getmydia/mydia --app dependabot --body <client id>
gh secret set DEPENDABOT_APP_PRIVATE_KEY --repo getmydia/mydia --app dependabot < key.pem
```

Rotating the key means generating a new one on the App's settings page and
re-running the two `PRIVATE_KEY` lines.

## Dependabot: a stale base blocks a green PR forever

The Master ruleset requires `Load lanes (ios)`, `Load lanes (android)`,
`Site build`, `Test`, `Test / PostgreSQL`, `Test / E2E Browser`, `Build / Web`
and `Test / Player` (both since 2026-08-31), and `Test / Player E2E` (since
2026-09-16). Several of those workflows were
originally `paths:`-filtered, and `20f0db5e2` (2026-08-26) removed the filters
precisely so they report on every PR. `ci-player.yml` got the same treatment
differently: its filter moved into a `changes` job, so its jobs always report.

A PR branched from a master older than that commit still carries the
path-filtered workflow files, so those jobs never run and the required contexts
never report. The PR shows every check green and sits at
`mergeStateStatus: BLOCKED` with nothing red to explain it. Seen on #582, which
was all-green and unmergeable for three days.

Diagnose by comparing the required contexts against what actually reported:

```
gh api repos/getmydia/mydia/rulesets/9740184 --jq '.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context'
gh pr view <n> --json statusCheckRollup --jq '[.statusCheckRollup[]|(.name//.context)]|sort|.[]'
```

A context in the first list and absent from the second is the blocker. The fix is
a rebase, not a re-run.

## @dependabot rebase on a group PR usually supersedes it

Dependabot recomputes the group during the rebase. If the member set changed at
all, it closes the PR with "Looks like these dependencies are updatable in another
way, so this is no longer needed" and opens a replacement under a new number.
Confirmed 2026-08-29: #578 (rust, 10 updates) became #612 (12 updates), and #580
(player, 11) became #613 (8). #577 rebased in place because its group was
unchanged.

"Rebase but keep it open" is therefore not something you can promise for a group
PR. Check `gh pr list --author app/dependabot --state open` afterwards rather than
assuming the numbers survived, and never cite the old number in follow-up work.

A coupled upgrade can also land split across two group PRs. After the 2026-08-29
regrouping, the `flutter_rust_bridge` 2.12.0 to 2.13.0 upgrade sat in two: the
Rust crate in #612 (`player/rust/mydia_player_p2p/Cargo.toml`) and the Dart
package in #613 (`player/pubspec.yaml`). `frb_generated.rs` asserts codegen and
runtime versions match and aborts the app at startup when they do not, so merging
either alone reproduces the panic. They have to land together with a codegen
regen. Dependabot's grouping does not know about cross-language version coupling
and will keep splitting this.

Once `dependabot-fixup.yml` has pushed to a pull request, `@dependabot rebase`
is refused, because the branch has commits Dependabot did not make. Use
`@dependabot recreate`.

## Dependabot resolves pubspec.lock with its own Flutter

Dependabot never reads `player/.fvmrc`. Its pub updater installs the newest
stable Flutter release that `environment.sdk` and `environment.flutter` in
`player/pubspec.yaml` allow, and resolves `pubspec.lock` on that. Each Flutter
release pins `meta`, `matcher`, `test_api`, `vector_math` and `intl` to its own
versions through `flutter_test` and its siblings, so a lock resolved on a newer
minor cannot resolve on the pinned SDK.

With no `environment.flutter` range, #613 and #740 were resolved on the next
minor. CI ran plain `flutter pub get`, which quietly re-resolved those packages
down on the `.fvmrc` SDK and passed, so the gate merged both. Every local
`pub get` then wrote the lock back, and it showed as modified in every checkout.
Restoring it did not help: the devenv `mydia:flutter` task reruns `pub get` on
shell entry whenever the lock changes, so the restore was itself the trigger.

Two checks now hold the line:

- `environment.flutter` must read `>=MAJOR.MINOR.0 <MAJOR.NEXT_MINOR.0` for the
  `.fvmrc` minor, enforced by `Check / Flutter Pin`. Pub enforces only the lower
  bound of that range (flutter/flutter#95472), so the upper bound constrains
  Dependabot alone, and only that check notices when a `.fvmrc` bump leaves it
  behind. The floor is `.0` rather than the `.fvmrc` patch because patches of one
  minor pin the same packages.
- Every CI, release and E2E `flutter pub get` passes `--enforce-lockfile`. A lock
  that does not resolve on the pinned SDK fails `Test / Player`, and the gate
  reports `BLOCKED`. The E2E toolbox (`player/Dockerfile.test`) installs the SDK
  from `.fvmrc` like every other build. Until September 2026 it built on
  cirruslabs' floating `stable` image, which stopped following releases.

## Quality gates

PR #186 (merged 2026-06-05) removed dead-code and duplicate-code grandfathering.

Credo is a true hard gate. CI runs `mix credo --strict`, every check is either
enabled and gating at zero or set to `false` with a rationale, and there is no
`exit_status: 0` anywhere, enforced by a CI grep-guard step named "Forbid Credo
grandfathering". The policy is documented in `CONTRIBUTING.md`.
`StructBracketAccess` was retired, since the type checker owns struct-access
safety, and `Refactor.Apply` is `false` because its only sites are intentional
`apply/3` behaviour dispatch in `library_item.ex` that the type checker rejects as
direct calls.

mix_unused is advisory by design and must not be promoted to blocking. A Phoenix
app's export analysis has irreducible false positives: controller actions via
router `apply` dispatch, HEEx function components, behaviour callbacks, and
default-argument arity artifacts, where for instance `count_books/1` is the
opts-arity of a live `count_books/0` and cannot be deleted. Ignores are
rule-shaped, as regexes or predicates, in `mix.exs`'s `unused_ignore/0`, including
a behaviour-callback predicate `MydiaQuality.behaviour_callback?/1`.

Four gotchas around it:

- The mix_unused `:unused` compiler must be prepended (`[:unused | base]`).
  Appending (`base ++ [:unused]`) produces no report in this version. It is gated
  to `Mix.env() in [:dev, :test]` and `UNUSED_CHECK=true`.
- The report runs on master pushes only, not on pull requests. It recompiles all
  765 files a second time and cost 199s of every run, measured 2026-09-03, for
  output nothing is gated on. `ci.yml` gates it on `GITHUB_EVENT_NAME` inside the
  `devenv shell` heredoc rather than with a step-level `if:`, because splitting
  the heredoc evaluates the devenv environment twice and costs more than it
  saves. Run it yourself with
  `UNUSED_CHECK=true ./dev mix compile --force`.
- Build-time helper modules referenced by `mix.exs` must be inlined in `mix.exs`
  rather than kept in a separate root file. The Docker build's
  `mix deps.get --only prod` layer copies only `mix.exs` and `mix.lock`, so a
  sibling `Code.require_file("mix_quality.ex")` fails with `(Code.LoadError) enoent`
  and breaks all image builds.
- The `mix compile --warnings-as-errors` gate runs in CI's test-env compile, so
  test-only warnings such as a duplicate `@doc` in `test/support/` fail CI even
  when a local dev-env compile is clean. Reproduce with
  `MIX_ENV=test mix compile --warnings-as-errors --force`.

### Watching test-suite speed

The regression signal is already free on every run: ExUnit's
`Finished in Xs (Ys async, Zs sync)` line. Sync time is the number that matters
here, because `test/test_helper.exs` pins `max_cases: 1` on SQLite and
`Mydia.DataCase` forces database tests to `async: false`, so the suite is
overwhelmingly serial and a slowdown shows up as sync time climbing. Measured on
master 2026-09-03: `876.4 seconds (59.1s async, 817.3s sync)`.

To find *which* tests are slow, profile on demand rather than in CI:

```bash
devenv shell -- bash -c 'MIX_ENV=test mix test --slowest-modules 20'
```

Do not add `--slowest` or `--slowest-modules` to the CI invocations. Both
automatically set `--trace`, and `--trace` forces `--max-cases 1` and sets the
test timeout to `:infinity` (`mix help test`; ExUnit's `max_cases/1` checks
`opts[:trace]` before any explicit `--max-cases`). On the PostgreSQL job that
silently serializes the whole suite, and on both jobs it means a hung test runs
until the GitHub job timeout instead of failing fast.

## Docker tags

`ci-docker.yml` pushes `:master` and `:master-pg` on every master push, which is
the rolling bleeding-edge tag. `release.yml` pushes `:beta` (and `-pg`) for any
tagged prerelease, so `:beta` is the most recent tagged prerelease rather than
every commit. `:latest` is the stable tagged release. The PostgreSQL suffix is
`-pg`, not `-postgres` (`matrix.tag_suffix`).

In release notes, `:master` is the tag that runs unreleased changes ahead of
tagged versions. Note that "beta" can also legitimately mean the TestFlight open
beta for the iOS player, which is a distinct concept.

## Releases are draft-first

Cutting a release is two steps, documented in the `release.yml` header: create a
draft, then dispatch the workflow. Two things the header does not say.

A draft release has no git tag. Its URL is `releases/tag/untagged-<hash>` and
`git ls-remote --tags origin` shows nothing. `release.yml`'s last step is
`gh release edit "$TAG" --draft=false`, and that is what creates the tag.

`--target` must be a full commit SHA.
`gh release create vX.Y.Z --target "$(git rev-parse origin/master)" --draft`
works, and `release.yml`'s `prepare` job rejects a draft whose target is a branch
("Draft targets 'master', which is a branch, not a commit"). A branch target is
resolved once at build time and again at publish time, so the tag could land on
code that was never built. Pinning to a SHA makes the notes, the images and the
tag describe one commit. If master moves past the pinned commit mid-preparation,
the run refuses until you re-pin or pass `-f accept_drift=true`.

The release workflow is independent of branch CI. `release.yml` runs its own
Docker and player builds, so do not gate the dispatch on master's `CI`,
`CI / Nix` or `CI / Player E2E` runs finishing. They are a separate signal and
waiting on them just stalls the release.

Prerelease versus stable is inferred from the tag (`-beta`, `-rc`, `-alpha`).
Prereleases skip three things: the bundled `priv/changelog/<version>.md` check is
stable-only, so a beta needs no changelog commit and `testflight-notes.sh` falls
back to player commit subjects; `Deploy Docs` and `Deploy Web Player` are both
skipped, the latter because web.mydia.dev has no staging copy; and Docker gets
`:beta` instead of `:latest`, `:MAJOR` and `:MAJOR.MINOR`.

Draft-first exists because Immutable Releases is on for this repo, so assets can
only be uploaded while the release is a draft. The workflow also cannot use the
`release` event, because GitHub silently drops `release: created` for drafts.

Version convention is `vMAJOR.MINOR.PATCH` with dot-suffixed prereleases
(`v0.13.0-beta.1`). The older no-dot form (`v0.10.0-beta2`) is legacy.

## devenv task caching is unsound for external state

Two devenv 2.1.2 semantics that are invisible from `devenv.nix`, verified against
devenv's own `src/modules/processes.nix` and `devenv-tasks/src/types.rs`.

`execIfModified` hashes inputs, so it is only sound when the task's output is a
pure function of those inputs. A task that creates or migrates a database
produces external mutable state the watched paths do not describe, so once it has
succeeded, deleting the database does not make it re-run. `devenv tasks run` has
no `--force`, so there is no escape hatch at the call site. A failed run records
no hash, which is why a broken task retries forever while a succeeded-then-invalidated
one never does.

`(Skipped, Succeeded) => Satisfied` in `types.rs`, so a cache-skipped task
satisfies a `processes.<name>.after = [ "task@succeeded" ]` dependency and the
dependent process starts anyway. `(Failed, Succeeded) => NeverSatisfiable`, so
failures do correctly hold the process down.

Together these turn a safety dependency into a silent no-op. The symptom seen was
`./dev db.setup` printing `{}` and leaving a 0-byte database while exiting 0.

Also, a devenv task dependency on `devenv:processes:postgres@ready` makes devenv
start Postgres whenever the task runs, colliding with the postmaster `./dev up -d`
already owns (`FATAL: lock file "postmaster.pid" already exists`). Poll with
`pg_isready` instead. Polling observes; dependencies start things.
