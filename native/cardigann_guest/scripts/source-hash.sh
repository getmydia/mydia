#!/usr/bin/env bash
# Prints the 16-hex-char source hash that names the prebuilt guest artifact.
# Must equal Mydia.Indexers.Cardigann.Wasm.SourceHash.source_hash/0; a test
# (test/mydia/indexers/cardigann/wasm/artifact_test.exs) fails when they drift.
#
# Every tracked file under native/cardigann_guest feeds the hash except build
# output, docs (*.md, so doc edits never force a 76 MB rebuild) and the
# ARTIFACT_SHA256 pin (which records the hash, so it cannot be part of it).
# Keep the exclusion regex in step with SourceHash.@excluded.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git ls-files -- native/cardigann_guest \
  | grep -v -E '/\.prowlarr/|/out/|/bin/|/obj/|/deny/target/|/deny/gen/|\.md$|/ARTIFACT_SHA256$' \
  | LC_ALL=C sort \
  | while IFS= read -r f; do printf '%s\0' "$f"; cat "$f"; done \
  | sha256sum | cut -c1-16
