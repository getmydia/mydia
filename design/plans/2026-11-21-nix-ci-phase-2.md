# Nix-native CI (phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Linux, web and Android player jobs, the player E2E suite and the backend E2E Browser job onto phase 1's Nix CI, leaving no path filter, Actions cache or devenv setup in them.

**Architecture:** A new `nix/ci/player.nix` adds player derivations to the existing `ciChecks`/`ciInternal` options; `ci.yml`'s planner discovers them unchanged. `e2e-browser` joins `nix/ci/tests.nix`. The player E2E becomes a `nixosTest` in `nix/tests/player-e2e.nix` built on the existing NixOS module and a new `packages.metadata-relay`. Android stays an ordinary job in `devShells.android`.

**Tech Stack:** Nix flakes, flake-parts, `lib.fileset`, nixpkgs `flutter` (resolved by `player/flutter-version.nix`) with `buildFlutterApplication`'s pub hooks, crane, `pkgs.testers.nixosTest`, `beamPackages.mixRelease`, GitHub Actions.

**Spec:** `design/specs/2026-11-21-nix-ci-phase-2-design.md` (builds on `design/specs/2026-11-20-nix-ci-checks-design.md`)

## Global Constraints

- Every derivation `src` is a `lib.fileset` from `nix/ci/sources.nix` via `toSource`; never `src = ../..`.
- New checks go through the existing perSystem options `ciChecks` / `ciInternal`; Linux only, like phase 1.
- Flutter comes only from `import ../../player/flutter-version.nix { inherit pkgs; }`. No file may name a Flutter version (`Check / Flutter Pin`).
- Rust comes from `ci.rustToolchain` / `ci.craneLib`; rustup is never invoked in a check.
- Required contexts keep their names, each on one job with `if: always()` passing on `success`/`skipped`: `Test / Player`, `Build / Web`, `Test / Player E2E`, `Test / E2E Browser` (Master ruleset). Also keep `Build / Linux`, `Check / Web icons`, `Build / Android`.
- `--concurrency 1` stays on the very_good VM run; the TV-tier and web file lists still fail when empty.
- rustfs is `nix/ci/tests.nix`'s `rustfs` (same store path as devenv), on `127.0.0.1:9000`, credentials `mydia` / `mydia-dev-secret`.
- `ci.yml` and the Linux/web/Android jobs contain no `actions/cache`, `hashFiles`, `dorny/paths-filter`, `setup-devenv` or `subosito/flutter-action`.
- Never real movie or TV titles in fixtures or seed data. No em dashes in docs or comments.
- Commit with `git commit -F <msgfile>` from inside the worktree's direnv environment; verify with `git show --stat`.

## Review Focus

1. **A new player file lands outside every file set** (a new top-level dir under `player/`, a new asset). Expected: `ci-fileset-coverage` fails naming it, never a green skip. Pinned in Task 1 by adding the player dirs to `codeDirs` and a negative test.
2. **Dependabot bumps `pubspec.lock`.** Expected: `scripts/regenerate-derived.sh` rewrites `player/pubspec.lock.json` and `Check / Generated Freshness` fails if it was not. Pinned in Task 1.
3. **A test renamed so the `*_tv_test.dart` or `*_web_test.dart` glob matches nothing.** Expected: the check fails with the "expected at least one" message. Pinned in Tasks 4 and 5 by a negative run with an empty pattern.
4. **The crane `.so` and cargokit disagree** (cargokit silently rebuilding, or the bundle missing `libmydia_player_p2p.so`). Expected: `player-linux` fails if cargokit tries to invoke cargo/rustup or the `.so` is absent from `bundle/lib/`. Pinned in Task 2.
5. **Server never finishes seeding in the VM.** Expected: `player-e2e` fails within its wait timeout with relay and server journals printed, not a hang to the job timeout. Pinned in Task 9.

---

### Task 1: Player sources, pub cache and codegen

**Files:**
- Modify: `nix/ci/sources.nix`, `nix/ci/flake-module.nix` (`codeDirs` gains `player`; import `./player.nix`)
- Create: `nix/ci/player.nix`, `player/pubspec.lock.json`
- Modify: `scripts/regenerate-derived.sh`, `scripts/check-generated-freshness.sh`

