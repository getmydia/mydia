#!/usr/bin/env bash
# Bring npmDeps.hash in nix/packages/flake-module.nix in line with
# assets/package-lock.json.
#
# The devenv pre-commit hook `npm-deps-hash` runs this whenever the lockfile is
# staged. Like any fixing hook it exits 1 after rewriting the file, so the
# commit stops and the new hash can be staged with it. Run it by hand the same
# way. Exits 0 when the hash was already right.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=scripts/lib/npm-deps-hash.sh
source scripts/lib/npm-deps-hash.sh

computed="$(npm_deps_hash)"
pinned="$(npm_deps_hash_pinned)"

if [ "$computed" = "$pinned" ]; then
  exit 0
fi

npm_deps_hash_write "$computed"
echo "npmDeps.hash: $pinned -> $computed in $npm_deps_flake_module." >&2
echo "Stage $npm_deps_flake_module with $npm_deps_lockfile and commit again." >&2
exit 1
