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
  `@dep_patches` applied) and `ciInternal.mixDepsCompiled-{sqlite,postgres}`
  (`deps/` plus `_build/test/lib` from an offline
  `MIX_ENV=test mix deps.compile`, built at `/build/source`). Evaluating
  `checks` fails with `deps.nix is stale: run mix2nix > deps.nix` when a
  `mix.lock` Hex entry has no `deps.nix` entry of the same version.
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
