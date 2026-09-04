#!/usr/bin/env bash
#
# Assert scripts/ios-refresh-due.sh holds its contract.
#
# The refresh workflow this feeds cannot be dispatched, scheduled or exercised
# in any way until it is on the default branch, because workflow_dispatch only
# triggers for a file that exists there and schedules only run there. So the
# decision it makes is tested here instead, where a pull request can see it.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/.."

readonly SCRIPT="scripts/ios-refresh-due.sh"

# The marker-path case below creates a real tag, so cleanup has to cover it even
# when an assertion fails partway through.
#
# The date is far in the future because newest_marker() returns the greatest
# dated marker across ALL ios-refresh/* refs, not just this probe. Once the
# refresh workflow ships, real markers accumulate permanently, and a probe dated
# in the past would lose to the first real one and fail this suite on every run
# from then on. 9999-12-31 wins forever.
readonly MARKER_PROBE="ios-refresh/9999-12-31"
trap 'git tag -d "$MARKER_PROBE" >/dev/null 2>&1 || true' EXIT

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

# A synthetic world: today, the newest stable release as "tag date", and the
# newest refresh marker as "tag date" or empty for none. Echoes one output key.
run_case() {
  IOS_REFRESH_TODAY="$1" IOS_REFRESH_STABLE="$2" IOS_REFRESH_MARKER="$3" \
    "$SCRIPT" 2>/dev/null | sed -n "s/^$4=//p"
}

expect() {
  [ "$3" = "$2" ] || note_failure "$1: got '$3', wanted '$2'"
}

# v0.13.2 is a real tag, so sha resolution is exercised rather than stubbed.
readonly REAL_TAG=v0.13.2

expect "a release yesterday is not due" false \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-09-03" "" due)"

# Strictly greater, so the threshold does not fire a day early.
expect "exactly 60 days is not due" false \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-07-06" "" due)"
expect "61 days is due" true \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-07-05" "" due)"

# The case a "last successful workflow run" baseline gets wrong.
expect "a recent refresh holds off a build" false \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-01-01" "ios-refresh/2026-08-20 2026-08-20" due)"
expect "an ancient refresh does not" true \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-01-01" "ios-refresh/2026-02-01 2026-02-01" due)"
expect "a release newer than the marker wins" false \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-09-01" "ios-refresh/2026-02-01 2026-02-01" due)"

expect "age is measured" 61 \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-07-05" "" age_days)"

# pubspec.yaml and CFBundleShortVersionString both want a bare number.
expect "version drops the leading v" 0.13.2 \
  "$(run_case 2026-09-04 "$REAL_TAG 2026-07-05" "" version)"

# A real marker tag, reaching newest_marker() for real. Every case above
# overrides IOS_REFRESH_MARKER and so never executes that function at all, which
# is how a real bug survived a full green suite once already.
#
# Asserted on baseline_date, not on due. The probe names 9999-12-31 but points
# at HEAD, whose commit date is recent, so the two implementations disagree on
# exactly one observable: reading the date from the tag's NAME gives a baseline
# of 9999-12-31, while reading any git date field gives HEAD's committer date.
# Both make `due` false, so asserting on `due` here would pass under the bug and
# test nothing. That is not hypothetical: it is the shape of the defect this
# case exists to catch.
git tag -f "$MARKER_PROBE" HEAD >/dev/null 2>&1

marker_baseline="$(IOS_REFRESH_TODAY=2026-09-04 IOS_REFRESH_STABLE="$REAL_TAG 2026-01-01" \
  "$SCRIPT" 2>/dev/null | sed -n 's/^baseline_date=//p')"
expect "the marker date is read from the tag name, not a git date" \
  9999-12-31 "$marker_baseline"

git tag -d "$MARKER_PROBE" >/dev/null 2>&1 || true

# The real repository, with only today pinned. Proves the git queries work
# against real refs rather than only against synthetic strings, and that the
# prerelease exclusion holds: there are v0.14.0-beta.* tags newer than the
# newest stable one, so a broken filter fails here.
out="$(IOS_REFRESH_TODAY=2026-09-04 "$SCRIPT" 2>/dev/null)"
real_tag="$(sed -n 's/^tag=//p' <<<"$out")"
real_sha="$(sed -n 's/^sha=//p' <<<"$out")"

case "$real_tag" in
  v*) : ;;
  *) note_failure "real repo: tag '${real_tag}' does not look like a release tag" ;;
esac
case "$real_tag" in
  *-beta*|*-rc*|*-alpha*) note_failure "real repo: picked prerelease tag ${real_tag}" ;;
esac
[ "${#real_sha}" -eq 40 ] || note_failure "real repo: sha '${real_sha}' is not a full SHA"

[ "$fail" -eq 0 ] || exit 1
echo "ios refresh decision: all cases pass"
