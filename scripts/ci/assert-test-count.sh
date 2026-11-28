#!/usr/bin/env bash
#
# Fails unless a `flutter test` run passed at least a pinned number of tests.
#
#   assert-test-count.sh <reporter.json> <min-passed> [name-prefix]
#
# <reporter.json> is what `flutter test --file-reporter json:<path>` writes:
# one JSON event per line. A test counts when its `testDone` has
# `result: "success"`, `skipped: false` and `hidden: false` (setUpAll,
# tearDownAll and the suite load are hidden). Its name comes from its
# `testStart`, with the names of its groups in front, so a prefix of
# "playback " selects the tests of the `playback` group.
#
# A skipped test still exits 0 from `flutter test`, and so does a test that
# returns early, which is what this exists to catch: a suite that quietly
# stopped testing something keeps passing unless someone pins the count.
#
# Exits 0 when the count reaches the minimum. Exits 1 printing the count, the
# minimum and the names of the skipped and failed tests when it does not, and
# also when the report is missing, empty, unreadable, or has no `done` event
# (the run crashed before it finished).
#
# Runs on bash 3.2 and BSD userland (macOS runners) as well as Linux; needs
# jq.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <reporter.json> <min-passed> [name-prefix]" >&2
  exit 2
fi

report="$1"
min="$2"
prefix="${3:-}"

case "$min" in
'' | *[!0-9]*)
  echo "assert-test-count: minimum must be a whole number, got '$min'" >&2
  exit 2
  ;;
esac

if [ ! -s "$report" ]; then
  echo "assert-test-count: no test report at $report (missing or empty); the run did not get as far as testing" >&2
  exit 1
fi

# One line saying whether the run finished, one with the passed count, then
# one line per skipped (S) or failed (F) test.
summary_code=0
summary="$(jq -s -r --arg prefix "$prefix" '
  . as $events
  | ($events
      | map(select(.type == "testStart")
            | {key: (.test.id | tostring), value: .test.name})
      | from_entries) as $names
  | [$events[]
      | select(.type == "testDone" and .hidden == false)
      | {name: ($names[.testID | tostring] // ""), result, skipped}
      | select(.name | startswith($prefix))] as $done
  | (if any($events[]; .type == "done") then "finished" else "unfinished" end),
    ($done | map(select(.result == "success" and .skipped == false)) | length),
    ($done[] | select(.skipped == true) | "S\t" + .name),
    ($done[] | select(.result != "success") | "F\t" + .name)
' "$report" 2>&1)" || summary_code=$?

if [ "$summary_code" -ne 0 ]; then
  echo "assert-test-count: could not read $report as a JSON test report: $summary" >&2
  exit 1
fi

finished=""
passed=""
skipped_names=""
failed_names=""
while IFS= read -r line; do
  if [ -z "$finished" ]; then
    finished="$line"
  elif [ -z "$passed" ]; then
    passed="$line"
  else
    case "$line" in
    S$'\t'*) skipped_names="${skipped_names}  ${line#S$'\t'}"$'\n' ;;
    F$'\t'*) failed_names="${failed_names}  ${line#F$'\t'}"$'\n' ;;
    esac
  fi
done <<EOF
$summary
EOF

if [ -n "$prefix" ]; then
  scope="tests named '${prefix}*'"
else
  scope="tests"
fi

if [ "$finished" != "finished" ]; then
  echo "assert-test-count: $report has no 'done' event: the run crashed or was killed before it finished ($passed $scope had passed)" >&2
  exit 1
fi

if [ "$passed" -lt "$min" ]; then
  {
    echo "assert-test-count: $passed $scope passed, fewer than the pinned minimum of $min."
    if [ -n "$skipped_names" ]; then
      printf 'Skipped:\n%s' "$skipped_names"
    fi
    if [ -n "$failed_names" ]; then
      printf 'Failed:\n%s' "$failed_names"
    fi
    echo "If a test was removed on purpose, lower the minimum in the same change."
  } >&2
  exit 1
fi

echo "assert-test-count: $passed $scope passed (minimum $min)"
