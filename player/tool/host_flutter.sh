#!/usr/bin/env bash
# Run Flutter with the host toolchain, not devenv's Nix-wrapped one.
#
# direnv loads devenv on cd into the worktree, which exports a Nix clang PATH,
# DEVELOPER_DIR and SDKROOT pointing at nixpkgs' apple-sdk, and a Nix-wrapped
# flutter. Under that environment `flutter test` dies before any test runs with
# "Building native assets failed": clang cannot find the macOS SDK while
# compiling `objective_c`, pulled in by flutter_secure_storage_darwin.
#
# This mirrors the escape hatch in `./dev player macos` (dev:506-517). CI does
# not need it — the player suite runs on Linux there.
#
# Usage, from player/:  ./tool/host_flutter.sh test test/core/window/
set -euo pipefail

if [ -n "${IN_NIX_SHELL:-}${DEVENV_ROOT:-}" ]; then
    PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/nix/store/' | paste -sd: -)"
    export PATH
    # NIX_SSL_CERT_FILE stays: pub fetches over TLS and Nix-installed curl has
    # no other CA bundle.
    for nix_var in $(compgen -v | grep '^NIX_'); do
        [ "$nix_var" = "NIX_SSL_CERT_FILE" ] || unset "$nix_var"
    done
    unset DEVELOPER_DIR SDKROOT MACOSX_DEPLOYMENT_TARGET IN_NIX_SHELL \
          LD_DYLD_PATH LD_FOR_BUILD PKG_CONFIG_PATH CC CXX AR LD \
          CFLAGS LDFLAGS CPATH LIBRARY_PATH
fi

if ! command -v flutter &> /dev/null; then
    echo "error: no host flutter on PATH (expected /opt/homebrew/bin/flutter)" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
exec flutter "$@"
