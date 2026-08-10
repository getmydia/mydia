#!/usr/bin/env bash
# Proves ensure-skeleton.sh repairs a repo whose empty directories were dropped
# in transit, which is what object storage and the artifact round trip both do.
# Needs nothing but bash: the script under test is mkdir and test -d.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/player/flatpak/ensure-skeleton.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SKELETON=(refs/mirrors refs/remotes extensions state tmp/cache)

# What comes back from `rclone sync r2:... ./live-repo`: every directory that
# held an object, and none of the ones that were empty. R2 stores keys, not
# directories, so an empty directory cannot round trip and
# --create-empty-src-dirs has nothing to recreate it from.
REPO="$WORK/live-repo"
mkdir -p "$REPO/objects/ab" "$REPO/refs/heads"
echo "config" > "$REPO/config"
echo "object" > "$REPO/objects/ab/cdef.filez"
echo "commit" > "$REPO/refs/heads/app"

for d in "${SKELETON[@]}"; do
  [ ! -d "$REPO/$d" ] \
    || { echo "FAIL: fixture should not already have $d"; exit 1; }
done

"$SCRIPT" "$REPO" >/dev/null

for d in refs/heads "${SKELETON[@]}"; do
  test -d "$REPO/$d" \
    || { echo "FAIL: $d missing after repair"; exit 1; }
done

# The repair must not disturb what the sync did bring down.
[ -f "$REPO/config" ] || { echo "FAIL: config was lost"; exit 1; }
[ -f "$REPO/objects/ab/cdef.filez" ] || { echo "FAIL: object was lost"; exit 1; }
[ "$(cat "$REPO/refs/heads/app")" = "commit" ] \
  || { echo "FAIL: existing ref was clobbered"; exit 1; }

# Idempotent: the release path runs this on repos that are already intact.
"$SCRIPT" "$REPO" >/dev/null
[ "$(cat "$REPO/refs/heads/app")" = "commit" ] \
  || { echo "FAIL: second run clobbered an existing ref"; exit 1; }

# A first publish starts from an empty directory and must also come out whole.
FRESH="$WORK/fresh"
mkdir -p "$FRESH"
"$SCRIPT" "$FRESH" >/dev/null
for d in refs/heads "${SKELETON[@]}"; do
  test -d "$FRESH/$d" || { echo "FAIL: $d missing on a fresh repo"; exit 1; }
done

# The guard must fail loudly rather than let an unusable repo through to
# flatpak, where the same problem surfaces as an opaque refs error. A regular
# file where a directory belongs is the deterministic way to make mkdir -p fail.
BROKEN="$WORK/broken"
mkdir -p "$BROKEN"
touch "$BROKEN/refs"
if "$SCRIPT" "$BROKEN" >/dev/null 2>&1; then
  echo "FAIL: a repo that cannot be repaired must exit non-zero"
  exit 1
fi

echo "PASS"
