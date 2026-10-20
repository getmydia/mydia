#!/usr/bin/env bash
set -uo pipefail

# Run the test suite of every WASM plugin crate under plugins/ and plugins-extra/.
#
# Plugin tests run on the host (plain `cargo test`, no --target), exactly as
# .github/workflows/plugins-publish.yml does for plugins-extra/. Crates with
# Node tests under test/*.test.mjs get those run too.
#
# Usage: scripts/test-plugins.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

found=0
failed=()
for manifest in "$PROJECT_ROOT"/plugins/*/Cargo.toml "$PROJECT_ROOT"/plugins-extra/*/Cargo.toml; do
  [ -e "$manifest" ] || continue
  found=1
  crate_dir="$(dirname "$manifest")"
  crate="$(basename "$crate_dir")"
  echo "==> $crate"

  cargo test --manifest-path "$manifest" || failed+=("$crate (cargo test)")

  node_tests=("$crate_dir"/test/*.test.mjs)
  if [ -e "${node_tests[0]}" ]; then
    node --test "${node_tests[@]}" || failed+=("$crate (node test)")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "Plugin tests failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

if [ "$found" -eq 0 ]; then
  echo "No plugin crates found under plugins/ or plugins-extra/."
fi
