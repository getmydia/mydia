#!/usr/bin/env bash
# Bring the fetchNpmDeps hashes in nix/packages/flake-module.nix in line with
# their lockfiles (assets/package-lock.json and
# metadata-relay/assets/package-lock.json; the list is npm_deps_targets in
# scripts/lib/npm-deps-hash.sh).
#
# The devenv pre-commit hook `npm-deps-hash` runs this whenever either
# lockfile is staged. Like any fixing hook it exits 1 after rewriting the file,
# so the commit stops and the new hash can be staged with it. Run it by hand
# the same way. Exits 0 when every hash was already right.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=scripts/lib/npm-deps-hash.sh
source scripts/lib/npm-deps-hash.sh

rewrote=0
for target in "${npm_deps_targets[@]}"; do
  read -r lockfile binding <<<"$target"
  computed="$(npm_deps_hash "$lockfile")"
  pinned="$(npm_deps_hash_pinned "$binding")"

  if [ "$computed" != "$pinned" ]; then
    npm_deps_hash_write "$binding" "$computed"
    echo "$binding.hash: $pinned -> $computed in $npm_deps_flake_module." >&2
    echo "Stage $npm_deps_flake_module with $lockfile and commit again." >&2
    rewrote=1
  fi
done

exit "$rewrote"
