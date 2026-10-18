#!/usr/bin/env bash
#
# Assert scripts/branch-build-number.sh holds its contract: a branch build's
# TestFlight number sorts above the highest upload and below the next master
# build. The ordering is asserted with sort -V, which compares period-separated
# integers the way App Store Connect does, rather than inferred from the output.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/../.."

readonly SCRIPT="scripts/branch-build-number.sh"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

expect() {
  local label="$1" want="$2" input="$3" got
  got="$("$SCRIPT" "$input" 2>&1)" || got="(failed) $got"
  [ "$want" = "$got" ] || note_failure "$label: got '$got', wanted '$want'"
}

expect_failure() {
  local label="$1" input="$2"
  if "$SCRIPT" "$input" >/dev/null 2>&1; then
    note_failure "$label: should have failed"
  fi
}

# below <a> <b>: a sorts strictly before b, component by component.
expect_below() {
  local label="$1" a="$2" b="$3"
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1)" = "$a" ] \
    || note_failure "$label: '$a' does not sort below '$b'"
}

expect "after a master build" 17000042.1 17000042
expect "after a branch build" 17000042.2 17000042.1
expect "suffix rolls past 9" 17000042.10 17000042.9
expect "leading zeros are not octal" 17000042.9 017000042.08

expect_failure "empty" ""
expect_failure "three components" 17000042.1.1
expect_failure "not a number" abc
expect_failure "trailing dot" 17000042.
expect_failure "prerelease text" 0.17.0-dev.4

branch="$("$SCRIPT" 17000042)"
expect_below "highest upload sorts below the branch build" 17000042 "$branch"
expect_below "branch build sorts below master's next build" "$branch" 17000043
expect_below "a tenth branch build still sorts above the ninth" 17000042.9 17000042.10
expect_below "and still below master's next build" 17000042.10 17000043

if [ "$fail" -eq 0 ]; then
  echo "scripts/branch-build-number.sh: all cases passed"
fi
exit "$fail"
