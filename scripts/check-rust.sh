#!/usr/bin/env bash
set -uo pipefail

# Lint every host Rust crate under native/: cargo fmt --check and
# cargo clippy --all-targets -D warnings.
#
# This list is the single source of truth. The pre-commit hook and the CI
# Rust job both run this script, so a crate added here is gated in both
# places at once. server/ is gated by ci-server.yml and its own hooks; the
# wasm plugins by scripts/check-plugins.sh.
#
# Usage: scripts/check-rust.sh [--fix]
#   (default) cargo fmt --check + cargo clippy -D warnings
#   --fix     cargo fmt (rewrite) instead of --check

CRATES=(
  mydia_p2p
  mydia_p2p_core
  mydia_subsync
  mydia_plugin_sdk
  mydia_plugin_macros
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(dirname "$SCRIPT_DIR")/native"

FMT_ARGS=(-- --check)
if [ "${1:-}" = "--fix" ]; then
  FMT_ARGS=()
fi

failed=()

for crate in "${CRATES[@]}"; do
  manifest="$NATIVE_DIR/$crate/Cargo.toml"
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
