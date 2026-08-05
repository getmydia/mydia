#!/usr/bin/env bash
# Proves sync-repo.sh uploads in an order that never exposes a summary
# referencing absent objects. Uses a plain ostree repo and rclone's local
# backend, so it needs no runtimes, no network and no flatpak.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
DEST="$WORK/dest"
mkdir -p "$SRC" "$DEST" "$WORK/content"

ostree init --repo="$SRC" --mode=archive
echo "version one" > "$WORK/content/file.txt"
ostree commit --repo="$SRC" --branch=test --tree=dir="$WORK/content" >/dev/null
ostree summary --repo="$SRC" --update

# Pass ordering is observable through the trace the script prints.
TRACE="$("$REPO_ROOT/player/flatpak/sync-repo.sh" "$SRC" "$DEST" 2>&1)"
echo "$TRACE"

objects_line=$(echo "$TRACE" | grep -n 'pass 1' | cut -d: -f1)
summary_line=$(echo "$TRACE" | grep -n 'pass 2' | cut -d: -f1)
delete_line=$(echo "$TRACE" | grep -n 'pass 3' | cut -d: -f1)

[ -n "$objects_line" ] && [ -n "$summary_line" ] && [ -n "$delete_line" ] \
  || { echo "FAIL: all three passes must be traced"; exit 1; }
[ "$objects_line" -lt "$summary_line" ] \
  || { echo "FAIL: objects must upload before the summary"; exit 1; }
[ "$summary_line" -lt "$delete_line" ] \
  || { echo "FAIL: summary must upload before deletions"; exit 1; }

# The destination must be a repo a client can actually resolve.
ostree summary --repo="$DEST" --view >/dev/null \
  || { echo "FAIL: destination summary is not readable"; exit 1; }
ostree fsck --repo="$DEST" >/dev/null \
  || { echo "FAIL: destination repo failed fsck"; exit 1; }
ostree refs --repo="$DEST" | grep -qx test \
  || { echo "FAIL: destination is missing the test ref"; exit 1; }

# A second commit must leave the destination consistent, not orphan the first.
echo "version two" > "$WORK/content/file.txt"
ostree commit --repo="$SRC" --branch=test --tree=dir="$WORK/content" >/dev/null
ostree summary --repo="$SRC" --update
"$REPO_ROOT/player/flatpak/sync-repo.sh" "$SRC" "$DEST" >/dev/null
ostree fsck --repo="$DEST" >/dev/null \
  || { echo "FAIL: destination repo failed fsck after second publish"; exit 1; }

# And the destination must actually carry the new content, not a stale copy.
dest_commit=$(ostree rev-parse --repo="$DEST" test)
src_commit=$(ostree rev-parse --repo="$SRC" test)
[ "$dest_commit" = "$src_commit" ] \
  || { echo "FAIL: destination ref $dest_commit != source $src_commit"; exit 1; }

# Pass 3 must actually delete: plant a stray file and confirm it is removed.
echo stale > "$DEST/stray-object-file"
"$REPO_ROOT/player/flatpak/sync-repo.sh" "$SRC" "$DEST" >/dev/null
[ ! -f "$DEST/stray-object-file" ] \
  || { echo "FAIL: pass 3 did not delete a stale file"; exit 1; }

echo "PASS"
