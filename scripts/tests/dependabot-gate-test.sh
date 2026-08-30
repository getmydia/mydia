#!/usr/bin/env bash
#
# Tests for scripts/dependabot-gate.sh. No network: every case reads a fixture.
set -euo pipefail

# The blocking-context assertion compares a sorted list. jq's `sort` is by
# codepoint, but glibc's en_US.UTF-8 collation folds case and would order
# "Build / macOS" before "Build / Web", so `sort` below must not disagree with
# the jq sort inside the script. Pin the locale rather than hope the runner's
# matches this machine's.
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/../dependabot-gate.sh"
fixtures="$here/fixtures"

failures=0

assert_verdict() {
  local fixture="$1" expected="$2" actual
  actual="$("$gate" verdict < "$fixtures/$fixture" | cut -f1)"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $fixture -> $expected"
  else
    echo "FAIL $fixture -> expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

assert_blocked_names() {
  local fixture="$1" expected="$2" actual
  actual="$("$gate" verdict < "$fixtures/$fixture" | cut -f2- | tr '\t' '\n' | cut -d= -f1 | sort | paste -sd, -)"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $fixture blocking contexts"
  else
    echo "FAIL $fixture blocking contexts" >&2
    echo "       expected: $expected" >&2
    echo "       actual:   $actual" >&2
    failures=$((failures + 1))
  fi
}

assert_verdict rollup-merge.json   MERGE
assert_verdict rollup-blocked.json BLOCKED
assert_verdict rollup-pending.json WAIT
assert_verdict rollup-empty.json   WAIT
assert_verdict rollup-null.json    WAIT

# PR #613's seven red contexts, alphabetically. This is the regression: every
# one of them was visible and none of them was required.
assert_blocked_names rollup-blocked.json \
  "Build / Android,Build / Linux,Build / Web,Build / Windows,Build / macOS,Flatpak / Build,Test / Player"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
