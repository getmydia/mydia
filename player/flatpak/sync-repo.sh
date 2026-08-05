#!/usr/bin/env bash
# Uploads an OSTree repo to an rclone destination in three ordered passes.
#
# The ordering is the whole point. A client reads the summary first and then
# fetches what it names, so the summary must never arrive before the objects it
# references, and pruned objects must not vanish before the summary that
# stopped referencing them.
#
#   pass 1  objects and deltas, additive only
#   pass 2  refs, summary, summary signature
#   pass 3  delete whatever pruning removed
#
# --create-empty-src-dirs is not optional. `ostree init` creates an empty
# refs/heads, refs/mirrors and refs/remotes skeleton, and rclone skips empty
# directories by default. Without the flag the destination fails `ostree fsck`
# with opendir(refs/remotes), and pass 3 would delete any skeleton that pass 1
# did manage to create. That matters because publish.sh syncs this destination
# back down and runs ostree against it.
#
# Usage: player/flatpak/sync-repo.sh <local-repo> <rclone-dest>
set -euo pipefail

SRC="${1:?local repo path required}"
DEST="${2:?rclone destination required}"

[ -f "$SRC/config" ] || { echo "::error::$SRC is not an ostree repo" >&2; exit 1; }

echo "sync-repo: pass 1, objects and deltas -> $DEST"
rclone copy "$SRC" "$DEST" \
  --exclude '/summary' --exclude '/summary.sig' --exclude '/refs/**' \
  --create-empty-src-dirs \
  --transfers 32 --checkers 32 --retries 5

echo "sync-repo: pass 2, refs and summary -> $DEST"
rclone copy "$SRC" "$DEST" \
  --include '/summary' --include '/summary.sig' --include '/refs/**' \
  --create-empty-src-dirs \
  --transfers 8 --checkers 8 --retries 5

echo "sync-repo: pass 3, delete pruned objects at $DEST"
rclone sync "$SRC" "$DEST" \
  --create-empty-src-dirs \
  --transfers 32 --checkers 32 --retries 5

echo "sync-repo: done"
