#!/usr/bin/env bash
#
# Assert scripts/build-number.sh holds its contract.
#
# Three workflows mint build numbers from this one script, and the ordering
# between tracks is what lets an Android device move from any build to any
# later one: a dev build to the beta, the beta to the stable of the same
# version. A regression here is invisible until a device refuses an install, so
# the ordering is asserted directly rather than inferred from the formula.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/../.."

readonly SCRIPT="scripts/build-number.sh"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

expect() {
  local label="$1" want="$2" got="$3"
  [ "$want" = "$got" ] || note_failure "$label: got '$got', wanted '$want'"
}

expect "stable" 15090000 "$($SCRIPT 0.15.0)"
expect "stable with v prefix" 15090000 "$($SCRIPT v0.15.0)"
expect "patch" 15190000 "$($SCRIPT 0.15.1)"
expect "minor rollover" 16090000 "$($SCRIPT 0.16.0)"
expect "major" 115090000 "$($SCRIPT 1.15.0)"
expect "dev" 15000004 "$($SCRIPT 0.15.0-dev.4)"
expect "dev zero" 15000000 "$($SCRIPT 0.15.0-dev.0)"
expect "alpha" 15011000 "$($SCRIPT 0.15.0-alpha.1)"
expect "beta" 15032000 "$($SCRIPT 0.15.0-beta.2)"
expect "beta no dot" 15032000 "$($SCRIPT 0.15.0-beta2)"
expect "rc" 15061000 "$($SCRIPT 0.15.0-rc.1)"
expect "rc no dot" 8173000 "$($SCRIPT v0.8.1-rc13)"
expect "refresh" 15090002 "$($SCRIPT 0.15.0+refresh.2)"
expect "dev after beta" 16032016 "$($SCRIPT 0.16.0-beta.2.dev.16)"
expect "dev after alpha, top of block" 16011999 "$($SCRIPT 0.16.0-alpha.1.dev.999)"
expect "dev after legacy rc" 16073004 "$($SCRIPT 0.16.0-rc13.dev.4)"
expect "leading zero dev counter" 15000010 "$($SCRIPT 0.15.0-dev.010)"
expect "leading zero that would be invalid octal" 15000008 "$($SCRIPT 0.15.0-dev.08)"
expect "zero padded minor" 15090000 "$($SCRIPT 0.015.0)"
expect "android ceiling" 2099990099 "$($SCRIPT 20.99.9+refresh.99)"

# Ordering is the property that matters, so assert it rather than trusting the
# numbers above to stay in step with each other. Each entry is a build made
# later than the one before it.
ordered=(
  0.16.0-dev.5
  0.16.0-alpha.1
  0.16.0-alpha.1.dev.3
  0.16.0-beta.2
  0.16.0-beta.2.dev.16
  0.16.0-beta.2.dev.17
  0.16.0-beta.3
  0.16.0-rc.1
  0.16.0-rc.1.dev.1
  0.16.0
  0.16.0+refresh.1
  0.17.0-dev.1
)
previous=""
previous_build=0
for version in "${ordered[@]}"; do
  build=$($SCRIPT "$version")
  if [ -n "$previous" ] && [ "$build" -le "$previous_build" ]; then
    note_failure "ordering: $version ($build) should be above $previous ($previous_build)"
  fi
  previous="$version"
  previous_build="$build"
done

# The lowest number the new formula gives any 0.15+ version (0.15.0-dev.0) has
# to clear every number the previous formula could give a 0.x version (it
# topped out below 10M), or an existing Android install cannot update onto the
# new scheme.
[ "$($SCRIPT 0.15.0-dev.0)" -gt 9999999 ] || note_failure "floor: new numbers must clear the old formula's 0.x ceiling"

# Rejections.
for bad in "" "0.15" "0.15.0.1" "banana" "0.15.0-nightly.1" \
  "0.15.0-dev.10000" "0.15.0-alpha.20" "0.15.0-beta.30" "0.15.0-rc.30" \
  "0.15.0-beta.2.dev.0" "0.15.0-beta.2.dev.1000" "0.15.0-beta.2.dev" \
  "0.15.0-dev.1.dev.2" "0.15.0+refresh.0" "0.15.0+refresh.100" "0.15.0+refresh2" \
  "21.0.0" "0.100.0" "0.0.10"; do
  if $SCRIPT "$bad" >/dev/null 2>&1; then
    note_failure "rejection: '$bad' should have failed"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "scripts/build-number.sh: all cases passed"
fi
exit "$fail"
