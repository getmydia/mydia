#!/usr/bin/env bash
set -uo pipefail

# Lint every host Rust crate under native/ and player/rust/: cargo fmt --check
# and cargo clippy --all-targets -D warnings.
#
# Crates are discovered by glob, so a new crate is gated by the pre-commit hook
# and the CI Rust job (both run this script) without editing a list.
#
# Usage: scripts/check-rust.sh [--fix]
#   (default) cargo fmt --check + cargo clippy -D warnings
#   --fix     cargo fmt (rewrite) instead of --check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every host crate under native/ and player/rust/. cardigann_guest is a .NET
# wasm guest with its own pipeline (cardigann-guest.yml), not a cargo crate we
# lint here. server/ is gated by ci-server.yml and its own hooks; the wasm
# plugins by scripts/check-plugins.sh.
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS=()
for manifest in "$ROOT_DIR"/native/*/Cargo.toml "$ROOT_DIR"/player/rust/*/Cargo.toml; do
  case "$manifest" in */native/cardigann_guest/*) continue ;; esac
  [ -e "$manifest" ] || continue
  MANIFESTS+=("$manifest")
done

FMT_ARGS=(-- --check)
if [ "${1:-}" = "--fix" ]; then
  FMT_ARGS=()
fi

failed=()

for manifest in "${MANIFESTS[@]}"; do
  crate="$(basename "$(dirname "$manifest")")"
  echo "==> $crate"
  cargo fmt --manifest-path "$manifest" --all "${FMT_ARGS[@]}" || failed+=("$crate (fmt)")
  cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings || failed+=("$crate (clippy)")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "Rust checks failed:"
  printf '  %s\n' "${failed[@]}"
  echo "Run scripts/check-rust.sh --fix for formatting; clippy findings need a code fix."
  exit 1
fi
