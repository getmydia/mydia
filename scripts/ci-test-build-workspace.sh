#!/usr/bin/env bash
#
# Lay the cached test build (ciInternal.mydiaTestBuild-sqlite) over this
# checkout, so Mix in `nix develop .#ci` sees the app and its deps as compiled
# and up to date. For CI jobs that run Mix outside the Nix sandbox (`Lint /
# Ratchet` in ci.yml); see nix/ci/README.md.
#
# Usage: scripts/ci-test-build-workspace.sh     (from /build/source)
#
# Three things make a copy of that build usable here, the same three the
# checks rely on inside the sandbox (nix/ci/elixir.nix):
#
# - The checkout must sit at /build/source, where the build ran: Mix records
#   absolute paths in the deps' build manifests. CI bind-mounts the workspace
#   there.
# - Every file is dated to the epoch, as store files are. Mix compares source
#   mtimes with the time each manifest records; a fresh checkout's files are
#   newer than that and Mix would recompile the app, and with a newer
#   config/ every dependency too (with cargo, for the NIF deps).
# - deps/heroicons gets the .git Mix's deps check reads (remote URL and HEAD
#   from mix.lock). The build carries heroicons without one, and the check
#   fails without it. --no-deps-check cannot help: the ratchet starts
#   `mix credo` as a subprocess, which runs the check itself.
#
# Run Mix with the same environment as the build: `nix develop .#ci` sets
# it (MIX_ENV=test, MYDIA_PREBUILT_NIFS=1, MYDIA_PREBUILT_PLUGINS=1, Hex from
# the store); a different value of any variable the app's compile-time config
# reads makes Mix recompile.
set -euo pipefail

if [ "$(pwd -P)" != /build/source ]; then
  echo "ci-test-build-workspace.sh: run from /build/source (the build's manifests point there), not $(pwd -P)" >&2
  exit 1
fi

build="$(nix build .#ciInternal.mydiaTestBuild-sqlite --no-link --print-out-paths)"
echo "test build: $build"

find . -path ./.git -prune -o -exec touch -h -d @1 {} +

rm -rf deps _build
cp -r --preserve=timestamps "$build/deps" deps
cp -r --preserve=timestamps "$build/_build" _build
mkdir -p priv/native priv/plugins
cp --preserve=timestamps "$build"/priv/native/* priv/native/
cp --preserve=timestamps "$build"/priv/plugins/*.wasm priv/plugins/
chmod -R u+w deps _build priv

lock="$(grep -E '^[[:space:]]*"heroicons": \{:git, ' mix.lock || true)"
url="$(sed -E 's/.*\{:git, "([^"]+)", "([0-9a-f]+)".*/\1/' <<< "$lock")"
rev="$(sed -E 's/.*\{:git, "([^"]+)", "([0-9a-f]+)".*/\2/' <<< "$lock")"
if [ -z "$lock" ] || [ "$url" = "$lock" ]; then
  echo "ci-test-build-workspace.sh: no heroicons git entry in mix.lock" >&2
  exit 1
fi
git -C deps/heroicons init --quiet
git --git-dir=deps/heroicons/.git config remote.origin.url "$url"
echo "$rev" > deps/heroicons/.git/HEAD
