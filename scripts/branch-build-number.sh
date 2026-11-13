#!/usr/bin/env bash
#
# Print the CFBundleVersion for an on-demand build uploaded to TestFlight.
#
#   scripts/branch-build-number.sh <highest uploaded build number> [<preferred>]
#
#   1700042               ->  1700042.1
#   1700042.1             ->  1700042.2
#   1700042    1700043    ->  1700043     (preferred clears the highest)
#   19031000   19000015   ->  19031000.1  (preferred is behind it)
#
# App Store Connect rejects an upload whose CFBundleVersion is not above every
# earlier one (validation error 90061), and compares the period-separated
# integers one by one. A branch build numbered from master's sequence would
# block every later master build below it. Numbered just above the highest
# upload instead, it sits below master's next integer build, which is minted
# from a later first-parent commit and so is always at least L+1.
#
# <preferred> is a master build's version-derived number. It is used as is
# when it clears the highest upload; otherwise the build goes just above the
# highest upload, as a branch build does. That happens while a release is a
# draft: its build is already on TestFlight, but its tag, which master's dev
# builds anchor on, only exists once it is published, so a master dev build
# derives a number below it.
#
# player-ios.yml calls this while holding the TestFlight upload lock, so the
# highest upload cannot change between the lookup and the upload.
set -euo pipefail
export LC_ALL=C.UTF-8

die() { echo "branch-build-number: $*" >&2; exit 1; }

highest="${1-}"
preferred="${2-}"
[ -n "$highest" ] || die "usage: branch-build-number.sh <highest uploaded build number> [<preferred>]"

if [[ "$highest" =~ ^([0-9]+)$ ]]; then
  base=$(( 10#${BASH_REMATCH[1]} ))
  next="${base}.1"
elif [[ "$highest" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  base=$(( 10#${BASH_REMATCH[1]} ))
  next="${base}.$(( 10#${BASH_REMATCH[2]} + 1 ))"
else
  # Every number this repository mints is an integer or L.n. Anything else was
  # uploaded by hand, and guessing past it risks the collision this avoids.
  die "unexpected build number '$highest'; expected N or N.M"
fi

if [ -n "$preferred" ]; then
  [[ "$preferred" =~ ^[0-9]+$ ]] || die "preferred build number must be an integer: '$preferred'"
  # An integer P sorts above both N and N.M exactly when P > N.
  if [ $(( 10#$preferred )) -gt "$base" ]; then
    echo "$(( 10#$preferred ))"
    exit 0
  fi
fi

echo "$next"
