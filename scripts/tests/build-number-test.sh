#!/usr/bin/env bash
#
# Assert scripts/build-number.sh holds its contract.
#
# Three workflows mint build numbers from this one script, and the ordering
# between tracks is what lets an Android device move from a dev build to the
# beta and then to the stable of the same version. A regression here is
# invisible until a device refuses an install, so the ordering is asserted
# directly rather than inferred from the formula.
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

expect "stable" 1500900 "$($SCRIPT 0.15.0)"
expect "stable with v prefix" 1500900 "$($SCRIPT v0.15.0)"
expect "patch" 1501900 "$($SCRIPT 0.15.1)"
expect "minor rollover" 1600900 "$($SCRIPT 0.16.0)"
expect "major" 11500900 "$($SCRIPT 1.15.0)"
expect "dev" 1500004 "$($SCRIPT 0.15.0-dev.4)"
expect "dev zero" 1500000 "$($SCRIPT 0.15.0-dev.0)"
expect "alpha" 1500301 "$($SCRIPT 0.15.0-alpha.1)"
expect "beta" 1500502 "$($SCRIPT 0.15.0-beta.2)"
expect "beta no dot" 1500502 "$($SCRIPT 0.15.0-beta2)"
expect "rc" 1500701 "$($SCRIPT 0.15.0-rc.1)"
expect "rc no dot" 801713 "$($SCRIPT v0.8.1-rc13)"
expect "refresh" 1500902 "$($SCRIPT 0.15.0+refresh.2)"
expect "leading zero dev counter" 1500010 "$($SCRIPT 0.15.0-dev.010)"
expect "leading zero that would be invalid octal" 1500008 "$($SCRIPT 0.15.0-dev.08)"
expect "leading zero version field" 1500900 "$($SCRIPT 0.15.0)"
expect "zero padded minor" 1500900 "$($SCRIPT 0.015.0)"

# Ordering is the property that matters, so assert it rather than trusting the
# numbers above to stay in step with each other.
dev=$($SCRIPT 0.15.0-dev.4)
alpha=$($SCRIPT 0.15.0-alpha.1)
beta=$($SCRIPT 0.15.0-beta.2)
rc=$($SCRIPT 0.15.0-rc.1)
stable=$($SCRIPT 0.15.0)
refresh=$($SCRIPT 0.15.0+refresh.1)
next_dev=$($SCRIPT 0.16.0-dev.1)
[ "$dev" -lt "$alpha" ] || note_failure "ordering: dev $dev should be below alpha $alpha"
[ "$alpha" -lt "$beta" ] || note_failure "ordering: alpha $alpha should be below beta $beta"
[ "$beta" -lt "$rc" ] || note_failure "ordering: beta $beta should be below rc $rc"
[ "$rc" -lt "$stable" ] || note_failure "ordering: rc $rc should be below stable $stable"
[ "$stable" -lt "$refresh" ] || note_failure "ordering: stable $stable should be below refresh $refresh"
[ "$refresh" -lt "$next_dev" ] || note_failure "ordering: refresh $refresh should be below next dev $next_dev"

# Every value has to clear the highest number ever published, or an existing
# install cannot update onto the new scheme. 500020 is the on-demand high
# water mark (run_number + 500000); 10093 is release.yml's.
[ "$($SCRIPT 0.15.0-dev.0)" -gt 500020 ] || note_failure "floor: dev must clear the on-demand high water mark"

# Rejections.
for bad in "" "0.15" "0.15.0.1" "banana" "0.15.0-nightly.1" "0.15.0-dev.300" "0.15.0-alpha.200" "0.15.0-beta.200" "0.15.0-rc.200" "0.15.0+refresh.100"; do
  if $SCRIPT "$bad" >/dev/null 2>&1; then
    note_failure "rejection: '$bad' should have failed"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "scripts/build-number.sh: all cases passed"
fi
exit "$fail"
