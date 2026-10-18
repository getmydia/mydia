#!/usr/bin/env bash
#
# Exit 0 when a commit is on a ref's first-parent history, 1 when it is not.
#
#   scripts/on-mainline.sh <ref> <commit>
#
# A commit on master's first-parent line is a master build. Anything else (an
# unmerged branch tip, or a commit reachable only through a merged side branch)
# is a branch build: player-ondemand.yml keeps it off every shared channel, and
# ondemand-version.sh --mainline refuses to version it. Any other failure (an
# unresolvable ref or commit) exits 2, so a caller can tell "off mainline" from
# "could not tell".
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "on-mainline: $*" >&2; exit 2; }

[ $# -eq 2 ] || die "usage: on-mainline.sh <ref> <commit>"
mainline="$1"
commit="$2"

git rev-parse --verify --quiet "${mainline}^{commit}" >/dev/null || die "not a commit: $mainline"
sha=$(git rev-parse --verify --quiet "${commit}^{commit}") || die "not a commit: $commit"

# A here-string, not a pipe: grep -q exits on the first match, and whatever
# was still writing into a pipe (master's list is past the 64 KiB pipe
# buffer) would die of SIGPIPE and fail the check under pipefail.
history=$(git rev-list --first-parent "$mainline")
grep -qxF "$sha" <<< "$history"
