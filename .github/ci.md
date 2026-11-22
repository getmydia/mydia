# CI mechanics

How the workflows in this directory actually behave, including the parts that let
breakage sit unnoticed. For the catalogue of known flakes and how to read a red
check, see `ci-flakes.md` next to this file.

This file is deliberately **not** called `README.md`. GitHub picks the repository
landing page from `.github/README.md` before the root `README.md`, so a README
here silently replaces the project's front page with this document. It did, from
46cbdfdb0 until it was noticed. Any new doc in this directory needs a name other
than `README.md`.

## The NixOS module tests skip human PRs and block nothing

`nixos-module` and `nixos-module-postgres` (`nix/checks/flake-module.nix`) boot
the package in a QEMU VM. They are flake checks, no longer gated on
`flake.lock`, and they build `packages.default` and `packages.postgres` as
inputs (`ciInternal.package-default`, `ciInternal.package-postgres`), which
is why there is no separate `Build / Packages` job.

`scripts/ci-plan.sh` lists them apart from the other checks, and ci.yml
builds them in their own matrix job, `Nix / NixOS (<name>)`, which
`Nix / Checks` does not include, so they are not part of `Test` or
`Test / PostgreSQL`. A QEMU boot on a shared runner is the slowest and
flakiest build in the set, and gating every merge on them would make a VM
hiccup a merge blocker.

