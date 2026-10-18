#!/usr/bin/env bash
#
# Print the CFBundleVersion for a branch build uploaded to TestFlight.
#
#   scripts/branch-build-number.sh <highest uploaded build number>
#
#   1700042    ->  1700042.1
#   1700042.1  ->  1700042.2
#
# App Store Connect rejects an upload whose CFBundleVersion is not above every
# earlier one (validation error 90061), and compares the period-separated
# integers one by one. A branch build numbered from master's sequence would
# block every later master build below it. Numbered just above the highest
# upload instead, it sits below master's next integer build, which is minted
# from a later first-parent commit and so is always at least L+1.
#
# player-ios.yml calls this while holding the TestFlight upload lock, so the
# highest upload cannot change between the lookup and the upload.
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "branch-build-number: $*" >&2; exit 1; }

highest="${1-}"
[ -n "$highest" ] || die "usage: branch-build-number.sh <highest uploaded build number>"

if [[ "$highest" =~ ^([0-9]+)$ ]]; then
  echo "$(( 10#${BASH_REMATCH[1]} )).1"
elif [[ "$highest" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  echo "$(( 10#${BASH_REMATCH[1]} )).$(( 10#${BASH_REMATCH[2]} + 1 ))"
else
  # Every number this repository mints is an integer or L.n. Anything else was
  # uploaded by hand, and guessing past it risks the collision this avoids.
  die "unexpected build number '$highest'; expected N or N.M"
fi
