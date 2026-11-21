# Nix-native CI (phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Express every Linux backend check in `ci.yml`, `ci-server.yml`, `ci-relay.yml` and `ci-nix.yml`'s VM tests as a flake check, and run CI as a planner plus a matrix that builds only uncached checks, with niks3 as the binary cache.

**Architecture:** New flake-parts module `nix/ci/` defines source file sets, shared derivations (Mix deps, NIFs, wasm plugins, test builds, PLT) and `checks.x86_64-linux.*`. A composite action installs Nix with `cache.mydia.dev` as substituter and pushes through niks3 with GitHub OIDC. `ci.yml` becomes `plan` → `build` matrix → aggregators.

**Tech Stack:** Nix flakes, flake-parts, `lib.fileset`, crane (Rust), nixpkgs `beamPackages` + existing `deps.nix` (mix2nix), `nix-eval-jobs`, niks3 v1.19.0 CLI, GitHub Actions.

**Spec:** `design/specs/2026-11-20-nix-ci-checks-design.md`

## Global Constraints

- Substituter `https://cache.mydia.dev`, public key `cache.mydia.dev-1:5zkoQR4Gcrx1EEQ1GvHRPQ7EoHm8gNrrVoeAqX3ioFg=`. Keep `cache.nixos.org` and Cachix `devenv` as read-only substituters.
- niks3 server `https://niks3.mydia.dev`, OIDC audience `https://niks3.mydia.dev` (URL-encoded in the token request). Jobs that push need `permissions: id-token: write`.
- Push failures warn (`::warning::`) after 3 attempts; they never fail a job.
- Master pushes pin with `niks3 push --pin master-<check>`; PRs never pin.
- Required check names unchanged: `Test`, `Test / PostgreSQL`, `Test / E2E Browser`, each on one job with `if: always()`.
- Every derivation `src` is a `lib.fileset`; never `src = ../..`.
- Toolchain comes from the flake's existing pins: Elixir/OTP from `.elixir-version`/`.otp-version` as `nix/packages/flake-module.nix` already resolves them, Rust from `rust-toolchain.toml` via rust-overlay.
- ExUnit runs with `--seed 0` in sandboxed checks.
- `config/runtime.exs` keeps everything that varies per shard (partition DB names); `config/test.exs` must not gain per-run values (see `.github/ci.md`, the 1455-file recompile).
- Migrated workflows contain no `actions/cache`, `hashFiles`, or `dorny/paths-filter`.
- No em dashes in docs or comments.

## Review Focus

