#!/usr/bin/env bash
#
# Print the version an on-demand player build carries.
#
#   scripts/ondemand-version.sh [--mainline <ref>] <commit>
#
# With --mainline, the commit must be on <ref>'s first-parent history. A branch
# build counts its own commits, so it would outrank the master build made after
# the branch merges (a merge is one first-parent step); publishing it is refused.
#
# The version is anchored on the nearest release tag the commit descends from,
# so a dev build sorts above the release it follows and below the next one:
#
#   after v0.16.0-beta.2   ->  0.16.0-beta.2.dev.K
#   after v0.16.0          ->  0.17.0-dev.K
#
# K is the number of first-parent commits from the tag to the commit. Every
# merge to master adds one, so a later master build always gets a higher
# number. Building the tag commit itself is refused: that build is the
# release. scripts/build-number.sh turns the version into a build number.
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "ondemand-version: $*" >&2; exit 1; }

usage="usage: ondemand-version.sh [--mainline <ref>] <commit>"
mainline=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mainline)
      [ $# -ge 2 ] || die "$usage"
      mainline="$2"
      shift 2
      ;;
    *) break ;;
  esac
done

commit="${1-}"
[ -n "$commit" ] || die "$usage"
sha=$(git rev-parse --verify --quiet "${commit}^{commit}") || die "not a commit: $commit"

if [ -n "$mainline" ]; then
  git rev-parse --verify --quiet "${mainline}^{commit}" >/dev/null || die "not a commit: $mainline"
  # A here-string, not a pipe: grep -q exits on the first match, and whatever
  # was still writing into a pipe (master's list is past the 64 KiB pipe
  # buffer) would die of SIGPIPE and fail the check under pipefail.
  history=$(git rev-list --first-parent "$mainline")
  grep -qxF "$sha" <<< "$history" \
    || die "$commit is not on $mainline's first-parent history; use dry_run, or version_override to publish it deliberately"
fi

# Release tags are cut on master's first-parent line. Both the anchor lookup
# and the count below follow first parents only, so a tag that exists only on
# a merged side branch (a hotfix, say) is never the anchor, and the count from
# the anchor grows with every merge.
# Player release tags only: plugins-v* and metadata-relay-v* do not match.
if anchor=$(git describe --tags --first-parent --match 'v[0-9]*' --abbrev=0 "$commit" 2>/dev/null); then
  k=$(git rev-list --first-parent --count "${anchor}..${commit}")
else
  anchor="v0.0.0"
  k=$(git rev-list --first-parent --count "$commit")
fi

[ "$k" -ge 1 ] || die "$commit is $anchor itself; use that release instead of an on-demand build"

release="${anchor#v}"
core="${release%%-*}"
[[ "$core" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "anchor $anchor is not major.minor.patch"

if [ "$release" = "$core" ]; then
  echo "${BASH_REMATCH[1]}.$(( 10#${BASH_REMATCH[2]} + 1 )).0-dev.${k}"
else
  suffix="$(printf '%s' "${release#*-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$suffix" =~ ^(alpha|beta|rc)\.?([0-9]+)$ ]] \
    || die "anchor $anchor has a prerelease suffix a dev build cannot follow"
  echo "${core}-${BASH_REMATCH[1]}.$(( 10#${BASH_REMATCH[2]} )).dev.${k}"
fi
