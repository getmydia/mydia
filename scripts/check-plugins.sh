#!/usr/bin/env bash
set -euo pipefail

# Lint every WASM plugin crate under plugins/ and plugins-extra/.
#
# Plugins compile to wasm32-wasip2 component-model guests (built against the WIT
# contract via the SDK's wit-bindgen), so we check them against that target
# rather than the host. This keeps plugin commits off the native NIF toolchain
# entirely — the native p2p crate links against system libraries and is
# irrelevant to a plugin change.
#
# Usage: scripts/check-plugins.sh [--fix]
#   (default) cargo fmt --check + cargo clippy -D warnings
#   --fix     cargo fmt (rewrite) instead of --check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TARGET="wasm32-wasip2"

FMT_MODE="--check"
if [ "${1:-}" = "--fix" ]; then
  FMT_MODE=""
fi

# Verify the *active* toolchain has the target's std, by probing its sysroot
# directly rather than asking rustup — the pinned devenv toolchain (languages.rust
# in devenv.nix) bakes the target in and exposes no rustup, while a leaked host
# rustup would report the target missing and give a false negative. When running
# outside the devenv shell with a host rustup, add it once: rustup target add $TARGET.
SYSROOT="$(rustc --print sysroot 2>/dev/null || true)"
if [ -n "$SYSROOT" ] && [ ! -d "$SYSROOT/lib/rustlib/$TARGET" ]; then
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$TARGET" 2>/dev/null || true
  fi

  if [ ! -d "$SYSROOT/lib/rustlib/$TARGET" ]; then
    echo "Rust target $TARGET is not installed for the active toolchain. Run:"
    echo "  rustup target add $TARGET"
    echo "  (or lint via: devenv shell -- scripts/check-plugins.sh)"
    exit 1
  fi
fi

found=0
for manifest in "$PROJECT_ROOT"/plugins/*/Cargo.toml "$PROJECT_ROOT"/plugins-extra/*/Cargo.toml; do
  [ -e "$manifest" ] || continue
  found=1
  crate_dir="$(dirname "$manifest")"
  echo "==> $(basename "$crate_dir")"

  # shellcheck disable=SC2086
  cargo fmt --manifest-path "$manifest" -- $FMT_MODE
  cargo clippy --manifest-path "$manifest" \
    --release --target "$TARGET" -- -D warnings
done

if [ "$found" -eq 0 ]; then
  echo "No plugin crates found under plugins/ or plugins-extra/."
fi
