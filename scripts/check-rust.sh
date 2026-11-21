#!/usr/bin/env bash
set -uo pipefail

# Lint every host Rust crate under native/ and player/rust/: cargo fmt --check
# and cargo clippy --all-targets -D warnings.
#
# Crates are discovered by glob, so a new crate is gated by the pre-commit hook
# without editing a list. CI runs the same fmt/clippy/test commands as Nix
# checks, and their crate list is mirrored in nix/ci/rust.nix: a new crate
# needs an entry there too (the ci-crate-list check enforces it).
#
# Usage: scripts/check-rust.sh [--fix | --list]
#   (default) cargo fmt --check + cargo clippy -D warnings
#   --fix     cargo fmt (rewrite) instead of --check
#   --list    print each crate directory, relative to the repo root, and exit
#             (the ci-crate-list check compares it with nix/ci/rust.nix)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every host crate under native/ and player/rust/. cardigann_guest is a .NET
# wasm guest with its own pipeline (cardigann-guest.yml), not a cargo crate we
# lint here. server/ has its own rust-server-* checks in nix/ci/rust.nix and
# its own hooks; the wasm plugins are linted by scripts/check-plugins.sh.
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS=()
for manifest in "$ROOT_DIR"/native/*/Cargo.toml "$ROOT_DIR"/player/rust/*/Cargo.toml; do
  case "$manifest" in */native/cardigann_guest/*) continue ;; esac
  [ -e "$manifest" ] || continue
  MANIFESTS+=("$manifest")
done

if [ "${1:-}" = "--list" ]; then
  for manifest in "${MANIFESTS[@]}"; do
    dir="$(dirname "$manifest")"
    echo "${dir#"$ROOT_DIR"/}"
  done
  exit 0
fi

FMT_ARGS=(-- --check)
if [ "${1:-}" = "--fix" ]; then
  FMT_ARGS=()
fi

failed=()

for manifest in "${MANIFESTS[@]}"; do
  crate="$(basename "$(dirname "$manifest")")"
  echo "==> $crate"
  cargo fmt --manifest-path "$manifest" --all "${FMT_ARGS[@]}" || failed+=("$crate (fmt)")
  cargo clippy --manifest-path "$manifest" --all-targets --all-features -- -D warnings || failed+=("$crate (clippy)")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "Rust checks failed:"
  printf '  %s\n' "${failed[@]}"
  echo "Run scripts/check-rust.sh --fix for formatting; clippy findings need a code fix."
  exit 1
fi
