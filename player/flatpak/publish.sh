#!/usr/bin/env bash
# Publishes a staged Flatpak build into a live channel repo.
#
# Reads the live repo down, commits the staged build into it, signs, prunes,
# regenerates the summary, then uploads with sync-repo.sh.
#
# Usage: player/flatpak/publish.sh <channel> <staged-repo> <rclone-dest>
# Requires: GPG_KEY_ID in the environment.
set -euo pipefail

CHANNEL="${1:?channel required (stable or beta)}"
STAGED="${2:?staged repo path required}"
DEST="${3:?rclone destination required}"
: "${GPG_KEY_ID:?GPG_KEY_ID must be set}"

case "$CHANNEL" in
  stable) PRUNE_DEPTH=5 ;;
  beta)   PRUNE_DEPTH=2 ;;
  *) echo "::error::unknown channel '$CHANNEL', expected stable or beta" >&2; exit 1 ;;
esac

LIVE="${LIVE_REPO_DIR:-./live-repo}"

echo "publish: syncing $DEST down to $LIVE"
mkdir -p "$LIVE"
rclone sync "$DEST" "$LIVE" --create-empty-src-dirs \
  --transfers 32 --checkers 32 --retries 5

# Creates the repo on a first publish, when $DEST is still empty. Safe on an
# existing repo: ostree init leaves the config and objects alone. It does NOT
# repair a repo whose empty directories the sync dropped, which is what
# ensure-skeleton.sh below is for.
ostree init --repo="$LIVE" --mode=archive

"$(dirname "${BASH_SOURCE[0]}")/ensure-skeleton.sh" "$LIVE"

echo "publish: committing the staged build into $LIVE"
flatpak build-commit-from \
  --src-repo="$STAGED" \
  --gpg-sign="$GPG_KEY_ID" \
  "$LIVE"

echo "publish: updating summary, generating deltas, pruning to depth $PRUNE_DEPTH"
flatpak build-update-repo \
  --generate-static-deltas \
  --prune --prune-depth="$PRUNE_DEPTH" \
  --gpg-sign="$GPG_KEY_ID" \
  "$LIVE"

echo "publish: refs now in $LIVE"
ostree refs --repo="$LIVE"

"$(dirname "${BASH_SOURCE[0]}")/sync-repo.sh" "$LIVE" "$DEST"

echo "publish: $CHANNEL published to $DEST"
