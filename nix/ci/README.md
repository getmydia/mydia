# Nix-native CI

CI checks are flake derivations, built with `nix build` and cached in the
niks3 binary cache. Design: `design/specs/2026-11-20-nix-ci-checks-design.md`.

## Layout

- `flake-module.nix`: the flake-parts module. It exposes
  `legacyPackages.<system>.ciInternal` (internal derivations such as compiled
  dependencies and NIFs, built with `nix build .#ciInternal.<name>`) and
  `legacyPackages.<system>.ciRustAttrs` (the list of Rust check names), fed
  by the mergeable perSystem options `ciInternal` and `ciRustAttrs` that the
  other `nix/ci/*.nix` modules set. Those modules put their checks in
  `ciChecks`, which this module exposes as `checks` on Linux only: the
  checks rely on the Linux sandbox's `/build/source`, so a Darwin
  `nix flake check` sees none of them and no `ciInternal`. It also passes
  `ci = { sources, rustToolchain, beamPackages, craneLib }` to them through
  `_module.args`. `ci.rustToolchain` is the CI toolchain (the
  `rust-toolchain.toml` version with clippy, rustfmt and the wasm targets),
  and `ci.craneLib` is crane on that toolchain. It also defines
  `devShells.ci`, the shell of the two CI jobs that run outside the
  sandbox (below).
- `sources.nix`: the `lib.fileset` source sets (`elixirApp`, `mixProject`, `elixirTest`,
  `gettext`, `patches`, `nativeCrate`, `playerCrate`, `plugins`,
  `pluginsExtra`, `server`, `relay`) and the `toSource` helper.
- `rust.nix`: `rust-<crate>-{fmt,clippy,test}` for every crate under
  `native/` (minus `cardigann_guest`), `player/rust/` and `server/`, plus
  `rust-p2p-core-wasm` and `rust-plugins`; and the `ciInternal` NIFs
  (`nifs-mydia_p2p`, `nifs-mydia_subsync`), `pluginWasm`, and
  `cargoDeps-<crate>` per crate (the crane `buildDepsOnly` its clippy and
  test checks share). Its crate list mirrors `scripts/check-rust.sh`.
- `mix-deps.nix`: the test-env Mix dependencies from `deps.nix`:
  `ciInternal.mixDepsSrc` (the `deps/` tree, with the `mix.exs`
  `@dep_patches` applied), `ciInternal.wasmexNif` (the patched Wasmex NIF,
  built on its own so wasmtime only recompiles when Wasmex, its lock or the
  toolchain changes) and `ciInternal.mixDepsCompiled-{sqlite,postgres}`
  (one derivation under both names: `deps/` plus `_build/test/lib` from an
  offline `MIX_ENV=test mix deps.compile`, built at `/build/source`, with
  every NIF built from source). Evaluating
  `checks` fails with `deps.nix is stale: run mix2nix mix.lock > deps.nix` when a
  `mix.lock` Hex entry has no `deps.nix` entry of the same version.
- `elixir.nix`: `ciInternal.mydiaTestBuild-{sqlite,postgres}` (the app's
  `MIX_ENV=test mix compile --warnings-as-errors` on top of
  `mixDepsCompiled`, with the NIFs and plugin wasm from `rust.nix` in
  `priv/native` and `priv/plugins` and `MYDIA_PREBUILT_NIFS=1`,
  `MYDIA_PREBUILT_PLUGINS=1`, so no cargo runs; the output is `deps/`,
  `_build/test`, `priv/native` and `priv/plugins/*.wasm`, to lay over the
  source at `/build/source`), `ciInternal.dialyzer-plt` (keyed on the
  compiled deps and the toolchain, not on `lib/`), and the checks
  `elixir-format`, `elixir-lint` (the Lint job's guard greps,
  `deps.unlock --check-unused`, Credo, `gettext.extract
  --check-up-to-date`) and `dialyzer`. Consumers of the test build set both
  `MYDIA_PREBUILT_*` variables too: Rustler reads its config with
  `Application.compile_env`, so a different value makes Mix recompile the
  NIF modules, with cargo. The ratchet and the `mix_unused` report read git
  history and stay an ordinary job (`Lint / Ratchet`, below).
