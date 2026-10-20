#!/usr/bin/env bash
# Negative and positive checks for scripts/check-rust-lints.sh, run against a
# throwaway copy of the repo's manifests so the real tree is never edited.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

copy_tree() {
  (cd "$ROOT" && git ls-files -- '*Cargo.toml' rust-lints.toml clippy.toml scripts/check-rust-lints.sh scripts/check_rust_lints.py) |
    while read -r f; do mkdir -p "$TMP/$(dirname "$f")"; cp "$ROOT/$f" "$TMP/$f"; done
}

copy_tree
"$TMP/scripts/check-rust-lints.sh" >/dev/null || { echo "FAIL: clean tree rejected"; exit 1; }

# Dropping a canonical entry from one crate must fail.
sed -i '/^unwrap_used = /d' "$TMP/native/mydia_subsync/Cargo.toml"
if "$TMP/scripts/check-rust-lints.sh" >/dev/null 2>&1; then echo "FAIL: missing entry accepted"; exit 1; fi
copy_tree

# Weakening a value must fail.
sed -i 's/^unsafe_code = "deny"/unsafe_code = "warn"/' "$TMP/plugins/plex/Cargo.toml"
if "$TMP/scripts/check-rust-lints.sh" >/dev/null 2>&1; then echo "FAIL: weakened entry accepted"; exit 1; fi
copy_tree

# A server member without `[lints] workspace = true` must fail.
sed -i '/^\[lints\]$/,/^workspace = true$/d' "$TMP/server/crates/db/Cargo.toml"
if "$TMP/scripts/check-rust-lints.sh" >/dev/null 2>&1; then echo "FAIL: unlinked member accepted"; exit 1; fi
copy_tree

# A second clippy.toml must fail.
cp "$TMP/clippy.toml" "$TMP/server/clippy.toml"
if "$TMP/scripts/check-rust-lints.sh" >/dev/null 2>&1; then echo "FAIL: nested clippy.toml accepted"; exit 1; fi

echo "check-rust-lints: all cases pass"
