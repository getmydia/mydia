# Nix-native CI

CI checks are flake derivations, built with `nix build` and cached in the
niks3 binary cache. Design: `design/specs/2026-11-20-nix-ci-checks-design.md`.

## Layout

- `flake-module.nix`: the flake-parts module. It exposes
  `legacyPackages.<system>.ciInternal` (internal derivations such as compiled
  dependencies and NIFs, built with `nix build .#ciInternal.<name>`) and
  `legacyPackages.<system>.ciRustAttrs` (the list of Rust check names). It
  also passes `ci = { sources, rustToolchain, beamPackages, craneLib }` to the
  other `nix/ci/*.nix` modules through `_module.args`.
- `sources.nix`: the `lib.fileset` source sets (`elixirApp`, `elixirTest`,
  `gettext`, `patches`, `nativeCrate`, `plugins`, `server`, `relay`) and the
  `toSource` helper.
- `../toolchains.nix`: `beamPackages` and `rustToolchain`, shared with
  `nix/packages` so the package and the checks use the same pins.

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