1. **A file the build reads is missing from a file set.** Expected: the check fails in the sandbox with a missing-file error, never passes. Pinned by Task 1's `ci-fileset-coverage` check, which compiles with the narrowest set and fails if `git ls-files` shows a file under `lib/`, `config/`, `priv/`, `test/`, `native/`, `plugins/` that no set covers.
2. **PR changes `mix.lock` without regenerating `deps.nix`.** Expected: eval fails with the existing freshness message, not a confusing build error. Pinned in Task 3 (eval-time assertion reusing `check-generated-freshness.sh`'s comparison).
3. **Cardigann guest source changed, release not published yet.** Expected: `:cardigann_wasm` tests excluded with the existing skip message, same as today. Pinned in Task 6.
4. **niks3 unreachable or OIDC refused.** Expected: build job green with a warning; next run rebuilds. Pinned in Task 8 by running the push step against `https://niks3.invalid` in the action's self-test.
5. **Fork PR.** Expected: no OIDC token; substitution works, push step skipped with a notice, not an error. Pinned in Task 8 (`if: github.event.pull_request.head.repo.full_name == github.repository`).

---

### Task 1: CI flake module and source file sets

**Files:**
- Create: `nix/ci/flake-module.nix`, `nix/ci/sources.nix`, `nix/ci/README.md`
- Modify: `flake.nix` (import `./nix/ci/flake-module.nix`; add input `crane.url = "github:ipetkov/crane"`)
- Modify: `nix/checks/flake-module.nix` (drop `package`/`package-postgres` from `checks`; the VM tests already build them)

**Interfaces:**
- Produces: `nix/ci/sources.nix` returning an attrset of file sets, called as `import ./sources.nix { lib; root = ../..; }`:
  `elixirApp` (`mix.exs mix.lock .formatter.exs .credo.exs config/ lib/ priv/` minus `priv/native priv/plugins/*.wasm priv/static/assets`), `elixirTest` (`test/`), `gettext` (`priv/gettext/`), `patches`, `nativeCrate name` (`native/<name>` plus `native/mydia_p2p_core` for p2p, `rust-toolchain.toml`, `rust-lints.toml`), `plugins` (`plugins/ native/mydia_plugin_sdk native/mydia_plugin_macros`), `server` (`server/`), `relay` (`metadata-relay/` minus `_build deps`), `toSource set` helper.
- Produces: `perSystem` `_module.args.ci` = `{ sources, rustToolchain, beamPackages, craneLib }` for the other `nix/ci/*.nix` files.

- [ ] **Step 1:** Write `checks.ci-fileset-coverage`: a `runCommand` that receives `git ls-files` output captured at eval time via `lib.fileset.toList` of `lib.fileset.gitTracked ../..`, and fails listing every tracked path under `lib/ config/ priv/ test/ native/ plugins/ server/ metadata-relay/` not in the union of the sets above (allowlist: `*.md`).
- [ ] **Step 2:** Run `nix build .#checks.x86_64-linux.ci-fileset-coverage -L`. Expected: FAIL while `sources.nix` is empty.
- [ ] **Step 3:** Implement `sources.nix` and the module wiring.
- [ ] **Step 4:** Run the check again. Expected: PASS. Then `touch priv/static/assets/x.js && git add -N -f priv/static/assets/x.js` (a tracked file inside an excluded subtree): Expected FAIL naming it. Remove it.
- [ ] **Step 5:** `nix eval .#checks.x86_64-linux --apply builtins.attrNames` lists `ci-fileset-coverage nixos-module nixos-module-postgres`.
- [ ] **Step 6:** Commit `ci(nix): CI flake module and source file sets`.

### Task 2: Rust checks with crane

**Files:**
- Create: `nix/ci/rust.nix`
- Modify: `scripts/check-rust.sh`, `scripts/check-plugins.sh` (header comment: the crate list is mirrored in `nix/ci/rust.nix`; Task 10's guard enforces it)

**Interfaces:**
- Consumes: `ci.sources.nativeCrate`, `ci.sources.plugins`, `ci.sources.server`, `ci.craneLib`.
- Produces: `mkRustChecks { name, src, cargoLock, testArgs ? "", clippyArgs ? "--all-targets --all-features -- -D warnings" }` returning `{ "rust-${name}-fmt"; "rust-${name}-clippy"; "rust-${name}-test"; }`, sharing one `buildDepsOnly` per crate. Checks: one triple per crate in `native/*` except `cardigann_guest`, `player/rust/mydia_smb`, `player/rust/mydia_player_p2p`, `server` (as `server`); plus `rust-p2p-core-wasm` (build + clippy `--target wasm32-unknown-unknown --no-default-features`) and `rust-plugins` (runs `scripts/check-plugins.sh` and `scripts/test-plugins.sh` with vendored deps). Test feature args copied from `ci.yml` lines 583-612 (`--features test-introspection` for `mydia_p2p_core` and `mydia_smb`).
- Produces: `nifs = { mydia_p2p = <drv with lib/libmydia_p2p.so>; mydia_subsync = ...; }` and `pluginWasm = <drv with plex.wasm simkl_sync.wasm webhook_notifier.wasm>`, built with the same `cargoArtifacts`.

- [ ] **Step 1:** Implement `mkRustChecks` and the crate list.
- [ ] **Step 2:** `nix build .#checks.x86_64-linux.rust-mydia_subsync-test -L`. Expected: PASS, test count equal to `cargo test` in devenv.
- [ ] **Step 3:** Insert a stray space in `native/mydia_media_names/src/lib.rs`; `nix build .#checks.x86_64-linux.rust-mydia_media_names-fmt`. Expected: FAIL naming the file. Revert.
- [ ] **Step 4:** Build every `rust-*` check and `server-*` with `nix build $(nix eval --raw .#ciRustAttrs)` (expose a helper list). Expected: all PASS.
- [ ] **Step 5:** Commit `ci(nix): Rust crates, NIFs and plugin wasm as crane checks`.

### Task 3: Mix deps for the test env

**Files:**
- Create: `nix/ci/mix-deps.nix`
- Modify: `nix/packages/flake-module.nix` (factor `heroicons` and `mixNixDeps` overrides into a shared `let` the CI module imports; no behaviour change for the package)

**Interfaces:**
- Consumes: `deps.nix` sources (`pkg.src` for each entry), `heroicons`, `ci.sources.patches`.
- Produces: `mixDepsSrc` (a `deps/` tree: each package's `src` copied to `deps/<name>`, `deps/heroicons`, then `@dep_patches` from `mix.exs` applied with `patch -p1`), and `mixDepsCompiled { databaseType ? null }`: `deps/` plus `_build/test/lib/<dep>` from `MIX_ENV=test mix deps.compile` with `HEX_OFFLINE=1`, `MIX_REBAR3`, and `DATABASE_TYPE` set when non-null.

- [ ] **Step 1:** Add an eval-time assertion in `mix-deps.nix` that every package in `mix.lock` (parsed with the same regex as `scripts/check-generated-freshness.sh:176`) has a `deps.nix` entry of the same version; message: `deps.nix is stale: run mix2nix > deps.nix (missing: <names>)`.
- [ ] **Step 2:** Change one version string in `mix.lock`, run `nix eval .#checks.x86_64-linux --apply builtins.attrNames`. Expected: eval error with that message. Revert.
- [ ] **Step 3:** Implement `mixDepsSrc` and `mixDepsCompiled`.
- [ ] **Step 4:** `nix build .#ciInternal.mixDepsCompiled-sqlite -L`. Expected: `_build/test/lib/` holds every dep in `mix.lock` that is `only: :test` or unrestricted; `deps/wasmex` contains the patched file from `patches/wasmex/`.
- [ ] **Step 5:** Commit `ci(nix): test-env Mix deps from deps.nix`.

### Task 4: App test build and lint checks

**Files:**
- Create: `nix/ci/elixir.nix`
- Modify: `config/config.exs` (move the `MYDIA_PREBUILT_NIFS` block from `config/prod.exs:24-27` here so it applies in every env); `config/prod.exs` (remove it)

**Interfaces:**
- Consumes: `mixDepsCompiled`, `nifs`, `pluginWasm`, `ci.sources.elixirApp`, `ci.sources.gettext`.
- Produces: `mydiaTestBuild { databaseType ? null }` (`_build/test` + `deps/` + `priv/native/*.so` + `priv/plugins/*.wasm`, compiled with `mix compile --warnings-as-errors`, `MYDIA_PREBUILT_NIFS=1`, `MYDIA_PREBUILT_PLUGINS=1`); checks `elixir-format` (`mix format --check-formatted`, needs only sources + deps), `elixir-lint` (the guard greps from `ci.yml:334-362` verbatim, `mix deps.unlock --check-unused`, `mix credo --strict`, `mix gettext.extract --check-up-to-date`), `dialyzer-plt` (internal) and `dialyzer` (`mix dialyzer --format github`, PLT copied to a writable `priv/plts`).

- [ ] **Step 1:** Build `elixir-format` after adding a mis-indented line to `lib/mydia.ex`. Expected: FAIL. Revert; expected PASS.
- [ ] **Step 2:** Implement `mydiaTestBuild`; build `-sqlite`. Expected: log shows NIFs loaded from `priv/native`, no cargo invocation, no "Compiling" of deps.
- [ ] **Step 3:** Add `@dialyzer :no_return` to a module in `lib/`; build `elixir-lint`. Expected: FAIL with the `@dialyzer attributes are not allowed` message. Revert.
- [ ] **Step 4:** Build `dialyzer`. Expected: PASS; rebuild after touching only `test/` is a cache hit (`nix build --dry-run` prints nothing to build).
- [ ] **Step 5:** `./dev mix test test/mydia/p2p_test.exs` still passes locally (the config move must not change dev/test NIF loading when the env var is unset).
- [ ] **Step 6:** Commit `ci(nix): app test build, format, lint and Dialyzer checks`.

### Task 5: Sandboxed test shards

**Files:**
- Create: `nix/ci/tests.nix`
- Modify: `test/README.md` (new section "Sandboxed CI runs": no network, `--seed 0`, how to reproduce a shard with `nix build .#checks.x86_64-linux.test-sqlite-2 -L`)

**Interfaces:**
- Consumes: `mydiaTestBuild`, `ci.sources.elixirTest`, `pkgs.rustfs` overridden as in `devenv.nix:161`, `pkgs.postgresql_17`.
- Produces: checks `test-sqlite-{1..4}`, `test-postgres-{1..3}` via `mkShard { databaseType, partitions, partition }`. `preCheck`: start rustfs on `127.0.0.1:9000` with the `MYDIA_TEST_S3_*` values from `devenv.nix:299-302`, set `MYDIA_TEST_S3_REQUIRED=1`; for postgres, `initdb` in `$TMPDIR/pg`, start on a unix socket, export `DATABASE_TYPE=postgres DATABASE_HOST=$TMPDIR/pg DATABASE_USER=$(whoami) DATABASE_NAME=mydia_test`. Then `mix ecto.create && mix ecto.migrate && mix test --partitions N --warnings-as-errors --seed 0`, with `MIX_TEST_PARTITION=<n>`. `$out` gets `test.log`.

- [ ] **Step 1:** Implement `mkShard`; build `test-sqlite-1`. Expected: PASS, or failures limited to tests that touch the network or `$HOME`. List them.
- [ ] **Step 2:** For each listed test: fix it to use Bypass/`System.tmp_dir!` if the dependency is incidental; otherwise tag `@tag :external` (already excluded). Record each in the commit message.
- [ ] **Step 3:** Build all seven shards. Expected: PASS, and the per-shard test counts sum to the counts from the last green master run of `ci.yml` (from `gh run view --log`, the `N tests, 0 failures` lines).
- [ ] **Step 4:** Add a failing `assert false` test; build `test-sqlite-*`. Expected: exactly one shard FAILS and the others PASS. Revert; rebuilding is a cache hit for nothing under `test-sqlite-*` (all shards share `test/`, spec Known costs 3) but a hit for `mydiaTestBuild-sqlite`.
- [ ] **Step 5:** Commit `ci(nix): sandboxed SQLite and PostgreSQL test shards`.

### Task 6: Cardigann guest pin

**Files:**
- Create: `nix/ci/cardigann-guest.json` (`{ "source_hash": "...", "url": "...", "sha256": "..." }`)
- Create: `scripts/update-cardigann-guest-pin.sh` (reads `mix mydia.cardigann_guest hash`, resolves the `cardigann-guest-<hash>` release asset with `gh release view`, writes the JSON)
- Modify: `nix/ci/tests.nix`; `.github/workflows/cardigann-guest.yml` (after publishing, open a commit updating the pin via the same script, using the existing Dependabot-fixup bot pattern)

**Interfaces:**
- Produces: `cardigannGuest` = `fetchurl` of the pinned asset, placed where `mix mydia.cardigann_guest fetch` would put it (`target()` in `lib/mix/tasks/mydia.cardigann_guest.ex`), only when the pin's `source_hash` equals a hash computed at eval time over `native/cardigann_guest/` using the same inputs as `Artifact.source_hash/0`. Otherwise the guest is absent and `test_helper.exs` excludes `:cardigann_wasm`.

- [ ] **Step 1:** Write a Nix unit check `ci-cardigann-hash` asserting the eval-time hash equals `mix mydia.cardigann_guest hash` output for the current tree (run the mix task inside the check against `mydiaTestBuild`).
- [ ] **Step 2:** Implement, run the script, commit the pin. Build `test-sqlite-*`. Expected: logs contain no `cardigann_wasm tests skipped`.
- [ ] **Step 3:** Change a comment in `native/cardigann_guest/`. Expected: shards log `cardigann_wasm tests skipped` and pass.
- [ ] **Step 4:** Commit `ci(nix): pin the Cardigann guest for sandboxed tests`.

### Task 7: Relay check

**Files:**
- Create: `metadata-relay/deps.nix` (generated: `cd metadata-relay && mix2nix > deps.nix`), `nix/ci/relay.nix`
- Modify: `scripts/check-generated-freshness.sh` (run the existing `deps.nix` vs `mix.lock` comparison for `metadata-relay/` too); `.github/workflows/dependabot-fixup.yml` (regenerate `metadata-relay/deps.nix` where it regenerates `deps.nix`)

**Interfaces:**
- Produces: check `relay-test`: deps from `metadata-relay/deps.nix`, `mix deps.unlock --check-unused`, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix ecto.create && mix ecto.migrate`, `mix test --warnings-as-errors --seed 0` (database setup copied from `ci-relay.yml:25-68`).

- [ ] **Step 1:** Generate `deps.nix`; run `scripts/check-generated-freshness.sh`. Expected: PASS; then bump a relay dep in `mix.lock` only: Expected: FAIL naming `metadata-relay/deps.nix`. Revert.
- [ ] **Step 2:** Implement and build `relay-test`. Expected: same test count as the last `Relay / Test` run.
- [ ] **Step 3:** Commit `ci(nix): metadata-relay test check`.

### Task 8: Nix CI composite action and niks3 push

**Files:**
- Create: `.github/actions/nix-ci/action.yml`, `.github/actions/nix-ci/push.sh`, `.github/actions/nix-ci/niks3-token.sh`

**Interfaces:**
- Produces: composite action inputs `push` (bool), `pin` (string, optional); outputs nothing. Steps: free disk (as in the user's nixos `build.yml`), `cachix/install-nix-action` with `extra-substituters = https://cache.mydia.dev https://devenv.cachix.org`, matching trusted keys, `max-jobs = auto`; install `niks3` from `github:Mic92/niks3/v1.19.0`.
- Produces: `push.sh <out-paths...>`: no-op with `::notice::` when `ACTIONS_ID_TOKEN_REQUEST_URL` is unset; otherwise up to 3 `niks3 push --server-url "${NIKS3_URL:-https://niks3.mydia.dev}" --auth-token-script niks3-token.sh [--pin "$PIN"]` attempts, then `::warning::` and exit 0.
- Produces: `niks3-token.sh`: prints `{"token": ...}` from the Actions OIDC endpoint with audience `https%3A%2F%2Fniks3.mydia.dev`, as in `/home/arosenfeld/Code/nixos/.github/workflows/build.yml:165-172`.

- [ ] **Step 1:** Write `.github/actions/nix-ci/push.test.sh` (bash, no network): unset `ACTIONS_ID_TOKEN_REQUEST_URL` → exit 0 with notice; set it and `NIKS3_URL=https://niks3.invalid` with a stub `niks3` on `PATH` that exits 1 → exit 0, 3 attempts, one `::warning::`.
- [ ] **Step 2:** Run it. Expected: FAIL (script missing). Implement. Run. Expected: PASS. Add it to `ci-nix.yml`'s Repo Contracts job.
- [ ] **Step 3:** Commit `ci: nix-ci composite action with niks3 OIDC push`.

### Task 9: Planner workflow running alongside the old jobs

**Files:**
- Create: `.github/workflows/ci-nix-checks.yml`, `scripts/ci-plan.sh`

**Interfaces:**
- Consumes: `.github/actions/nix-ci`.
- Produces: `scripts/ci-plan.sh` → JSON `{"inputs":[...],"checks":[...]}` on stdout. Runs `nix-eval-jobs --flake .#checks.x86_64-linux --check-cache-status --force-recurse`, keeps entries whose `cacheStatus` is not `cached`. `inputs` = uncached derivations referenced by 2+ uncached checks, from `nix-store -q --references` of each check `.drv`, limited to the `ciInternal` set (`mydiaTestBuild-*`, `mixDepsCompiled-*`, `dialyzer-plt`, `nifs.*`, `pluginWasm`).
- Produces jobs: `plan` → `inputs` (matrix over `inputs`, push, pin on master) → `checks` (matrix over `checks`, `needs: [plan, inputs]`, `if: always() && needs.plan.result == 'success'`) → `nix-result` aggregator named `Nix / Checks` (fails unless `checks` and `inputs` are `success` or `skipped`). Permissions: `contents: read`, `id-token: write`. Concurrency group per ref, cancel-in-progress on PRs.

- [ ] **Step 1:** Write `scripts/tests/ci-plan-test.sh` with a fixture `nix-eval-jobs` JSONL (stubbed on `PATH`) of 3 checks, 2 cached; expected output lists the one uncached check and no inputs.
- [ ] **Step 2:** Run. Expected: FAIL. Implement `ci-plan.sh`. Expected: PASS. Register the test in `ci-nix.yml` Repo Contracts.
- [ ] **Step 3:** Add the workflow; push the branch; open the PR (not draft). Expected first run: all checks build, `Nix / Checks` green, `niks3 push` succeeds (look for `Upload complete` in logs), the old jobs still run and stay required.
- [ ] **Step 4:** Re-run the workflow with no changes. Expected: `plan` emits empty matrices, total wall clock under 2 minutes.
- [ ] **Step 5:** Push a commit touching only `docs/`. Expected: same as Step 4. Push a commit touching `native/mydia_subsync/src/lib.rs` (comment): only `rust-mydia_subsync-*`, `nifs.mydia_subsync`, `mydiaTestBuild-*` and its dependents rebuild.
- [ ] **Step 6:** Commit `ci: plan/build/push workflow for flake checks`.

### Task 10: Cutover

**Files:**
- Modify: `.github/workflows/ci.yml` (delete `changes`, `lint`, `test-sqlite`, `test-postgres`, `dialyzer`, `rust`, `translations`, `cache-prune`; move the pure-file guard steps of `guards` into a `guards` flake check in `nix/ci/guards.nix`, keep `guards` steps that need Docker/`yq` on workflows; add `ratchet` job per spec; re-point `Test` to need `nix-checks` result jobs for `elixir-*`, `test-sqlite-*`, `dialyzer`, `rust-*`, `guards`; `Test / PostgreSQL` to `test-postgres-*`; `Test / E2E Browser` unchanged)
- Modify: `.github/workflows/ci-nix-checks.yml` (fold into `ci.yml` as jobs `plan`/`inputs`/`checks`; emit per-group result outputs so aggregators can filter: `checks` matrix entries carry `group: sqlite|postgres|lint|rust|relay|server|nixos`)
- Modify: `.github/workflows/ci-server.yml` (delete), `.github/workflows/ci-relay.yml` (delete `test` job; `docker`/`publish` keep their path filter: they build images, not checks), `.github/workflows/ci-nix.yml` (delete the two NixOS module jobs)
- Modify: `.github/actions/setup-devenv/action.yml` (delete every cache step and the `cargo-cache`/`elixir-caches`/`build-cache-prefix` inputs; remaining callers: `ratchet`, `test-e2e`)
- Modify: `.github/ci.md` (replace "The Nix jobs run on pull requests only when flake.lock changes", "ci.yml: path gate, shards and aggregators" cache paragraphs, and "The Dialyzer job" cache text with: the derivation graph, how to read the plan job, how to reproduce a check locally, niks3 operations pointing at `infra/kubernetes/apps/nix-cache/README.md`); `nix/ci/README.md` (same graph, for contributors)
- Create: `devShells.ci` in `nix/ci/flake-module.nix` (Elixir, OTP, Rust toolchain, git; used by `ratchet`, which runs `nix build .#ciInternal.mydiaTestBuild-sqlite`, copies `_build` and `deps/` into the workspace, then `nix develop .#ci -c mix mydia.ratchet --from-git-merge-base origin/master`, plus the master-push-only `UNUSED_CHECK=true mix compile --force || true`)
- Create: `nix/ci/guards.nix` plus check `ci-crate-list` (fails if `scripts/check-rust.sh`'s manifest glob and `nix/ci/rust.nix`'s crate list differ)

- [ ] **Step 1:** Build `guards` and `ci-crate-list`. Expected: PASS; add a fake `native/zz_test/Cargo.toml`: `ci-crate-list` FAILS naming it. Remove.
- [ ] **Step 2:** Apply the workflow edits. Run the `Guard the required-check aggregators` yq step locally against the new `ci.yml`. Expected: PASS.
- [ ] **Step 3:** `grep -nE 'actions/cache|hashFiles|paths-filter' .github/workflows/ci.yml .github/workflows/ci-relay.yml .github/actions/setup-devenv/action.yml`. Expected: only `ci-relay.yml`'s docker/publish path filter.
- [ ] **Step 4:** Push; confirm on the PR that `Test`, `Test / PostgreSQL`, `Test / E2E Browser` are green and fed by the new jobs. Ask the user to confirm the Master ruleset needs no change (names unchanged).
- [ ] **Step 5:** Commit `ci: cut over to flake checks; remove path filters and Actions caches`. After merge, watch master's first run: pins created (`kubectl --context k3s-can1 -n nix-cache exec deploy/niks3-postgres -- psql -U niks3 -c 'select count(*) from pins'` > 0) and `gh api repos/getmydia/mydia/actions/cache/usage` trending down.