**Interfaces:**
- Produces in `sources.nix`: `playerApp` (`player/` minus `build/ .dart_tool/ rust/ windows/ macos/ ios/ android/ flatpak/ appimage/ windows-vm-scripts/` and generated `*.g.dart *.freezed.dart`), `playerAndroid` (`player/android`), `playerOtherPlatforms` (the excluded platform dirs, so coverage holds). `player/rust/*` stays under `playerCrate`.
- Produces `ciInternal.player-pub-cache` (a `PUB_CACHE` dir) and `ciInternal.player-codegen` (the `playerApp` tree after `flutter pub get --offline --enforce-lockfile`, `flutter gen-l10n`, `dart run build_runner build`).
- Produces `_module.args.ciPlayer = { flutter, pubCache, codegen, mkPlayerCheck }`, where `mkPlayerCheck { name, nativeBuildInputs ? [], script }` is `mixLib.mkLogCheck`'s shape running in a writable copy of `codegen` with `PUB_CACHE` and `HOME` set, and every `flutter test` call passing `--test-randomize-ordering-seed 0` (the spec's determinism rule).

- [ ] **Step 1:** Add `player` to `codeDirs`, run `nix build .#checks.x86_64-linux.ci-fileset-coverage -L`. Expected: FAIL listing player files.
- [ ] **Step 2:** Add the three player sets to `sources.nix` and `all`. Re-run. Expected: PASS. Then `mkdir -p player/build && touch player/build/x.dart && git add -N -f player/build/x.dart` (tracked, but inside an excluded subtree). Expected: FAIL naming `player/build/x.dart`. Remove the probe.
- [ ] **Step 3:** Generate `player/pubspec.lock.json` with `yq -o json player/pubspec.lock` from `regenerate-derived.sh`; add the same comparison to `check-generated-freshness.sh`. Edit one version in the JSON and run the freshness script. Expected: FAIL naming `player/pubspec.lock.json`. Revert.
- [ ] **Step 4:** Implement `player-pub-cache` from `lib.importJSON ../../player/pubspec.lock.json` using nixpkgs' pub-deps fetcher (the one `buildFlutterApplication` uses for `pubspecLock`); `player-codegen` on top. Build both with `nix build .#ciInternal.player-codegen -L`. Expected: succeeds offline; `find result -name '*.freezed.dart' | head -1` prints a path.
- [ ] **Step 5:** Commit `ci(nix): player file sets, pub cache and codegen`.

### Task 2: `player-p2p-so` and `player-linux` (spike 1 gate)

