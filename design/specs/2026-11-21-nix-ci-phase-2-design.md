# Nix-native CI, phase 2: the player and the E2E suites

Status: implemented (PR 1 in #1474; PR 2 moved `Test / Player E2E` onto the
`player-e2e` VM test and deleted the Docker-compose workflow). Approved in
conversation 2026-11-21.

The deleted workflow also built the release `Dockerfile` on pull requests
touching the player inputs it copies (the #1444 guard), which the VM test
cannot replace since it boots the Nix package. PR 2 restored that guard in
`ci-docker.yml`: a non-required `Docker / flutter-builder (PR)` job builds the
`flutter-builder` stage, read-only against the registry cache, on pull
requests that touch those inputs (`.github/ci.md`, "The player E2E is a
blocking VM test").

Follows `design/specs/2026-11-20-nix-ci-checks-design.md` (phase 1, PR #1464),
whose goal, binary cache (niks3 on can-1, reads from R2) and workflow shape
(`plan` job, build matrix, aggregators) this phase reuses unchanged.

## Goal

Give the player and both end-to-end suites the guarantees phase 1 gave the
backend: no path filter that can skip a job and go green, no hand-keyed cache,
and a check that re-runs exactly when Nix says one of its inputs changed.

What this replaces:

- `ci-player.yml`'s `changes` job (a hand-written player path list), its
  `subosito/flutter-action` setup and both `actions/cache` pub caches keyed on
  `hashFiles('**/pubspec.lock')`.
- `ci-player-e2e.yml` in full: the `dorny/paths-filter` `relevant` superset
  invariant, the three pull-or-build Docker image steps, `Publish / Toolbox`,
  the compose retry loop.
- `ci.yml`'s `Test / E2E Browser (run)`, the last job on
  `.github/actions/setup-devenv`.

## Scope

In scope: the Linux, web and Android player jobs of `ci-player.yml`,
`ci-player-e2e.yml`, and `ci.yml`'s E2E Browser job.

Out of scope, unchanged: the Windows and macOS legs of `ci-player.yml`, its
Flatpak metadata validation, the other `player-*.yml` packaging workflows,
`release.yml`, `deploy-*`, `ci-docker.yml`, and the remaining Cachix pushes in
`ci-nix.yml`, `dependabot-fixup.yml` and `deploy-web-player.yml`.

## Facts the design rests on

- All 221 packages in `player/pubspec.lock` are `source: hosted`; none is a git
  dependency. A single fixed-output fetch of the pub cache works without
  per-package hashes.
- Generated Dart (`*.g.dart`, `*.freezed.dart`, l10n) is gitignored, so
  `build_runner` must run in the build. It becomes its own derivation.
- The player's Rust half (`player/rust_builder`, cargokit) shells out to
  rustup. In the sandbox it must instead receive a prebuilt library, as the
  backend NIFs do under `MYDIA_PREBUILT_NIFS`.
- `ci.yml` already enables KVM for the NixOS module VM tests
  (`nix/tests/module.nix`), and that module already runs `packages.default`.
- metadata-relay has a phase 1 test check (`nix/ci/relay.nix`) but no package.

## Derivation graph

New file `nix/ci/player.nix`, exposed as `checks.x86_64-linux.<name>` on Linux
only, like phase 1. File sets are added to `nix/ci/sources.nix`. A file left
out of a set is absent in the sandbox, so the build fails rather than skips.

Shared inputs (cached, not checks):

| Derivation | Inputs | Output |
| --- | --- | --- |
| `player-pub-cache` | `pubspec.yaml`, `pubspec.lock`, `rust_builder/`, `packages/` | fixed-output `PUB_CACHE` |
| `player-codegen` | pub cache, `lib/`, `test/`, `integration_test/`, `build.yaml`, `l10n.yaml`, `analysis_options.yaml` | project tree with `.dart_tool` and all generated Dart |
| `player-p2p-so` | `player/rust/mydia_player_p2p`, `native/mydia_p2p_core`, `rust-toolchain.toml` | `libmydia_player_p2p.so` (crane; cargo deps shared with phase 1's derivation where the lockfiles agree) |

Checks:

| Check | Depends on | Replaces |
| --- | --- | --- |
| `player-analyze` | `player-codegen` | gen-l10n, Analyze localizations, `flutter analyze`, the `@TestOn` tagging guard |
| `player-l10n-test` | `player-codegen` | Test localizations |
| `player-test` | `player-codegen` | very_good VM run (`--concurrency 1`) and the television-tier run (`--dart-define=MYDIA_FORCE_TV=true`) |
| `player-test-web` | `player-codegen` | `*_web_test.dart` under headless chromium |
| `player-web` | `player-codegen` | Build / Web, including the `_headers` check |
| `player-linux` | `player-codegen`, `player-p2p-so` | Build / Linux, including the no-symlinks assertion |
| `player-icons` | `player/web`, icon sources | Check / Web icons (`tool/gen-web-icons.sh --check`) |
| `e2e-browser` | `mydia-test-build-sqlite`, `assets` | Test / E2E Browser (run) |
| `player-e2e` | `packages.default`, `packages.metadata-relay`, `player-codegen`, `player-p2p-so` (the client builds its own debug app; it does not use `player-linux`'s bundle) | Test / Player E2E |

The Flutter package comes from `player/flutter-version.nix`, so `.fvmrc` stays
the single Flutter pin and `Check / Flutter Pin` keeps enforcing it.

### Sandbox details

- **S3 test:** `player-test` starts rustfs on `127.0.0.1:9000` in `preCheck`
  and sets the `MYDIA_TEST_S3_*` variables, so `s3_integration_test.dart` runs
  instead of skipping itself.
- **Empty-glob guards:** the TV-tier and web test file lists keep failing when
  they match nothing. The `git ls-files` calls become `find` over the source
  tree, since the sandbox has no `.git`.
- **cargokit:** `player-linux` puts `player-p2p-so` where cargokit's build
  output would be and makes the cargokit build step a no-op. The exact
  mechanism (cargokit's precompiled-binary path or an environment override in
  `rust_builder`) is settled by spike 1. rustup is never invoked.
- **Determinism:** `flutter test` runs with a fixed `--test-randomize-ordering-seed`
  where randomized order is enabled, matching phase 1's `--seed 0`.
- **Output:** every check writes its log (and JUnit where the runner supports
  it) to `$out`. `player-linux` and `player-web` output their bundles. On
  master the workflow uploads the Linux bundle as `mydia-player-linux-bundle`,
  as today.

### `e2e-browser`

Runs `scripts/run-feature-tests.sh` with nixpkgs `chromium` and `chromedriver`
on top of `mydia-test-build-sqlite` and the phase 1 `assets` derivation. Its
compile-time `MYDIA_*` environment is taken from the same attrset in
`nix/ci/elixir.nix` the test build uses, which removes the hand-synced copy in
the workflow. `scripts/ci-restore-test-build.sh --mount` is deleted if nothing
else calls it.

A failed build has no `$out`, so on failure the check copies
`tmp/wallaby_screenshots/` to a path it prints; running the check locally
with `--keep-failed` keeps that directory. CI uploads no screenshots: the
feature tests use plain `test`, not Wallaby's `feature`, so a failing
assertion writes none, and only an explicit `take_screenshot/2` produces one.
A re-run on failure to collect them was planned and dropped for that reason.

### `player-e2e`

A `pkgs.testers.nixosTest` with three nodes on the test VLAN:

- `relay`: a new `packages.metadata-relay` (a `mixRelease` reusing the deps
  derivation of `nix/ci/relay.nix`) run by a systemd unit with the environment
  `compose.player-e2e.yml` sets today, on port 4001.
- `server`: the existing NixOS module on `packages.default`, configured with
  `E2E_MODE`, `ENABLE_REMOTE_ACCESS` and `METADATA_RELAY_URL=http://relay:4001`.
  The seeding in `scripts/e2e/server-entrypoint.sh` runs as an `ExecStartPost`
  (or a oneshot ordered after the service) and writes the seeded marker.
- `client`: Xvfb and the Flutter toolchain, running
  `flutter test -d linux integration_test/all_tests.dart` against
  `player-codegen`'s tree with `player-p2p-so` in place. The logic of
  `scripts/e2e/run-tests.sh` moves into the `testScript`.

The `testScript` waits for the relay's `/health`, then the server's `/health`
and seeded marker, then runs the client. Service logs are collected into
`$out` on success and printed on failure.

The VM has no internet. iroh between client and server must work over direct
addresses with discovery off; spike 2 proves it. If it cannot, the `relay`
node also runs a local iroh relay and both ends are pointed at it.

Deleted: `ci-player-e2e.yml`, `compose.player-e2e.yml`,
`player/Dockerfile.test`, the `player-e2e-toolbox` image and its build cache
tag, and whatever under `scripts/e2e/` the NixOS test no longer reads.

## Android

`Build / Android` cannot be a derivation without a Gradle dependency lockfile
(nixpkgs `mitmCache`) refreshed on every Android dependency bump, and Flutter's
Android engine artifacts in the sandbox are unproven. It stays an ordinary job
and moves into `ci.yml`:

- It runs on every PR. No path filter, no stamp gate. (Since changed: a
  reference-free stamp derivation over its inputs now lets the plan skip it,
  and the free part of its dev shell is pushed; `.github/ci.md`, "Build /
  Android runs when its inputs change".)
- Its toolchain comes from `nix develop .#android` (Flutter, Android SDK, NDK,
  Rust with Android targets), substituted from niks3 and cache.nixos.org. This
  removes `subosito/flutter-action`, `actions/setup-java` and the runner's
  rustup.
- No `actions/cache`. pub and Gradle fetch on each run.
- `flutter build apk --release --target-platform android-arm,android-arm64`,
  `scripts/check-apk-abis.sh` and the `mydia-player-android-apk` artifact are
  unchanged.

## Workflow shape

The player checks join phase 1's `plan`/build matrix in `ci.yml`; the matrix
discovers them from `checks.x86_64-linux` with no further workflow change.

Required contexts keep their names as aggregators (`if: always()`, pass when
every needed result is `success` or `skipped`), so the Master ruleset needs no
edit once they move: `Test / Player`, `Build / Web`, `Build / Linux`,
`Check / Web icons`, `Test / Player E2E`, `Test / E2E Browser`,
`Build / Android`. The existing yq guard in `guards` enforces the `always()`
shape on them.

`ci-player.yml` keeps only the Windows and macOS build legs and Flatpak
metadata validation. Its `changes` job is replaced by workflow-level
`on.pull_request.paths: [player/**, ...]`, since those legs are outside this
migration and cost macOS/Windows minutes.

## Known costs

1. A player source change rebuilds `player-codegen` and every player check
   from scratch (no incremental `.dart_tool`).
2. Any change to server or player sources rebuilds the closure `player-e2e`
   needs. An unchanged closure is a cache hit, which today's pull path (about
   10 minutes on every PR) never was. `packages.default` takes the
   `mydiaPackage` file set of `nix/ci/sources.nix`, not the whole repository,
   so "server sources" means what the release reads (the Elixir app, assets,
   the NIF and plugin crates, the Cardigann guest directory); a docs, workflow,
   test or `design/` change leaves the package and `player-e2e` cached.
3. Android costs one full build on every PR, by design.
4. As in phase 1, a flaky check that passes once is cached as passed.

## Rollout

1. **Spike 1:** `player-linux` builds in the sandbox with a crane-built `.so`
   handed to cargokit.
2. **Spike 2:** a two-node `nixosTest` where a player client pairs with a
   server over iroh with no internet.
   Either spike failing reopens this spec before any PR.
3. **PR 1:** `player.nix` (all checks except `player-e2e`), `e2e-browser`, and
   Android in `ci.yml`. Old jobs stay required alongside the new aggregators
   for a few PRs; compare results and timings; then move the required contexts
   and delete the old jobs, the pub caches, the `changes` job and
   `setup-devenv` if nothing else uses it.
4. **PR 2:** `packages.metadata-relay` and `player-e2e`; then delete
   `ci-player-e2e.yml` and the files listed above.
5. Update `.github/ci.md`, `nix/ci/README.md`, `player/docs/` and
   `.github/ci-flakes.md`; mark phase 2 implemented in the phase 1 spec.

## Success criteria

- No `paths-filter`, `actions/cache`, `hashFiles`, `setup-devenv` or
  `subosito/flutter-action` in `ci.yml`, and none in what `ci-player.yml` keeps
  for Linux, web or Android (it keeps none of those jobs).
- A docs-only PR runs no player check, and a backend-only PR runs none
  except `player-e2e`, whose closure includes `packages.default`: each other
  player check is a cache hit.
  `Build / Android` runs anyway, by design.
- A player-only PR runs no Elixir check.
- `Test / Player E2E` wall clock is no worse than today's roughly 19 minutes on
  a backend PR; a full hit is under 2 minutes.
- `ci-player-e2e.yml` and `compose.player-e2e.yml` no longer exist.
