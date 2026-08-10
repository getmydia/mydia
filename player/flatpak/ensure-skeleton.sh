#!/usr/bin/env bash
# Recreates the empty directories an ostree repo needs, then proves they exist.
#
# Usage: player/flatpak/ensure-skeleton.sh <repo>
#
# An ostree repo is full of directories that survive a build empty: refs/remotes,
# refs/mirrors, extensions, state and tmp/cache. Two things in the release path
# carry a repo from one place to another and neither preserves an empty
# directory:
#
#   1. upload-artifact / download-artifact, for the staged repo.
#   2. rclone against object storage, for the live repo. R2 has no directories
#      at all, only keys, so an empty one cannot be stored and
#      --create-empty-src-dirs has nothing to recreate it from.
#
# Whichever path dropped them, the first command to read the repo dies with
# "Listing refs: opendir(refs/remotes): No such file or directory".
#
# mkdir, not `ostree init`. Whether init repairs an existing repo is version
# dependent: libostree 2026.2 recreates the missing skeleton, but the 2024.5 on
# ubuntu-latest returns 0 and changes nothing, so the repair silently does not
# happen. That is what failed the flatpak publish on v0.13.0-beta.5 (staged
# repo, fixed inline in release.yml) and again on v0.13.1 (live repo, which had
# an `ostree init` that was believed to cover this and did not).
#
# The whole skeleton is recreated rather than just the subset a given path
# happens to drop, because mkdir -p on a directory that already exists costs
# nothing and does not require reasoning about which refs a build produced.
# refs/heads normally survives, in that it holds the app ref; it is listed for
# that reason, not because it is expected to be missing.
#
# objects/ is deliberately NOT created. It always carries content, so its
# absence means a broken transfer rather than a dropped empty directory, and
# creating it would paper over that and defer the failure into flatpak. It is
# asserted instead, so the break is reported here and names itself.
set -euo pipefail

REPO="${1:?repo path required}"

DIRS=(refs/heads refs/mirrors refs/remotes extensions state tmp/cache)

for d in "${DIRS[@]}"; do
  mkdir -p "$REPO/$d"
done

# Fail here rather than inside flatpak build-commit-from or build-update-repo,
# where the same problem surfaces as an opaque refs error.
for d in "${DIRS[@]}"; do
  test -d "$REPO/$d" || { echo "::error::$REPO/$d missing" >&2; exit 1; }
done

# Gated on config, which is a file and therefore survives every transfer. Its
# presence is what distinguishes an existing repo, where objects/ must be
# there, from a first publish against an empty directory, where nothing has
# been initialised yet and its absence is expected.
if [ -e "$REPO/config" ] && [ ! -d "$REPO/objects" ]; then
  echo "::error::$REPO/objects is missing from a repo that has a config. That is a broken transfer, not a dropped empty directory." >&2
  exit 1
fi

echo "skeleton: $REPO ok"
