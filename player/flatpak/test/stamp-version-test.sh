#!/usr/bin/env bash
# Verifies stamp-version.sh rewrites both the pubspec version and the
# metainfo release entry, operating on a throwaway copy of the tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/player/flatpak"
cp "$REPO_ROOT/player/pubspec.yaml" "$WORK/player/pubspec.yaml"
cp "$REPO_ROOT/player/flatpak/dev.mydia.player.metainfo.xml" \
   "$WORK/player/flatpak/dev.mydia.player.metainfo.xml"

(cd "$WORK" && "$REPO_ROOT/player/flatpak/stamp-version.sh" 1.2.3 10042 2026-08-04)

grep -q '^version: 1\.2\.3+10042$' "$WORK/player/pubspec.yaml" \
  || { echo "FAIL: pubspec version not stamped"; exit 1; }

grep -q '<release version="1.2.3" date="2026-08-04"/>' \
     "$WORK/player/flatpak/dev.mydia.player.metainfo.xml" \
  || { echo "FAIL: metainfo release not stamped"; exit 1; }

# The committed placeholder must be gone, not merely joined by a second entry.
# Note this is `! grep -q`, not `grep -qv`: the latter passes whenever any
# single line fails to match, which is true of almost every file.
if grep -q '0\.0\.0' "$WORK/player/flatpak/dev.mydia.player.metainfo.xml"; then
  echo "FAIL: placeholder 0.0.0 release still present"
  exit 1
fi

# Running twice must be idempotent, so a re-run of a release job cannot stack
# release entries.
(cd "$WORK" && "$REPO_ROOT/player/flatpak/stamp-version.sh" 1.2.3 10042 2026-08-04)
count=$(grep -c '<release ' "$WORK/player/flatpak/dev.mydia.player.metainfo.xml")
[ "$count" -eq 1 ] || { echo "FAIL: expected 1 release entry, got $count"; exit 1; }

echo "PASS"
