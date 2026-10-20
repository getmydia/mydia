#!/usr/bin/env bash
# Fail when a first-party Rust crate's [lints] drifts from rust-lints.toml.
# Run by the rust-lints pre-commit hook and CI's Guards job.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/check_rust_lints.py" "$ROOT"