- `tests.nix`: the ExUnit shards `test-sqlite-{1..4}` and
  `test-postgres-{1..3}`, on top of `mydiaTestBuild` (through
  `elixir.nix`'s `_module.args.ciElixir` helpers). Each starts its own
  RustFS and, for PostgreSQL, its own server on loopback, then runs
  `mix test --partitions N --warnings-as-errors --seed 0`; the output is
  `test.log`. `testReads` lists the repo files outside the app and `test/`
  that tests read. `test/ci/workflow_triggers_test.exs`, the one test that
  reads `.github/workflows`, is left out of the shards and runs alone in
  `ci-workflow-triggers`, so a workflow edit reruns that check instead of
  all seven shards (on master the non-blocking NixOS tests rerun too, as on
  any edit: their package takes the whole repo as source). The shards carry the Cardigann guest pinned in
  `native/cardigann_guest/ARTIFACT_SHA256` (the app's own pin), installed
  only while its source hash matches the guest sources;
  `ci-cardigann-hash` proves the Nix-side hash equals
  `mix mydia.cardigann_guest hash`. What the sandbox means for tests: `test/README.md`,
  "Sandboxed CI runs". The inputs every shard shares are `ciInternal.rustfs`
  (devenv's RustFS override, a full Rust build), `ciInternal.cardigannGuest`
  (the pinned guest fetch; absent when `ARTIFACT_SHA256` holds a value the
  app reads as no pin, such as `unpublished`, and then no shard carries the
  guest) and `ciInternal.cardigannSourceHash`.
  `tests.nix` also holds `e2e-browser`, the Wallaby `:feature` suite in
  nixpkgs chromium and chromedriver over `mydiaTestBuild-sqlite` and
  `ciInternal.assets` (the digested esbuild and Tailwind output the
  LiveView socket needs).
- `player.nix`: the Flutter player (below, "The player checks"):
  `ciInternal.player-pub-cache`, `ciInternal.player-codegen` and the checks
  `player-analyze`, `player-l10n-test`, `player-icons`, `player-test`,
  `player-test-web`, `player-web` and `player-linux`. `player-linux` takes
  `ciInternal.player-p2p-so` from `rust.nix`.
- `../checks/flake-module.nix`: the NixOS module VM tests `nixos-module` and
  `nixos-module-postgres`, `player-e2e` (x86_64-linux only,
  `../tests/player-e2e.nix`: relay, server and Flutter client VMs running
  the player's integration tests), and the packages they boot as
  `ciInternal.package-default`, `ciInternal.package-postgres` and
  `ciInternal.package-metadata-relay` (`packages.metadata-relay`, a
  `mixRelease` on the relay's BEAM pair and `deps.nix` from `relay.nix`'s
  `_module.args.ciRelay`).
- `relay.nix`: `relay-test`, the old `Relay / Test` job for
  `metadata-relay/` (its own Mix project): `deps.unlock --check-unused`,
  `compile --warnings-as-errors`, `format --check-formatted`, `ecto.create`
  and `ecto.migrate` (SQLite), `test --warnings-as-errors --seed 0`; the
  output is `test.log`. Its deps come from `metadata-relay/deps.nix`
  (`ciInternal.relayDepsCompiled`), with the same freshness assertion as
  the app's, and it builds on the BEAM pair pinned by
  `metadata-relay/.elixir-version` and `.otp-version`.
  Those pins name the relay `Dockerfile`'s pair (Elixir 1.20, OTP 29), so
  the check tests what ships. Move them together with the Dockerfile's
  base tag. They are outside `scripts/check-beam-pin.sh`'s scope, so
  nothing enforces that.
- `guards.nix`: `guards`, the repository guards that only read files (the
  Rust toolchain pin, the Rust lint tables, the Docker build-identity
  placement, the pre-migration backup task and devenv shell-entry purity),
  and `ci-crate-list`, which fails when `scripts/check-rust.sh --list` (its
  manifest glob) and the crate list in `rust.nix` name different crates.
  The guard that runs `yq` over the workflows stays in ci.yml's `Guards`
  job.
- `mix-lib.nix`: helpers both Mix projects share (lock parsing, the
  freshness assertion, the offline Mix env, the NIF source edits, the
  log-writing check).
- `../beam-deps.nix`: `deps.nix` with its sandbox overrides, heroicons,
  lexbor and the vendored Wasmex crates, shared with `nix/packages`.
- `../toolchains.nix`: `beamPackages`, shared with `nix/packages` so the
  package and the checks build on the same BEAM pins; the package's
  `rustToolchain`; and `rustToolchainCi`, which is what `ci.rustToolchain`
  is.

## The derivation graph

Every check is a derivation, cached in niks3 and skipped by CI until one of
its inputs changes. The intermediate derivations are `ciInternal` entries.
`A ─► B` reads "B is built from A":

    deps.nix, mix.lock, patches/          ─► mixDepsSrc
    Wasmex crates, nix/wasmex-Cargo.lock  ─► wasmexNif
    mixDepsSrc, wasmexNif                 ─► mixDepsCompiled-{sqlite,postgres}
    mixDepsCompiled                       ─► dialyzer-plt, elixir-format
    native/mydia_p2p, native/mydia_subsync ─► nifs-mydia_p2p, nifs-mydia_subsync
    plugins/                              ─► pluginWasm
    mixDepsCompiled, NIFs, pluginWasm,
      lib/, config/, priv/, test/support  ─► mydiaTestBuild-{sqlite,postgres}
    mydiaTestBuild-sqlite, test/, rustfs,
      cardigannGuest                      ─► test-sqlite-{1..4}
    mydiaTestBuild-postgres, test/, ...   ─► test-postgres-{1..3}
    mydiaTestBuild-sqlite                 ─► elixir-lint, ci-cardigann-hash,
                                             ci-workflow-triggers
    mydiaTestBuild-sqlite, dialyzer-plt   ─► dialyzer
    mydiaTestBuild-sqlite, assets,
      chromium, chromedriver              ─► e2e-browser
    each crate                            ─► cargoDeps-<crate>
                                             ─► rust-<crate>-{clippy,test}
    player/rust/mydia_player_p2p,
      native/mydia_p2p_core               ─► player-p2p-so
    player/pubspec.lock.json              ─► player-pub-cache
    player/ (playerCodegen), the GraphQL
      schema, player-pub-cache            ─► player-codegen
    player-codegen                        ─► player-analyze, player-l10n-test,
                                             player-icons, player-test-web,
                                             player-web
    player-codegen, platform files, rustfs ─► player-test
    player-codegen, player-p2p-so         ─► player-linux
    metadata-relay/                       ─► relayDepsCompiled ─► relay-test
    package-{default,postgres}            ─► nixos-module{,-postgres}
    plain files                           ─► rust-<crate>-fmt, guards,
                                             ci-crate-list, ci-fileset-coverage

So a `lib/` edit rebuilds `mydiaTestBuild` and everything under it, and
leaves the dependency builds, the PLT, the NIFs, the player and every Rust
and relay check cached. A `test/` edit reruns the shards and `e2e-browser`;
a workflow edit reruns `ci-workflow-triggers` only (plus, on master, the
non-blocking NixOS tests, whose package takes the whole repo as source and
so reruns on any edit). A player source edit rebuilds `player-codegen` and every player
check from scratch: there is no incremental `.dart_tool`.

## The player checks

`nix/ci/player.nix` builds the player's Linux, web and VM checks in the
sandbox. Android is not one of them (`.github/ci.md`, "Build / Android runs
on every PR"), and Windows and macOS stay in `ci-player.yml`.

- **Pub cache.** `player-pub-cache` is a `PUB_CACHE` holding every hosted
  package in `player/pubspec.lock`, read from `player/pubspec.lock.json`
  (Nix reads no YAML; `scripts/regenerate-derived.sh` writes the JSON and
  `check-generated-freshness.sh` keeps it current). Each archive is fetched
  by nixpkgs' `pub2nix`, fixed-output on the lock's sha256.
- **Patched sources.** `pub2nix` applies nixpkgs' own package-source
  builders, the ones `buildFlutterApplication` uses, so a few plugins come
  in with nixpkgs' Linux patches rather than byte for byte from pub.dev:
  `media_kit`, `media_kit_libs_linux`, `xdg_directories` and
  `flutter_secure_storage_linux`. When one of those is bumped in
  `pubspec.lock`, check that nixpkgs' builder still applies to the new
  version (and still does what the player needs), or the checks build a
  tree that differs from what developers and the release run.
- **Writable `/build/pub-cache`.** Pub writes bookkeeping (`active_roots/`)
  into `PUB_CACHE` even offline, so the cache every check sees is a writable
  `/build/pub-cache` whose `hosted/` and `hosted-hashes/` link into the
  store. The path is fixed in `player-codegen` and every check, because pub
  writes it into `.dart_tool/package_config.json`.
- **Codegen once.** `player-codegen` runs `flutter pub get --offline
  --enforce-lockfile`, `flutter gen-l10n` and `flutter pub run build_runner
  build` at `/build/source/player`, and every check copies that tree back to
  `/build/source` (`mkPlayerCheck`), where the absolute paths build_runner
  recorded under `.dart_tool` still hold.
- **The `flutter` shim.** Each check's `flutter` is a PATH shim that adds
  `--no-pub` to `test`, `analyze` and `build` (their implicit `pub get` is
  not offline and hangs in the sandbox) and `--test-randomize-ordering-seed
  0` to any `flutter test` that sets no seed. It matches only the first
  argument: the subcommand must come first (`flutter test ...`, never
  `flutter --suppress-analytics test ...`), or the call passes through
  unchanged.
- **The p2p library.** `player-linux` never runs cargokit: crane builds
  `libmydia_player_p2p.so` as `ciInternal.player-p2p-so` (`rust.nix`), and
  the check exports `MYDIA_PLAYER_P2P_PREBUILT` with its path.
  `player/rust_builder/linux/CMakeLists.txt` bundles the file that variable
  names and skips `apply_cargokit`. `cargo` and `rustup` on the check's PATH
  refuse, so a fallback to cargokit fails loudly. The bundle's runpath points
  into `/nix/store`, so CI does not upload it.
- **very_good.** `player-test` does not run very_good_cli. It reproduces, in
  bash, very_good_cli 1.5.0's test optimizer template and the `flutter test`
  call very_good makes with it; developers run the real `very_good test`.
  Bumping very_good_cli means re-reading its template and pre_gen hook.

## Outside the sandbox

Three CI jobs cannot be checks. Two run as ordinary jobs in `devShells.ci`,
and `Build / Android` runs in `devShells.android` (`.github/ci.md`, "Build /
Android runs on every PR"):

- `Lint / Ratchet` runs `mix mydia.ratchet --from-git-merge-base
  origin/master`, which reads git history, and on master pushes the
  advisory `mix_unused` report. It substitutes
  `ciInternal.mydiaTestBuild-sqlite` instead of compiling:
  `scripts/ci-restore-test-build.sh --mount` bind-mounts the checkout at
  `/build/source` (Mix records absolute paths), copies the build into it,
  dates every file to the epoch as the store does (so Mix sees nothing
  stale) and gives `deps/heroicons` the `.git` the deps check reads. Mix
  then recompiles only a handful of files (about 14), not the app.
- `Rust / SMB integration` runs `mydia_smb`'s Samba tests, which need a
  root smbd; `rust-mydia_smb-test` skips them.

The Wallaby browser suite is not one of them: it is the `e2e-browser` check
in `tests.nix`, over the test build and `ciInternal.assets`.

The NixOS module VM tests are checks, but `scripts/ci-plan.sh` lists them
separately and ci.yml runs them outside the `Nix / Checks` verdict, on
master pushes, manual dispatches and Dependabot PRs only (`.github/ci.md`,
"The NixOS module tests skip human PRs and block nothing").

`player-e2e` is a VM test too, but blocking (`Test / Player E2E` is
required), so it is not `nixos-`-prefixed and builds in the `Nix / Checks`
matrix, whose job enables KVM for it. Its client runs the Linux build
outside the sandbox, so it sources an environment captured from a
derivation with `player-linux`'s inputs (`clientEnv`) and recreates
`/build/source` and `/build/pub-cache` through `ciPlayer.setupPlayerTree`,
the helper `mkPlayerCheck` uses.

## ciInternal and the CI planner

`scripts/ci-plan.sh` (run by the `Nix / Plan` job in `.github/workflows/ci.yml`) builds
a `ciInternal` derivation in its own job, before the checks, when two or
more uncached checks still need it. Anything else a check needs is built
inside that check's job and is never pushed unless it is in the check's
output closure, which build-time inputs are not. So an expensive build-time
input that several checks share belongs in `ciInternal`; exposing an
existing derivation there does not change any check's derivation path.

## Master pins

niks3 garbage-collects unpinned paths after 14 days. A PR's run pushes its
outputs before it merges, so the run on master usually finds everything
cached, skips both build jobs and would pin nothing. The `Nix / Pins` job
(master only, after the build jobs, whatever their result) therefore takes
ci-plan.sh's `all` list (every check and `ciInternal` attribute with its
output path), fetches those outputs with one `nix-store --realise
--keep-going` and pushes each with the pin `master-<name>`
(`scripts/ci-nix-pin.sh`). niks3 skips NARs it already has, so this mostly
records the pins. It only warns, never fails the run, and is not part of
`Nix / Checks`. PR runs never pin.

## Who can write to the cache

A deliberate trust decision. niks3 signs whatever it is handed, and CI
skips any check whose output path is already in the cache, so an uploaded
path counts as a passed check on master. Uploads come from:

- any workflow run in `getmydia/mydia` that obtains an OIDC token for the
  niks3 audience, including a pull request from a branch of this repository
  that edits a workflow in the same PR;
- any holder of the niks3 admin token (`scripts/nix-cache-push.sh`).

This is accepted because write access to the repository is a small,
trusted set of maintainers. Pull requests from forks get no OIDC token and
cannot write. The server side, and what to revisit before widening write
access: `infra/kubernetes/apps/nix-cache/README.md`, "Who can write, and why
that is accepted".

## The file-set rule

Every derivation `src` is built from these sets with `sources.toSource`.
Never use `src = ../..`: one edit anywhere would rebuild every check.

`checks.ci-fileset-coverage` enforces this. It fails, listing the paths, when
a git-tracked file under `lib/ config/ priv/ test/ plugins/ server/
metadata-relay/` belongs to none of the sets (Markdown files are exempt). A
new directory or file type there has to be added to `sources.nix`. `native/`
is in the list too, but its coverage set includes every directory under it
as a crate, so the check cannot flag a new crate there. A new Rust crate is
caught by `ci-crate-list` instead, once it is under `native/*` or
`player/rust/*`.

## Building a check locally

    nix build .#checks.x86_64-linux.ci-fileset-coverage -L
    nix build .#checks.x86_64-linux.player-test -L

New files must be visible to git (`git add -N <path>`) before Nix sees them.
