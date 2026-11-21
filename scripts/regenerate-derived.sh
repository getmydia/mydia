#!/usr/bin/env bash
# Regenerate the files derived from dependency manifests: the repairing half
# of check-generated-freshness.sh.
#
# Dependabot edits manifests and their own lockfiles and nothing else, so
# three derived artifacts go stale behind it. Each is mechanical:
#
#   deps.nix       mix2nix output of mix.lock, byte for byte, for the app and
#                  for metadata-relay/
#   */Cargo.lock   path crates are shared between workspaces, so a bump in one
#                  crate's manifest leaves every other lock that includes it
#                  unsatisfied
#   npmDeps.hash   fixed-output hash of assets/package-lock.json, in
#                  nix/packages/flake-module.nix
#   devenv.lock    its nixpkgs node, copied from flake.lock's so the devenv
#                  shell and the Nix build share one package set
#   player/pubspec.lock.json
#                  yq's JSON form of player/pubspec.lock, which nix/ci/player.nix
#                  reads with lib.importJSON (Nix has no YAML parser)
#
# The flutter_rust_bridge bindings and the hand-pinned Nix hashes for fine,
# wasmex, tailwind, heroicons and lexbor are not regenerated here;
# .github/dependabot.yml ignores the dependencies that would move them.
#
# No tool here executes dependency code: mix2nix reads mix.lock, `cargo
# metadata` resolves without running build scripts, and prefetch-npm-deps
# fetches tarballs without running install scripts. dependabot-fixup.yml runs
# this on Dependabot branches and relies on that.
#
# Needs nix and cargo on PATH. Idempotent: on a fresh tree it changes nothing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/cargo-lock-dirs.sh
source scripts/lib/cargo-lock-dirs.sh
# shellcheck source=scripts/lib/npm-deps-hash.sh
source scripts/lib/npm-deps-hash.sh

# --inputs-from . resolves nixpkgs to this flake's pinned input, so the tools
# match what the Nix build uses rather than whatever is newest.
nixpkgs_run() {
  local pkg="$1"; shift
  nix run --inputs-from . "nixpkgs#$pkg" -- "$@"
}

trap 'rm -f deps.nix.tmp metadata-relay/deps.nix.tmp player/pubspec.lock.json.tmp' EXIT

# The app's and metadata-relay's (its own Mix project; nix/ci/relay.nix).
for d in . metadata-relay; do
  echo "$d/deps.nix <- $d/mix.lock"
  nixpkgs_run mix2nix "$d/mix.lock" > "$d/deps.nix.tmp"
  mv "$d/deps.nix.tmp" "$d/deps.nix"
done

for d in "${cargo_lock_dirs[@]}"; do
  [ -f "$d/Cargo.lock" ] || continue
  echo "$d/Cargo.lock <- $d/Cargo.toml"
  (cd "$d" && cargo metadata --format-version 1 > /dev/null)
done

echo "player/pubspec.lock.json <- player/pubspec.lock"
nixpkgs_run yq-go -o json player/pubspec.lock > player/pubspec.lock.json.tmp
mv player/pubspec.lock.json.tmp player/pubspec.lock.json

echo "npmDeps.hash <- assets/package-lock.json"
npm_deps_hash_write "$(npm_deps_hash)"

echo "devenv.lock nixpkgs <- flake.lock nixpkgs"
scripts/sync-devenv-nixpkgs.sh

./scripts/check-generated-freshness.sh
