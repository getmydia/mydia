# CI mechanics

How the workflows in this directory actually behave, including the parts that let
breakage sit unnoticed. For the catalogue of known flakes and how to read a red
check, see `ci-flakes.md` next to this file.

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

## Toolchain pins live in several files at once

The Elixir/OTP pin lives in three places that must be bumped together:
`nix/devShells/flake-module.nix` (`elixir_1_19` plus `erlang_28`), `Dockerfile.dev`
(`elixir:1.19-otp-28`), and `ci.yml` (`ELIXIR_VERSION` and `OTP_VERSION`). Bumping
one alone produces green-locally, red-in-CI.

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

## Dependabot: a stale base blocks a green PR forever

The Master ruleset requires `Load lanes (ios)`, `Load lanes (android)`,
`Site build`, `Test`, `Test / PostgreSQL` and `Test / E2E Browser`. Several of
those workflows were originally `paths:`-filtered, and `20f0db5e2` (2026-08-26)
removed the filters precisely so they report on every PR.

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

Three gotchas around it:

- The mix_unused `:unused` compiler must be prepended (`[:unused | base]`).
  Appending (`base ++ [:unused]`) produces no report in this version. It is gated
  to `Mix.env() in [:dev, :test]` and `UNUSED_CHECK=true`.
- Build-time helper modules referenced by `mix.exs` must be inlined in `mix.exs`
  rather than kept in a separate root file. The Docker build's
  `mix deps.get --only prod` layer copies only `mix.exs` and `mix.lock`, so a
  sibling `Code.require_file("mix_quality.ex")` fails with `(Code.LoadError) enoent`
  and breaks all image builds.
- The `mix compile --warnings-as-errors` gate runs in CI's test-env compile, so
  test-only warnings such as a duplicate `@doc` in `test/support/` fail CI even
  when a local dev-env compile is clean. Reproduce with
  `MIX_ENV=test mix compile --warnings-as-errors --force`.

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
