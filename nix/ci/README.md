# Nix-native CI

CI checks are flake derivations, built with `nix build` and cached in the
niks3 binary cache. Design: `design/specs/2026-11-20-nix-ci-checks-design.md`.

## Layout

- `flake-module.nix`: the flake-parts module. It exposes
  `legacyPackages.<system>.ciInternal` (internal derivations such as compiled
  dependencies and NIFs, built with `nix build .#ciInternal.<name>`) and
  `legacyPackages.<system>.ciRustAttrs` (the list of Rust check names), fed
  by the mergeable perSystem options `ciInternal` and `ciRustAttrs` that the
  other `nix/ci/*.nix` modules set. It also passes
  `ci = { sources, rustToolchain, beamPackages, craneLib }` to them through
  `_module.args`. `ci.rustToolchain` is the CI toolchain (the
  `rust-toolchain.toml` version with clippy, rustfmt and the wasm targets),
  and `ci.craneLib` is crane on that toolchain.
- `sources.nix`: the `lib.fileset` source sets (`elixirApp`, `mixProject`, `elixirTest`,
  `gettext`, `patches`, `nativeCrate`, `playerCrate`, `plugins`,
  `pluginsExtra`, `server`, `relay`) and the `toSource` helper.
- `rust.nix`: `rust-<crate>-{fmt,clippy,test}` for every crate under
  `native/` (minus `cardigann_guest`), `player/rust/` and `server/`, plus
  `rust-p2p-core-wasm` and `rust-plugins`; and the `ciInternal` NIFs
  (`nifs-mydia_p2p`, `nifs-mydia_subsync`) and `pluginWasm`. Its crate list
  mirrors `scripts/check-rust.sh`.
- `mix-deps.nix`: the test-env Mix dependencies from `deps.nix`:
  `ciInternal.mixDepsSrc` (the `deps/` tree, with the `mix.exs`
  `@dep_patches` applied), `ciInternal.wasmexNif` (the patched Wasmex NIF,
  built on its own so wasmtime only recompiles when Wasmex, its lock or the
  toolchain changes) and `ciInternal.mixDepsCompiled-{sqlite,postgres}`
  (one derivation under both names: `deps/` plus `_build/test/lib` from an
  offline `MIX_ENV=test mix deps.compile`, built at `/build/source`, with
  every NIF built from source). Evaluating
  `checks` fails with `deps.nix is stale: run mix2nix > deps.nix` when a
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
  history and stay ordinary jobs.
- `tests.nix`: the ExUnit shards `test-sqlite-{1..4}` and
  `test-postgres-{1..3}`, on top of `mydiaTestBuild` (through
  `elixir.nix`'s `_module.args.ciElixir` helpers). Each starts its own
  RustFS and, for PostgreSQL, its own server on loopback, then runs
  `mix test --partitions N --warnings-as-errors --seed 0`; the output is
  `test.log`. `testReads` lists the repo files outside the app and `test/`
  that tests read. The shards carry the Cardigann guest pinned in
  `cardigann-guest.json` (written by `scripts/update-cardigann-guest-pin.sh`,
  which the `cardigann-guest` workflow runs after publishing and proposes in
  a pull request), installed only while its `source_hash` matches the guest
  sources; `ci-cardigann-hash` proves the Nix-side hash equals
  `mix mydia.cardigann_guest hash`. What the sandbox means for tests: `test/README.md`,
  "Sandboxed CI runs".
- `../beam-deps.nix`: `deps.nix` with its sandbox overrides, heroicons,
  lexbor and the vendored Wasmex crates, shared with `nix/packages`.
- `../toolchains.nix`: `beamPackages`, shared with `nix/packages` so the
  package and the checks build on the same BEAM pins; the package's
  `rustToolchain`; and `rustToolchainCi`, which is what `ci.rustToolchain`
  is.

## The file-set rule

Every derivation `src` is built from these sets with `sources.toSource`.
Never use `src = ../..`: one edit anywhere would rebuild every check.

`checks.ci-fileset-coverage` enforces this. It fails, listing the paths, when
a git-tracked file under `lib/ config/ priv/ test/ native/ plugins/ server/
metadata-relay/` belongs to none of the sets (Markdown files are exempt). A
new directory or file type therefore has to be added to `sources.nix`.

## Building a check locally

    nix build .#checks.x86_64-linux.ci-fileset-coverage -L

New files must be visible to git (`git add -N <path>`) before Nix sees them.