**Files:**
- Modify: `nix/ci/player.nix`, `nix/ci/rust.nix` (expose the player crate's `cargoArtifacts` for reuse)
- Possibly modify: `player/rust_builder/cargokit/` build hook or `player/linux/CMakeLists.txt` (only the minimum to accept a prebuilt library)

**Interfaces:**
- Consumes: `ciPlayer.codegen`, `ci.craneLib`, `sources.playerCrate "mydia_player_p2p"`.
- Produces: `ciInternal.player-p2p-so` (`$out/lib/libmydia_player_p2p.so`, release profile); `ciChecks.player-linux` (`$out/bundle/` = `build/linux/x64/release/bundle`, plus `$out/log`).

- [ ] **Step 1:** Build `player-p2p-so` with crane. Run `nix build .#ciInternal.player-p2p-so && nm -D result/lib/libmydia_player_p2p.so | grep -c frb_`. Expected: non-zero.
- [ ] **Step 2:** Implement `player-linux`: `flutter build linux --release` in the sandbox with the `.so` handed to cargokit, plus a `PATH` shim where `cargo` and `rustup` exit 1 with `cargokit tried to build Rust in the sandbox`. Port the no-symlinks assertion from `ci-player.yml`'s "Assert Linux bundle has no symlinks" step. Fail if `bundle/lib/libmydia_player_p2p.so` is absent.
- [ ] **Step 3:** Run `nix build .#checks.x86_64-linux.player-linux -L`. Expected: PASS, `cmp result/bundle/lib/libmydia_player_p2p.so <(cat $(nix build --print-out-paths .#ciInternal.player-p2p-so)/lib/libmydia_player_p2p.so)` exits 0.
- [ ] **Step 4:** If no hand-off works without rewriting cargokit, stop and report: the spec's rollout says this reopens the spec. Record the mechanism used in a comment above `player-linux`.
- [ ] **Step 5:** Commit `ci(nix): player Linux bundle with a crane-built p2p library`.

### Task 3: Spike 2, iroh between VM nodes

**Files:**
- Create (throwaway, not committed to master): `nix/tests/spike-iroh.nix`

**Interfaces:**
- Consumes: `packages.default`, the NixOS module, `player-linux`'s bundle.

- [ ] **Step 1:** Two-node `nixosTest`: `server` runs the module with `ENABLE_REMOTE_ACCESS=true`, `PUBLIC_IP_ENABLED=false`; `client` runs a minimal Dart or Rust probe from `mydia_player_p2p` that dials the server's node ID with discovery off and the server's direct address passed in.
- [ ] **Step 2:** `nix build .#checks.x86_64-linux.spike-iroh -L`. Expected: the probe reports a connection. If it does not, add an iroh relay on the server node and retry; record which variant works.
- [ ] **Step 3:** Write the outcome (direct, or local relay with its config) into this plan's Task 9 Step 1 as a one-line note, delete the spike file, and commit the plan edit.

### Task 4: `player-analyze`, `player-l10n-test`, `player-icons`

**Files:**
- Modify: `nix/ci/player.nix`

**Interfaces:**
- Consumes: `ciPlayer.mkPlayerCheck`.
- Produces: `ciChecks.player-analyze`, `ciChecks.player-l10n-test`, `ciChecks.player-icons`.

- [ ] **Step 1:** Port, unchanged in meaning, `ci-player.yml`'s "Analyze localizations", "Analyze" and "Check @TestOn files are tagged out of the bundle" steps into `player-analyze`; "Test localizations" into `player-l10n-test`; `tool/gen-web-icons.sh --check` into `player-icons`. `git ls-files` becomes `find` over the source tree.
- [ ] **Step 2:** Build all three. Expected: PASS. Add an unused import to a scratch copy of a `lib/` file in a throwaway commit and build `player-analyze`. Expected: FAIL. Drop the commit.
- [ ] **Step 3:** Commit `ci(nix): player analyze, l10n and icon checks`.

### Task 5: `player-test`

**Files:**
- Modify: `nix/ci/player.nix`, `nix/ci/tests.nix` (export `rustfs` through `_module.args`)

**Interfaces:**
- Produces: `ciChecks.player-test`.

- [ ] **Step 1:** In `preCheck`, start `rustfs` on `127.0.0.1:9000` with data under `$TMPDIR` and wait for its port; set `MYDIA_TEST_S3_ENDPOINT=http://127.0.0.1:9000`, `MYDIA_TEST_S3_ACCESS_KEY_ID=mydia`, `MYDIA_TEST_S3_SECRET_ACCESS_KEY=mydia-dev-secret`.
- [ ] **Step 2:** Run `very_good test --concurrency 1` (very_good_cli fetched as a pinned Dart package in the pub cache, not `pub global activate`), then the TV-tier run with `--dart-define=MYDIA_FORCE_TV=true` over `find test -name '*_tv_test.dart'`, failing with `No test/**/*_tv_test.dart files matched; expected at least one.` when empty.
- [ ] **Step 3:** Build. Expected: PASS, and `grep -c 's3_integration_test' result/log` is non-zero with no "skip" for it. Then override the glob to `*_nope_test.dart`. Expected: FAIL with the message above. Restore.
- [ ] **Step 4:** Commit `ci(nix): player VM, TV-tier and S3 tests`.

### Task 6: `player-test-web` and `player-web`

**Files:**
- Modify: `nix/ci/player.nix`

**Interfaces:**
- Produces: `ciChecks.player-test-web`; `ciChecks.player-web` (`$out/web/` bundle).

- [ ] **Step 1:** `player-test-web`: `CHROME_EXECUTABLE=${pkgs.chromium}/bin/chromium`, `flutter test --platform chrome` over `find test -name '*_web_test.dart'`, empty-list failure as in Task 5.
- [ ] **Step 2:** `player-web`: the same flags `ci-player.yml`'s "Build the web bundle" step uses (`MYDIA_WEB_P2P=true`, no wasm module), then its "Check _headers survived the build" step.
- [ ] **Step 3:** Build both. Expected: PASS; `test -f result/web/_headers`.
- [ ] **Step 4:** Commit `ci(nix): player browser tests and web bundle`.

### Task 7: `e2e-browser`

**Files:**
- Modify: `nix/ci/tests.nix`, `nix/ci/sources.nix` (an `assets` set: `assets/` minus `node_modules`)
- Modify: `.github/workflows/ci.yml` (delete the `test-e2e` devenv job; `Test / E2E Browser` needs the Nix result)
- Delete: `.github/actions/setup-devenv/` (no other user, confirmed by `grep -rn setup-devenv .github`)

**Interfaces:**
- Consumes: `ciInternal.mydiaTestBuild-sqlite`, `ciElixir.env`, `ciElixir.copyBuild`, the `npmDeps` hash already in `nix/packages/flake-module.nix`.
- Produces: `ciInternal.assets` (built `priv/static/assets`), `ciChecks.e2e-browser` (`$out/log`).

- [ ] **Step 1:** `ciInternal.assets`: `npm ci --offline` from the existing `npmDeps`, then `mix assets.deploy` against the copied test build.
- [ ] **Step 2:** `e2e-browser`: copy the test build, install assets, run `./scripts/run-feature-tests.sh` with `chromium` and `CHROMEDRIVER_PATH=${pkgs.chromedriver}/bin/chromedriver`, env from `ciElixir.env` only. On failure copy `tmp/wallaby_screenshots/` to `$TMPDIR/wallaby-screenshots` and print the path.
- [ ] **Step 3:** Build. Expected: PASS. Break one feature-test assertion in a throwaway commit. Expected: FAIL with the screenshot path printed. Drop it.
- [ ] **Step 4:** In the build matrix job, on failure of `e2e-browser`, re-run it with `--keep-failed` and upload `wallaby-screenshots` from the kept build dir. Delete the devenv job and `setup-devenv`.
- [ ] **Step 5:** Commit `ci(nix): E2E Browser as a sandboxed check; drop setup-devenv`.

### Task 8: Workflow cut-over for PR 1

**Files:**
- Modify: `.github/workflows/ci.yml`, `.github/workflows/ci-player.yml`
- Modify: `.github/ci.md`, `nix/ci/README.md`, `player/docs/` (CI section), `.github/ci-flakes.md`

**Interfaces:**
- Consumes: every check from Tasks 2 and 4 to 7.

- [ ] **Step 1:** In `ci.yml`, add aggregators named `Test / Player`, `Build / Web`, `Build / Linux`, `Check / Web icons` that need `nix-result`, `if: always()`, with the existing `jq` all-success-or-skipped body. On master, upload `player-linux`'s bundle as `mydia-player-linux-bundle`.
- [ ] **Step 2:** Add `build-android` (`Build / Android`) to `ci.yml`: checkout, the `nix-ci` action, then `nix develop .#android --command bash -c` running `flutter pub get --enforce-lockfile`, `dart run build_runner build`, `flutter build apk --release --target-platform android-arm,android-arm64` in `player/`; then `scripts/check-apk-abis.sh` and the `mydia-player-android-apk` upload. No cache steps.
- [ ] **Step 3:** Run `actionlint` and `nix build .#checks.x86_64-linux.guards -L`. Expected: both PASS (the yq guard sees `always()` on the new aggregators).
- [ ] **Step 4:** Open PR 1 with the old `ci-player.yml` jobs still present under temporary names (`Old / ...`) so both run. After a few PRs agree, rename: delete `test-player`, `build-web`, the Linux matrix leg, `build-android`, `icons` and `changes` from `ci-player.yml`; give it `on.pull_request.paths: ['player/**', '.github/workflows/ci-player.yml']` for the remaining Windows/macOS/Flatpak jobs.
- [ ] **Step 5:** `grep -nE 'actions/cache|hashFiles|paths-filter|setup-devenv|subosito' .github/workflows/ci.yml` prints nothing; the same grep on `ci-player.yml` only matches Windows/macOS steps.
- [ ] **Step 6:** Update the docs listed above: the derivation graph gains the player and E2E nodes; the setup-devenv and pub-cache sections go. Commit `ci: player and E2E Browser on Nix CI`.

### Task 9: `packages.metadata-relay` and `player-e2e`

**Files:**
- Modify: `nix/packages/flake-module.nix` (add `metadata-relay`), `nix/checks/flake-module.nix` (add `player-e2e` to `checks` on x86_64-linux)
- Create: `nix/tests/player-e2e.nix`
- Modify: `scripts/e2e/seed.sh` only if it assumes the Docker paths

**Interfaces:**
- Consumes: `ciInternal.relayDepsCompiled` deps source, `packages.default`, `self.nixosModules.default`, `ciChecks.player-linux`, `ciInternal.player-codegen`, `ciInternal.player-pub-cache`.
- Produces: `packages.x86_64-linux.metadata-relay`, `checks.x86_64-linux.player-e2e`.

- [ ] **Step 1:** Spike 2 outcome: direct works with no relay node and no code change. A production `Host::new` client (the player's config, discovery and default relays left on but unreachable) dialing an `EndpointAddr` with only the server's node ID and `192.168.1.2:4100` reached the module-run server (`ENABLE_REMOTE_ACCESS=true`, `PUBLIC_IP_ENABLED=false`, `P2P_BIND_PORT=4100`, UDP 4100 open in the firewall) over a `Direct` path in 10 ms; expect the server's `Ready` and published node address only after its 30 s relay wait. Build `packages.metadata-relay` as a `mixRelease` of `metadata-relay/` with the BEAM pin `nix/ci/relay.nix` uses. `nix build .#metadata-relay && result/bin/metadata_relay version`. Expected: prints a version.
- [ ] **Step 2:** Write `player-e2e.nix` with nodes `relay` (env `PORT=4001`, `SQLITE_DB_PATH=/var/lib/relay/relay.db`, `RENDEZVOUS_MASTER_PEPPER=test-pepper-not-for-production`, dashboard `admin`/`admin`), `server` (module with `E2E_MODE=true`, `ENABLE_REMOTE_ACCESS=true`, `METADATA_RELAY_URL=http://relay:4001`, `PUBLIC_IP_ENABLED=false`, `DIRECT_URLS_USE_HTTP=true`, admin `admin@test.local`/`testpassword123`, seeding via `scripts/e2e/seed.sh` as a oneshot after the service writing the seeded marker) and `client` (Xvfb, Flutter, the codegen tree, the pub cache, `player-p2p-so`). The `testScript` waits for relay `/health`, server `/health` and `scripts/e2e/assert-seeded.sh` with a 300 s cap, then runs `flutter test -d linux integration_test/all_tests.dart` as `run-tests.sh` does; on any failure it prints `journalctl -u` of both services.
- [ ] **Step 3:** `nix build .#checks.x86_64-linux.player-e2e -L`. Expected: PASS. Then set the server's `E2E_MODE=false` in a throwaway edit. Expected: FAIL within the 300 s cap with both journals printed. Revert.
- [ ] **Step 4:** Commit `ci(nix): player E2E as a NixOS VM test`.

### Task 10: Cut-over for PR 2

**Files:**
- Modify: `.github/workflows/ci.yml` (`Test / Player E2E` aggregator needing `nix-result`)
- Delete: `.github/workflows/ci-player-e2e.yml`, `compose.player-e2e.yml`, `player/Dockerfile.test`, `scripts/e2e/server-entrypoint.sh` and `scripts/e2e/run-tests.sh` if `player-e2e.nix` no longer reads them
- Modify: `nix/ci/guards.nix` (drop references to `ci-player-e2e.yml` in the BUILD_COMMIT guard message), `.github/ci.md`, `nix/ci/README.md`, `player/docs/`, `design/specs/2026-11-20-nix-ci-checks-design.md` and `design/specs/2026-11-21-nix-ci-phase-2-design.md` (status: implemented)

- [ ] **Step 1:** Open PR 2 with `ci-player-e2e.yml`'s job renamed `Old / Player E2E` alongside the new aggregator; after a few agreeing runs, delete the files listed above.
- [ ] **Step 2:** `rg -n 'ci-player-e2e|compose.player-e2e|Dockerfile.test|player-e2e-toolbox' --hidden -g '!design/**'` prints nothing.
- [ ] **Step 3:** Commit `ci: retire the Docker player E2E workflow`.
