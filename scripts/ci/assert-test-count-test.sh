#!/usr/bin/env bash
#
# Assert scripts/ci/assert-test-count.sh holds its contract.
#
# The fixtures copy the shape `flutter test --file-reporter json:<path>`
# writes: a `testStart` carries `test.id` and `test.name` (group names
# prefixed), its `testDone` carries `testID`, `result`, `skipped` and
# `hidden`, a skipped test reports `result: "success"` with `skipped: true`,
# setUpAll and the suite load are `hidden: true`, and a run that finishes
# ends with a `done` event.
#
# Runs on bash 3.2 (macOS) as well as Linux.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/assert-test-count.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
note_failure() {
  echo "FAIL: $*" >&2
  fail=1
}

# start <id> <name>
start() {
  printf '{"test":{"id":%s,"name":"%s","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null}},"type":"testStart","time":0}\n' "$1" "$2"
}

# done_test <id> <result> <skipped> <hidden>
done_test() {
  printf '{"testID":%s,"result":"%s","skipped":%s,"hidden":%s,"type":"testDone","time":0}\n' "$1" "$2" "$3" "$4"
}

header() {
  printf '{"protocolVersion":"0.1.1","runnerVersion":null,"pid":1,"type":"start","time":0}\n'
  start 1 "loading /work/integration_test/all_tests.dart"
  done_test 1 success false true
  start 3 "(setUpAll)"
  done_test 3 success false true
  start 4 "playback (setUpAll)"
  done_test 4 success false true
}

finish() {
  printf '{"success":true,"type":"done","time":0}\n'
}

# Three passing playback tests, one passing test outside the group.
{
  header
  start 5 "playback a local clip decodes and advances"
  done_test 5 success false false
  start 6 "playback the fullscreen button enters and leaves fullscreen"
  done_test 6 success false false
  start 7 "playback closing mid-playback disposes the player"
  done_test 7 success false false
  start 8 "simple app boots"
  done_test 8 success false false
  printf '{"testID":8,"messageType":"print","message":"playback noise","type":"print","time":0}\n'
  finish
} >"$work/enough.json"

# The same, with the third playback test skipped.
{
  header
  start 5 "playback a local clip decodes and advances"
  done_test 5 success false false
  start 6 "playback the fullscreen button enters and leaves fullscreen"
  done_test 6 success false false
  start 7 "playback closing mid-playback disposes the player"
  done_test 7 success true false
  start 8 "simple app boots"
  done_test 8 success false false
  finish
} >"$work/skipped.json"

# A run that crashed: tests passed, but no `done` event.
{
  header
  start 5 "playback a local clip decodes and advances"
  done_test 5 success false false
} >"$work/crashed.json"

# run <expected-exit> <output-must-contain> <description> -- <guard args...>
run() {
  local expected="$1" needle="$2" what="$3"
  shift 4
  local out code=0
  out="$("$guard" "$@" 2>&1)" || code=$?
  if [ "$code" -ne "$expected" ]; then
    note_failure "$what: exit $code, expected $expected; output: $out"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    note_failure "$what: output lacks '$needle'; output: $out"
  fi
}

run 0 "" "enough passes" -- "$work/enough.json" 4
run 1 "playback closing mid-playback disposes the player" \
  "a skip pushes the count below the minimum and is named" -- \
  "$work/skipped.json" 3 "playback "
run 0 "" "the prefix counts only its own tests" -- \
  "$work/enough.json" 3 "playback "
run 1 "3" "the prefix leaves out the test outside it" -- \
  "$work/enough.json" 4 "playback "
run 1 "" "a missing report fails" -- "$work/absent.json" 1
: >"$work/empty.json"
run 1 "" "an empty report fails" -- "$work/empty.json" 0
run 1 "" "a report with no done event fails" -- "$work/crashed.json" 1

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "assert-test-count.sh: all cases pass"