They also skip most pull requests. When this was decided the packages took
`src = ../..`, so a docs-only or translation-only PR rebuilt both, about 28
runner-minutes and 16 minutes of wall clock per PR, for a result nobody had
to read. The packages now take the `mydiaPackage` file set
(`nix/ci/sources.nix`: the Elixir app, assets, the NIF and plugin crates and
the Cardigann guest directory), so an edit outside it leaves them, and these
tests, cached; the PR policy has not been revisited since. The job runs on
master pushes, on manual dispatches, and on
pull requests opened by Dependabot; master pins include its outputs.
Dependabot is the exception because the Dependabot gate merges with
`GITHUB_TOKEN`, which starts no master run (see "Dependabot merges through
a gate, not GitHub's auto-merge"), so a
dependency or `flake.lock` bump gets no other NixOS run, and the gate
accepts only SUCCESS, SKIPPED or NEUTRAL, so a red VM test holds the bump
back. On any other PR the `Nix / Plan` summary still lists the NixOS tests
the cache lacks, marked as not built, and no `Nix / NixOS` job appears.
When both are already in the cache (a passed result for exactly this
input), the planner leaves the matrix empty and the job is skipped.

So a red `Nix / NixOS` on master is a real signal nobody is forced to read.
For any `.nix`, `flake.lock` or packaging change, get the result before
merging: build the affected checks locally
(`nix build .#checks.x86_64-linux.<name> -L`), or dispatch CI on the branch
(`gh workflow run ci.yml --ref <branch>`), which runs the NixOS jobs and
pushes their outputs, so master's own run then finds them cached.

## npmDeps.hash must move with package-lock.json

`npmDeps.hash` in `nix/packages/flake-module.nix` is a fixed-output derivation
hash and must be bumped in the same commit as any `assets/package-lock.json`
change. `relayNpmDeps.hash` in the same file is the same for
`metadata-relay/assets/package-lock.json` (the `metadata-relay` package, which
the player-e2e VM test runs). Everything below covers both: the pairs are
listed once, in `npm_deps_targets` in `scripts/lib/npm-deps-hash.sh`. A stale
value fails the Nix build as
`error: hash mismatch in fixed-output derivation '...npm-deps.drv'`, with the
correct value on the `got:` line.

Two things keep it in step:

- The devenv pre-commit hook `npm-deps-hash` runs
  `scripts/update-npm-deps-hash.sh` whenever either lockfile is staged. It
  rewrites the hash and stops the commit; stage `flake-module.nix` and commit
  again. `scripts/regenerate-derived.sh` (run by `dependabot-fixup.yml`)
  rewrites both after a Dependabot bump.
- `Check / Generated Freshness` recomputes the hash on every pull request and
  fails with the pinned and computed values side by side.

Both compute the hash with `prefetch-npm-deps` from the flake's pinned nixpkgs
(`scripts/lib/npm-deps-hash.sh`) and compare strings. Never gate this by
building `.#packages.x86_64-linux.default.npmDeps`. A fixed-output derivation's
store path depends only on its declared hash, so an unbumped hash names the path
master already built, the binary cache substitutes it, nothing is fetched, and
the build passes. `Check / Flutter Pin` ran exactly that step. It passed on #967,
which changed the lockfile and left the hash, and master's `CI / Nix` went red
on the merge. The hash had drifted twice before (`d1109d65c`, `f00681d22`, 15
red master runs, fixed in #584), both times while the NixOS module tests still
ran on master pushes only.

The package now builds in ci.yml's NixOS module jobs, so a stale hash that gets
past the freshness check shows as a red `Nix / NixOS (<name>)` (the package
builds inside that job; the blocking `Nix / Input` wave never builds what only
the NixOS tests need). Those jobs block nothing and skip human pull requests
(see "The NixOS module tests skip human PRs and block nothing"), so on those
the freshness check is the only pre-merge guard: after a `package-lock.json`
change, dispatch CI on the branch or build `.#packages.x86_64-linux.default`
locally before merging. When one is red, grep its log for `hash mismatch` first. It is a one-line fix
(`./scripts/update-npm-deps-hash.sh`) and it masks everything downstream,
since the build aborts before the Rust crate vendoring even starts.

## The Elixir and OTP pins each live in one file

`.elixir-version` holds the Elixir minor and `.otp-version` the OTP major, and
nothing else may name either. `beam-version.nix` resolves the pair from one
nixpkgs beam set and throws when the pinned nixpkgs lacks the OTP set or the
Elixir attribute under it. `devenv.nix` imports that resolver and is the
toolchain for local development. `nix/toolchains.nix` imports it too, for the release build in
`nix/packages/flake-module.nix`, the NixOS module VM tests and every flake
check under `nix/ci/`.

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
jobs going red on master with every other job green, unnoticed pre-merge
because at the time neither ran on pull requests.

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

The trigger also filters on `branches: ['dependabot/**']`, the triggering run's
head branch. Unfiltered, every listed workflow on every branch woke the gate,
nearly half of all Actions runs, only for it to find no Dependabot pull request.
The fixup's push and the gate's own re-runs are on Dependabot branches, so they
still wake it.

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
and re-runs the failed jobs of any run still on attempt 1. It logs `Retrying
once before reporting PR #<n> as blocked.` instead of commenting, and the
re-run's completion wakes the gate again. Only
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
nix and actions:

| Group | Covers |
|---|---|
| `backend` | mix `/`, npm `/assets` |
| `relay` | mix and npm under `/metadata-relay` |
| `player` | pub, the player's Rust crate, both fastlane Gemfiles |
| `rust` | `/server`, `native/*`, `plugins/*` |
| `tooling` | `/site`, `/docs` |
| `nix` | `flake.lock`, and `devenv.lock` through the fixup (below) |
| `actions` | github-actions, alone because the gate cannot merge it (above) |

Majors are ignored everywhere except actions, and every entry has a seven-day
`cooldown`. Both settings apply to version updates only, so security updates
still open immediately, majors included. Take a major deliberately: bump it on
a branch of your own.

Some dependencies have their version updates ignored by name because their bumps need work nothing
automates: `fine`, `lazy_html`, `wasmex` and `heroicons` (hand-pinned hashes
in `nix/packages/flake-module.nix`), `tailwindcss` (pinned across npm, config
and nix), and `flutter_rust_bridge` on both sides (needs a codegen run). The
comments in `dependabot.yml` say what each one moves. Their security updates
still open; for `fine`, `wasmex`, `tailwindcss` and `flutter_rust_bridge` the
freshness check then fails until the pin moves, so they wait for a person
rather than merging.

### The fixup regenerates derived files

`dependabot-fixup.yml` runs `scripts/regenerate-derived.sh` on every Dependabot
pull request except github-actions bumps, which touch no manifest it regenerates from. The script rewrites `deps.nix` from `mix.lock` with `mix2nix`,
refreshes every Cargo.lock listed in `scripts/lib/cargo-lock-dirs.sh`, and
recomputes `npmDeps.hash` with `prefetch-npm-deps`, copies flake.lock's nixpkgs
node into `devenv.lock` (`scripts/sync-devenv-nixpkgs.sh`), then runs
`check-generated-freshness.sh`. Run it locally the same way.

### nixpkgs bumps carry devenv with them

Dependabot's `nix` ecosystem reads `flake.lock` only and has no security
updates. `devenv.lock` is invisible to it, yet `devenv.yaml` requires its
nixpkgs on flake.lock's revision, and the freshness check fails any tree where
they differ. So when the fixup sees flake.lock's nixpkgs ahead of devenv.lock's,
it first runs `devenv update`, moving devenv, git-hooks and rust-overlay, and the
regenerate step then pins devenv.lock's nixpkgs back to flake.lock's revision.
The devenv CLI in CI comes from that same nixpkgs (`--inputs-from .`), so it
moves too.

Every check a nix bump needs runs on its pull request, because the gate's
merge starts no workflows on master (the trap that left the Cardigann guest
unpublished). `flake.lock` moving changes the toolchain under every flake
check, so the whole `ci.yml` check matrix reruns, NixOS module tests
included (they run on Dependabot's PRs for exactly this reason); and the
fixup touches nothing under
`.github/workflows/`, which the gate could not merge. `nixpkgs-android` is
ignored: it moves by hand, with Flutter.

A bump can fail for reasons no fixup can repair: `beam-version.nix` aborts when
the new nixpkgs no longer ships the OTP major in `.otp-version`, and the NixOS
module checks catch a package that no longer builds. Fix those by hand on the Dependabot branch.

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
Since phase 2 of Nix CI, `Test / Player`, `Test / Player E2E` and
`Build / Web` are aggregators in `ci.yml` and `ci-player.yml` holds no
required context, so it is `paths:`-filtered again.

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
- Every CI and release `flutter pub get` passes `--enforce-lockfile`. A lock
  that does not resolve on the pinned SDK fails `Test / Player`, and the gate
  reports `BLOCKED`. The player E2E runs no `pub get` of its own: its client
  works on a copy of `player-codegen`, like the other player checks.

## Quality gates

PR #186 (merged 2026-06-05) removed dead-code and duplicate-code grandfathering.

Credo is a true hard gate. CI runs `mix credo --strict`, every check is either
enabled and gating at zero or set to `false` with a rationale, and there is no
`exit_status: 0` anywhere, enforced by a grep guard in the `elixir-lint` flake
check (`nix/ci/elixir.nix`). The policy is documented in `CONTRIBUTING.md`.
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
  output nothing is gated on. It is the last step of ci.yml's `Lint / Ratchet`
  job, behind `if: github.event_name == 'push'`, and its failure is ignored.
  Run it yourself with `UNUSED_CHECK=true ./dev mix compile --force`.
- Build-time helper modules referenced by `mix.exs` must be inlined in `mix.exs`
  rather than kept in a separate root file. The Docker build's
  `mix deps.get --only prod` layer copies only `mix.exs` and `mix.lock`, so a
  sibling `Code.require_file("mix_quality.ex")` fails with `(Code.LoadError) enoent`
  and breaks all image builds.
- The `mix compile --warnings-as-errors` gate runs in CI's test-env compile, so
  test-only warnings such as a duplicate `@doc` in `test/support/` fail CI even
  when a local dev-env compile is clean. Reproduce with
  `MIX_ENV=test mix compile --warnings-as-errors --force`.

### Dialyzer

The `dialyzer` flake check runs `mix dialyzer --format github` in
`MIX_ENV=test` on top of the SQLite test build and fails on any finding. The
PLTs are their own derivation, `ciInternal.dialyzer-plt`, built from the
compiled dependencies and the toolchain but not from `lib/`: an app edit
reuses the cached PLT, and a `mix.lock`, `patches/` or BEAM pin change
rebuilds it. A patch change therefore never meets a PLT built from other patch
content, which the old version-keyed Actions cache had to arrange by hand
(dialyxir compares dependency versions, not beam contents).
The `elixir-lint` check greps `mix.exs` for `ignore_warnings`, `lib/` and
`test/support/` for `@dialyzer`, and checks for a `.dialyzer_ignore.exs` file
(Dialyxir loads it by default without any `mix.exs` setting). It fails if any
of the three appears. The policy is in `CONTRIBUTING.md`.

### Rust lint and test-warning gates

Every crate under `native/` (minus `cardigann_guest`), `player/rust/` and
`server/` has three flake checks, `rust-<crate>-fmt`, `-clippy` and `-test`,
with the commands and flags `scripts/check-rust.sh` and the old per-crate
`cargo test` steps used; `rust-plugins` runs `scripts/check-plugins.sh` and
`scripts/test-plugins.sh`, and `rust-p2p-core-wasm` the p2p core's browser
build and clippy (`nix/ci/rust.nix`). `scripts/check-rust.sh` finds crates by
glob, so the `native-rust` pre-commit hook gates a new crate at once; the
checks need an entry in `nix/ci/rust.nix`'s crate list, and the
`ci-crate-list` check fails until the two agree.

`mydia_smb`'s Samba integration tests need a root smbd, which the sandbox
cannot provide, so `rust-mydia_smb-test` skips them. ci.yml's `Rust / SMB
integration` job runs them against a real Samba
(`player/rust/mydia_smb/tests/samba/run-samba.sh`) with
`MYDIA_SMB_REQUIRE_HARNESS=1`, which turns a harness that failed to start
into a failure.

The SQLite and PostgreSQL shards run `mix test --warnings-as-errors`, which
aborts the run after the tests finish when a test file emitted a compile warning. LiveViewTest
warnings raise through `config :phoenix_live_view, :test_warnings, :raise` in
`config/test.exs`, so they fail the individual test instead.

### Watching test-suite speed

The regression signal is already free on every run: ExUnit's
`Finished in Xs (Ys async, Zs sync)` line. Sync time is the number that matters
here, because `test/test_helper.exs` pins `max_cases: 1` on SQLite and
`Mydia.DataCase` forces database tests to `async: false`, so the suite is
overwhelmingly serial and a slowdown shows up as sync time climbing. Measured on
master 2026-09-03: `876.4 seconds (59.1s async, 817.3s sync)`. Since the suite
is sharded (below), each shard prints its own line, so compare a shard against
the same shard rather than against that whole-suite figure.

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

## ci.yml: the flake-check graph

The backend's checks are flake checks under `nix/ci/`: Elixir format, lint
and Dialyzer, the SQLite and PostgreSQL shards, the Wallaby browser suite
(`e2e-browser`), every Rust crate's fmt, clippy and tests, the plugins, the
relay's suite, the NixOS module VM tests and the repository guards. The
player's Linux, web and VM checks are flake checks too (`nix/ci/player.nix`:
`player-analyze`, `player-l10n-test`, `player-icons`, `player-test`,
`player-test-web`, `player-web`, `player-linux`). Each is a derivation whose hash covers exactly the
files and toolchain it reads (every `src` is a `lib.fileset`), and every
built output goes to the niks3 binary cache, `cache.mydia.dev`. A run builds
what changed and substitutes the rest, so there is no path filter and no
Actions cache in `ci.yml`: the derivation graph is the filter. The graph,
with what each derivation reads, is in `nix/ci/README.md`, "The derivation
graph". In short: a `lib/` edit rebuilds the two test builds and everything
on top of them and leaves the dependency builds, the PLT, the NIFs and the
Rust and relay checks cached; a `test/` edit reruns only the shards; a
workflow edit reruns only `ci-workflow-triggers`. A
Weblate `.po`-only PR
rebuilds the test build and runs every shard, because Gettext compiles the
catalogs into the backend; the old `Translations` fast path is gone. A
player-only PR runs only the player checks, and a backend-only PR finds
every player check cached.

The jobs, in order:

- `Nix / Plan` runs `scripts/ci-plan.sh`: `nix-eval-jobs
  --check-cache-status` over `checks.x86_64-linux`, which lists the checks
  the cache lacks, and the `ciInternal` derivations (compiled deps, test
  builds, NIFs, the PLT, rustfs) that two or more of them still need.
- `Nix / Input (<name>)` builds each of those shared inputs once and pushes
  it, so the check jobs substitute it instead of each building its own copy.
  It is skipped for fork PRs, which cannot push, and for Dependabot runs,
  which may not get an OIDC token: inputs built where a push may fail only
  duplicate what each check job then builds for itself.
- `Nix / <check>` is one job per uncached check: `scripts/ci-nix-build.sh`,
  then a push of the output.
- `Nix / NixOS (<name>)` builds the uncached NixOS module VM tests the same
  way, outside the verdict, on master pushes, manual dispatches and
  Dependabot PRs only (see "The NixOS module tests skip human PRs and block
  nothing").
- `Nix / Checks` aggregates plan, inputs and checks: success when the plan
  succeeded and each of the two build jobs succeeded or was skipped (an
  empty matrix).
- `Nix / Pins` runs on master only and pins every check and `ciInternal`
  output as `master-<name>` (below). It never fails the run.

### Reading the plan

The `Plan` step's summary, "Nix plan", says how many inputs and checks this
run builds and lists them with their group (`sqlite`, `postgres`, `lint`,
`rust`, `server`, `relay`, `nixos`, `other`); everything else was already
cached. The step log prints the same as JSON. A check missing from the matrix
passed on an earlier run with identical inputs, and its log is in the cache:
`nix build .#checks.x86_64-linux.<name>` substitutes the output and
`result/test.log` (shards, Rust tests, relay) or `result/log` (the other
Elixir checks) is the run that cached it. An evaluation error fails the plan
with an `::error::` naming the attribute.

### Reproducing a check locally

    nix build .#checks.x86_64-linux.<name> -L

builds exactly what CI builds, in the same sandbox. With `cache.mydia.dev`
as a substituter (key
`cache.mydia.dev-1:5zkoQR4Gcrx1EEQ1GvHRPQ7EoHm8gNrrVoeAqX3ioFg=`) the inputs
come from the cache; devenv's shell does not set it, so pass
`--option extra-substituters https://cache.mydia.dev --option
extra-trusted-public-keys <key>` or add both to `nix.conf`. `nix log` on a
failed derivation shows its output again. New files must be visible to git
(`git add -N`) before Nix sees them. What the sandbox means for tests is in
`test/README.md`, "Sandboxed CI runs": no network, `--seed 0`, only the files
and tools the check lists. Four tests that need a real network interface or
a default route are tagged `:external` there and no longer run in CI
(`DirectUrlsTest` "includes local URLs", two `DirectUrlRefresherTest` cases
and a `Plugins.Net.GateTest` connect timeout); run them with
`./dev mix test --include external <file>`.

### Pushing from a workstation

The devenv pre-push hook `nix-cache-push` (`scripts/nix-cache-push-hook.sh`)
builds the pushed commit's outputs in the background and pushes them with
`scripts/nix-cache-push.sh`, so CI finds them already built. It never blocks
or fails a push and is a silent no-op without the niks3 admin token in
`~/.config/mydia/niks3-token`. `MYDIA_NIX_PUSH` selects what it builds:
`builds` (the default, every `ciInternal` output, the expensive compile
artifacts), `all` (the checks too, which runs the suites) or `off`. Its log is
`.devenv/state/nix-cache-push.log`. `scripts/nix-cache-push.sh <attr>...`
pushes chosen attributes by hand.

### niks3

CI pushes through niks3 at `niks3.mydia.dev` with a GitHub OIDC token, so
only `Nix / Input`, `Nix / <check>`, `Nix / NixOS` and `Nix / Pins` hold
`id-token: write`. A push that fails three times warns and never fails the
job. niks3 garbage-collects unpinned paths after 14 days; PR runs push
without a pin, and `Nix / Pins` refreshes the `master-<name>` pins on every
master run, so master's newest closure never ages out. Deployment, secrets,
the signing key and health checks are in
`infra/kubernetes/apps/nix-cache/README.md`. The pin count is

    kubectl --context k3s-can1 -n nix-cache exec deploy/niks3-postgres -- \
      psql -U niks3 -c 'select count(*) from pins'

### Jobs outside the sandbox

- `Guards` runs the one guard that reads the workflows with `yq` (below).
  The file-only guards (Rust toolchain pin, Rust lint tables, Docker
  build-identity placement, pre-migration backup task, devenv shell-entry
  purity) are the `guards` check in `nix/ci/guards.nix`.
- `Lint / Ratchet` runs `mix mydia.ratchet --from-git-merge-base
  origin/master`, which reads git history, and on master pushes the advisory
  `mix_unused` report. It does not compile the app: Mix recompiles only a
  handful of files (about 14). `scripts/ci-restore-test-build.sh --mount`
  bind-mounts the checkout at `/build/source` (Mix records absolute paths)
  and lays the cached `ciInternal.mydiaTestBuild-sqlite` over it with every
  file dated to the epoch, and the job runs Mix in `nix develop .#ci`
  (`nix/ci/README.md`, "Outside the sandbox").
- `Rust / SMB integration` runs `mydia_smb`'s Samba tests (above).
- `Build / Android` builds the release APK when its inputs changed (below).

The Wallaby browser suite is the `e2e-browser` check (`nix/ci/tests.nix`),
not a job: nixpkgs chromium and chromedriver over the SQLite test build and
`ciInternal.assets`. CI uploads no screenshots: tests write them only by an
explicit `take_screenshot`, and a local
`nix build .#checks.x86_64-linux.e2e-browser --keep-failed` keeps them under
the path the failed check prints.

### Build / Android runs when its inputs change

`Build / Android` is the one player build that is not a derivation. Making it
one needs a Gradle dependency lockfile for nixpkgs' `mitmCache` to fetch
from, refreshed on every Android dependency bump, and Flutter's Android
engine artifacts have never been proven inside the sandbox
(`design/specs/2026-11-21-nix-ci-phase-2-design.md`, "Android"). So it is an
ordinary job in `ci.yml`, but the plan still decides whether it runs, through
a stamp (`nix/ci/android.nix`):

- `legacyPackages.x86_64-linux.ciAndroid.stamp` is a tiny derivation naming
  the source of everything the job reads (the player app, `player/android`,
  `mydia_player_p2p` and its path deps, the GraphQL schema,
  `scripts/check-apk-abis.sh`, `ci.yml`, minus Markdown) and the `.#android`
  shell's `.drv`, so a `flake.lock`, Flutter or toolchain change counts as an
  input change.
  It holds those as plain strings, with no store references.
- `Nix / Plan` reports `android: true` while cache.mydia.dev lacks the stamp,
  and the job runs; otherwise it is skipped. Of the 80 PRs merged before
  this changed, 39 touched none of those inputs (Markdown is excluded).
- The job pushes the stamp as its last step, after the APK built and passed
  `scripts/check-apk-abis.sh`, so only a passing build marks inputs as done.
  Fork PRs and Dependabot cannot push, so for them it runs every time.
  `Build / Android` is not a required context, so a skip blocks nothing.

Its toolchain is `nix develop .#android`, the shell `./dev player android
build` uses. Before building, the job realises `ciAndroid.shell` (the shell's
`inputDerivation`) and pushes every input of it except the `androidsdk`
composition (`scripts/ci-android-shell-push.sh`, which refuses to push at all
if any of those inputs' closures reaches the SDK). The SDK, NDK, platforms and
build tools are unfree; their licence forbids redistribution and
cache.mydia.dev is publicly readable, so each run still unpacks them (about
8 GB). The Rust toolchain with its Android targets was the one free input no
cache carried. Never add `ciAndroid.shell` to `ciInternal`, the pins or any
push: its closure is the SDK. There is no `actions/cache`; pub and Gradle
fetch on each run. The steps are `flutter pub get --enforce-lockfile`,
`flutter pub run build_runner build` and `flutter build apk --release
--target-platform android-arm,android-arm64`, then
`scripts/check-apk-abis.sh` and the `mydia-player-android-apk` artifact.

### ci-player.yml: what Nix does not cover

`ci-player.yml` keeps the Windows and macOS build legs and the Flatpak jobs
(`Flatpak / Validate metadata`, `Flatpak / Build`). None of them is a
required context, so it carries a workflow-level `paths:` filter on push and
pull_request (player/, native/, the GraphQL schema, `rust-toolchain.toml`
and the workflow itself) instead of the `changes` job it had while it held
required checks. A PR that changes only translated ARB catalogs, not the
`app_en.arb` template, does not trigger it; `player-l10n-test` covers those.
The AppImage dry run is `ci-player-appimage.yml`, filtered on the packaging
files alone.

The Linux bundle CI builds (`player-linux`) is not uploaded: its runpath
points into `/nix/store`, so it runs nowhere else. Release Linux bundles
come from `player-linux.yml`.

`ci-nix.yml` consolidates the non-VM pin, freshness, release-note, Apple-target,
guard, and Dependabot-gate checks into two runners (`Check / Repo Contracts` and
`Check / Pins & Freshness`) so non-VM PR checks share one Nix setup
instead of eight runners.

### Shards

The SQLite suite runs as four checks (`test-sqlite-{1..4}`) and the
PostgreSQL suite as three (`test-postgres-{1..3}`), each its own job using
`mix test --partitions` (`nix/ci/tests.nix`). SQLite stays at `max_cases: 1`
inside every shard, since the suite shares one writer per database, and each
shard has its own database in its own sandbox. `config/test.exs` suffixes
`MIX_TEST_PARTITION` to the database name, which lets
`scripts/test-partitioned.sh` run the same partitions side by side on one
machine. `--partitions` sorts the test files and deals them out round-robin,
not by duration, so adding a test file can shift later files to another
shard. If one shard runs well over the others, raise the count in
`tests.nix` (`shards "sqlite" 4`) rather than moving files by hand. The tests
do not run with `--cover`.

### Aggregators

The names `Test`, `Test / PostgreSQL`, `Test / E2E Browser`, `Test / Player`,
`Test / Player E2E` and `Build / Web` are required by the Master ruleset, and
they sit on aggregator jobs (`test`, `test-postgres-result`, `test-e2e-result`,
`test-player-result`, `test-player-e2e-result`, `build-web-result`), as do `Build / Linux` and
`Check / Web icons` (`build-linux-result`, `icons-result`), which kept their
names from `ci-player.yml`. `Test` needs `Guards`, `Nix / Checks`,
`Lint / Ratchet` and `Rust / SMB integration`; the others need
`Nix / Checks`. A matrix leg's result is not addressable through `needs`, so
every aggregator gates on the whole check matrix: a failing Rust check also
reds `Test / Player`, and a failing `player-test` reds `Test / PostgreSQL`.
`Build / Android` is a plain job, not an aggregator, and not required: the
plan skips it when its stamp is cached. The NixOS VM tests are not in that matrix and gate
neither. Each has `if: always()` and a step that fails unless
every job it needs concluded `success` or `skipped`, so the aggregator itself
concludes success or failure and never `skipped`. The `Guard the required-check aggregators` step in `Guards` checks
with `yq` that each required name sits on exactly one job whose `if` is
`always()`. See `ci-flakes.md`, "Why the list was short".

### Compile-time config and the test build

Every consumer of `ciInternal.mydiaTestBuild-*` (the shards, `elixir-lint`,
`dialyzer`, `ci-workflow-triggers`, `e2e-browser`, the ratchet) must run Mix
with the same compile-time configuration the build had, or Mix recompiles
every file of the app: it stores each app's compile-time config in the
manifest, and when the `:mydia` app's config differs it recompiles all of it.
The build sets `MYDIA_PREBUILT_NIFS=1`, `MYDIA_PREBUILT_PLUGINS=1`,
`MYDIA_SKIP_CARDIGANN_FETCH=1` and, for the PostgreSQL build,
`DATABASE_TYPE=postgres` (the `env` in `nix/ci/elixir.nix`); the checks and
`devShells.ci` take that same `env`.
Anything that varies per shard or per run (partition numbers, database names,
ports, temp paths, `CI`) belongs in `config/runtime.exs`, which Mix does not
track, or in a different app's config, never under `:mydia` in
`config/test.exs`. `config/test.exs` used to put `MIX_TEST_PARTITION` in the
Repo database name, and under the old Actions cache every job that restored
another job's `_build` recompiled all ~1455 files, 3 to 4.5 minutes per job,
until 2026-11-20. "Compiling 1455 files" in a shard log is the symptom. To
check a candidate locally, compile, `touch config/test.exs`, change the
variable and compile again: a handful of files is fine, all of them is this
bug.

### The Actions cache budget

`ci.yml` no longer uses the Actions cache. The rest of this is history that
still shapes the other workflows. The Actions cache has a 10 GB limit per
repository, and it is evicted least recently used first. On 2026-10-15 it
held 10.6 GB, 3.8 GB of that two
`flutter-windows` SDK entries, so eviction had been dropping the 155 MB `_build`
cache and about 5 of 12 PR runs recompiled deps and NIFs from scratch. Dropping
the Windows SDK cache was not enough. Later that day the cache held 10.79 GB:
7.2 GB in 163 `buildkit-blob-*` entries (Docker `type=gha` layer caches written
with `mode=max`), 2.2 GB in one `flutter-macos-stable-*` SDK entry, and only
about 0.7 GB for everything `ci.yml` needs. Warm PR CI measured about 8 minutes
and cold about 20, so the cure was to get the big entries out of the budget:

- No workflow caches the Flutter SDK (`subosito/flutter-action` without
  `cache: true`; the release builds set it up once, in
  `.github/actions/player-flutter-prep`). Once the Docker blobs were gone, `ci-player.yml` took their
  place: about 2 GB per platform per player PR. The SDK download costs about a
  minute. Pub caches are small and stay on the Windows and macOS legs; the
  Linux, web and Android player builds keep none (the Nix checks read pub
  packages from the `player-pub-cache` derivation, and `Build / Android`
  fetches on each run).
- Docker layer caches no longer use `type=gha`. They are `type=registry` tags
  named `buildcache*` on the existing public GHCR packages, which do not count
  against the Actions cache: `:buildcache-sqlite` and `:buildcache-postgres`
  (written by `ci-docker.yml` and, for amd64 only, `release.yml`) and
  `:buildcache-cwasm-<arch>` (`cardigann-cwasm.yml`, never on pull requests) on
  the main image package, and `metadata-relay:buildcache` (`ci-relay.yml`
  publish). Tags on
  existing packages rather than a new package, because a new package starts
  private and fork PRs and anonymous pulls must be able to read the cache.
  Exports use `mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true`,
  which GHCR needs for cache manifests and which keeps a failed cache push from
  failing the build.
- `ci-nix.yml` and `dependabot-fixup.yml` install Nix through the `nix-ci`
  action with `push: 'false'`, so they read cache.mydia.dev, which ci.yml's
  flake checks fill through niks3, and push nothing. The `mydia` Cachix cache
  is now written only by `release.yml` and `deploy-web-player.yml`. Nothing
  uses magic-nix-cache, which stored every store path as its own Actions
  cache entry (2,226 entries, 1.1 GB on 2026-10-30).

Check the budget with:

```bash
gh api repos/getmydia/mydia/actions/cache/usage
```

## The player suite runs as one bundle

The `player-test` check runs the suite as one bundle, not file by file.
Measured on 2026-10-15, 760 of the per-file run's 988 seconds were compiling
666 test files one at a time; the bundle compiles once. CI does not run
`very_good` itself: `nix/ci/player.nix` reimplements, in bash, the part of
very_good_cli 1.5.0's test optimizer the suite relies on (the generated
`test/.test_optimizer.dart` and the separate run of files tagged
`skip_very_good_optimization`), while developers run the real
`very_good test` locally. Bumping very_good means re-reading that generator.
Leak rules and the local repro command are in `player/docs/workflow.md`. The
browser (`player-test-web`) and television-tier runs still use plain
`flutter test` on enumerated files.

## The player E2E is a blocking VM test

`Test / Player E2E` is the aggregator over the `player-e2e` check
(`nix/tests/player-e2e.nix`): a `nixosTest` with a metadata-relay VM, a
server VM running the NixOS module on `packages.default`, and a client VM
that runs `integration_test/all_tests.dart` under Xvfb through
`scripts/e2e/run-tests.sh`. Unlike the NixOS module tests it is not
`nixos-`-prefixed, so it builds in the blocking `Nix / Checks` matrix, whose
job enables KVM for it, and a red run reds every aggregator, not only
`Test / Player E2E`. It has no retry: as with every check, a pass is cached
and a failure reruns on the next push. Run it locally with
`nix build .#checks.x86_64-linux.player-e2e -L` (or `./dev player e2e`); it
needs KVM. `nix/ci/README.md` covers the client's environment.

The VM test boots the Nix package, not the release image, so it cannot catch
a `Dockerfile` that fails to build. The Docker-compose workflow it replaced
built that image on pull requests touching the player inputs the `Dockerfile`
copies one by one, which is the guard #1444 called for: that PR added a path
dependency the `flutter-builder` stage did not copy and broke every release
build after merge. The guard now lives in `ci-docker.yml`. On a pull request
that touches the `Dockerfile`, the workflow itself, or anything that stage
copies (its path filter mirrors the stage's COPY lines, minus `player/lib`
and `player/web`, which `Build / Web` covers), `Docker / flutter-builder (PR)`
builds that stage alone,
with `push: false` and the `:buildcache-sqlite` registry cache read-only (no
login, so fork PRs build too, and no cache export). It is not required.
Push runs build and publish the full image as before.

## The precompiled Cardigann guest

`cardigann-cwasm.yml` precompiles the published Cardigann guest to a `.cwasm`
for x86_64 and aarch64, each on a native runner through the Dockerfile's
`cwasm-out` target, so the artifact is built by the release image's own Wasmex
and wasmtime. It runs on a guest, Dockerfile, Wasmex pin or engine-config
change, and again when the `Cardigann guest` workflow completes on master (the
guest is only downloadable once that has published it). `cardigann-guest.yml`
runs on every `master` push without a path filter (exiting in seconds when
`cardigann-guest-<hash>` already exists) and supports `workflow_dispatch` so a
Dependabot merge with `GITHUB_TOKEN` cannot leave a new guest hash permanently
unpublished. Pull requests build both
architectures and upload them as run artifacts, but never publish. On master the
`publish` job creates the immutable release
`cardigann-cwasm-<hash>-wasmtime<ver>-cfg<n>` holding both `.cwasm.gz` files with
their `.sha256`, plus `.LICENSE` and `.NOTICE`. It is the only producer of
`cardigann-cwasm-*` releases; never create one by hand. It is soft: an image
built before the release exists has no `.cwasm` pin and compiles the guest
locally on first boot. The wasmtime version in the tag is read from the Wasmex
crate's `Cargo.toml` on GitHub at the tag matching `mix.lock`, and
`scripts/cardigann_precompile.exs` fails the build if that disagrees with the
crate it actually compiled against.

## The Docker image builds the NIFs and bundled plugins in their own stages

`Dockerfile` builds `mydia_p2p` and `mydia_subsync` in a `nifs` stage that
copies only those crates (plus `mydia_p2p_core`), and the bundled WASM plugin
guests (`plex`, `simkl_sync`, `webhook_notifier`) in a parallel `plugins` stage
that copies only `native/mydia_plugin_sdk/`, `native/mydia_plugin_macros/`,
and `plugins/`. `builder` copies the
two `.so` files into `priv/native/` and the `.wasm` files into `priv/plugins/`,
and sets `ENV MYDIA_PREBUILT_NIFS=1` and `ENV MYDIA_PREBUILT_PLUGINS=1` so
`mix compile` loads them instead of running cargo when only Elixir/config
changed. Before this, Rustler built the NIFs and `:plugins` built the WASM
guests after `COPY lib`. Both stages are cached through the `:buildcache-*`
registry tags, with cargo target dirs kept in BuildKit cache mounts.

cargo runs from each crate directory, not through Rustler, because each crate's
`.cargo/config.toml` already turns `crt-static` off on musl. A probe after
`mix compile` loads both modules and fails the image build if a NIF does not
load. A new `use Rustler` crate needs nothing to keep working: it builds through
Rustler in `builder` as before, just slowly. To move it to the `nifs` stage, make
all three edits together: the `nifs` COPY and loop, the `skip_compilation?` line
in `config/prod.exs`, and the probe's module list. Adding the `skip_compilation?`
line without the stage still passes `mix compile`, because Rustler then does
nothing at compile time and nothing loads the `.so`. Only the probe catches it,
and only if the module is in its list, which is why the list must grow in the
same edit. Without it the image would build and fail at boot.

The built-in torrent engine and the VPN have stages of their own. `rqbit` is
`cargo install rqbit --version "$RQBIT_VERSION" --locked` on the toolchain
stage, with `openssl-dev` and `openssl-libs-static` added: the musl target
links statically and fails with `cannot find -lssl` otherwise. The result is a
static-pie binary with no runtime library dependency. `gluetun` is
`golang:alpine` cloning the tag in `vendor/gluetun/VERSION`, applying
`vendor/gluetun/patches/*.patch` with `git am` and building with
`CGO_ENABLED=0`. The runtime stage copies both binaries; `rqbit` and
`torrent-curl` are setgid `mydia-torrent`. Each stage builds alone with
`docker build --target rqbit .` or `--target gluetun .`. Rebasing the patches
is in `vendor/gluetun/README.md`.

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
Docker and player builds, so do not gate the dispatch on master's `CI`
or `CI / Nix` runs finishing. They are a separate signal and
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
