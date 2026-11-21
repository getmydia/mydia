#!/usr/bin/env bash
#
# Restore the cached test build (ciInternal.mydiaTestBuild-sqlite) into this
# checkout, so Mix sees the app and its deps as compiled and up to date. For
# the ci.yml job that runs Mix outside the Nix sandbox, `Lint / Ratchet` (in
# `nix develop .#ci`). See nix/ci/README.md, "Outside the sandbox".
#
# Usage: scripts/ci-restore-test-build.sh            (from /build/source)
#        scripts/ci-restore-test-build.sh --mount    (from the checkout, CI)
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
# Then run Mix with the build's compile-time environment, or Mix recompiles
# the app: MIX_ENV=test, MYDIA_PREBUILT_NIFS=1, MYDIA_PREBUILT_PLUGINS=1,
# MYDIA_SKIP_CARDIGANN_FETCH=1 and no DATABASE_TYPE (SQLite), on the same
# Elixir and OTP. `nix develop .#ci` sets all of it; devenv has the same
# Elixir and OTP (both resolve beam-version.nix on flake.lock's nixpkgs) and
# the caller exports the variables. Do not run `mix deps.get`: deps/ is
# complete, and the build is offline-compiled from deps.nix.
#
# What the build lacks: priv/static/assets (run `mix assets.deploy`, which
# needs node_modules from `npm ci --prefix assets`) and the Cardigann guest.
set -euo pipefail

# --mount (CI): bind-mount the current checkout at /build/source with sudo
# and continue there. Later steps then use working-directory: /build/source.
if [ "${1:-}" = "--mount" ]; then
  workspace="$(pwd -P)"
  sudo mkdir -p /build/source
  sudo mount --bind "$workspace" /build/source
  cd /build/source
  exec "./scripts/$(basename "$0")"
fi

if [ "$(pwd -P)" != /build/source ]; then
  echo "ci-restore-test-build.sh: run from /build/source (the build's manifests point there), not $(pwd -P)" >&2
  exit 1
fi

# The niks3 cache, for a Nix installed without it (a local run). Harmless
# where it is already configured.
build="$(nix build .#ciInternal.mydiaTestBuild-sqlite --no-link --print-out-paths \
  --option extra-substituters https://cache.mydia.dev \
  --option extra-trusted-public-keys 'cache.mydia.dev-1:5zkoQR4Gcrx1EEQ1GvHRPQ7EoHm8gNrrVoeAqX3ioFg=')"
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
  echo "ci-restore-test-build.sh: no heroicons git entry in mix.lock" >&2
  exit 1
fi
git -C deps/heroicons init --quiet
git --git-dir=deps/heroicons/.git config remote.origin.url "$url"
echo "$rev" > deps/heroicons/.git/HEAD
