#!/usr/bin/env bash
#
# Decide whether a dependabot pull request may merge.
#
# GitHub's native auto-merge (`gh pr merge --auto`) waits on REQUIRED checks
# only, and there is no flag to make it consider advisory ones. The Master
# ruleset requires six contexts out of roughly twenty-six, so on 2026-08-29
# PR #613 auto-merged with seven red checks and broke the master Docker image.
# This script exists to wait on the whole rollup instead.
#
# The verdict path takes JSON on stdin and touches no network, so it is tested
# from fixtures in scripts/tests/.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  dependabot-gate.sh verdict [--pr <number>]

  Reads a JSON object with a `statusCheckRollup` key on stdin (or fetches one
  for --pr) and prints exactly one line:

    MERGE                      every context concluded acceptably
    WAIT                       something has not concluded, or no checks yet
    BLOCKED\t<name>=<state>... everything concluded, something is not acceptable

  Exit status is 0 for all three. Non-zero means the script itself failed.
USAGE
  exit 64
}

# A rollup mixes two shapes:
#
#   CheckRun      { name, status, conclusion }   status is QUEUED/IN_PROGRESS/COMPLETED
#   StatusContext { context, state }             NO status field at all
#
# CodeRabbit posts a StatusContext. Reading only `.status` yields null for it,
# which a naive script reads as "still running" and waits on forever. Normalise
# both into { name, state } where state is terminal or the literal PENDING.
normalise='
  [ (.statusCheckRollup // [])[]
    | if .__typename == "StatusContext"
      then { name: .context, state: (.state // "PENDING") }
      else { name: .name,
             state: (if (.status // "") != "COMPLETED"
                     then "PENDING"
                     else (.conclusion // "PENDING")
                     end) }
      end
  ]
'

# SKIPPED and NEUTRAL are normal, not failures. PR #610 carries four SKIPPED
# (CodeQL, the fork lockfile scan, both NixOS Module jobs) and PR #613 carries
# three plus one NEUTRAL. Rejecting them would mean never merging anything.
acceptable='["SUCCESS", "SKIPPED", "NEUTRAL"]'
pending='["PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "EXPECTED", "REQUESTED"]'

verdict() {
  local doc
  doc="$(cat)"

  local checks
  checks="$(printf '%s' "$doc" | jq -c "$normalise")"

  # No checks registered yet is WAIT, never MERGE. A PR queried in the seconds
  # after it opens has an empty rollup, and treating empty as green would merge
  # it before CI had started.
  if [ "$(printf '%s' "$checks" | jq 'length')" -eq 0 ]; then
    echo "WAIT"
    return 0
  fi

  if [ "$(printf '%s' "$checks" | jq --argjson p "$pending" '[.[] | select(.state as $s | $p | index($s))] | length')" -gt 0 ]; then
    echo "WAIT"
    return 0
  fi

  local blocking
  blocking="$(printf '%s' "$checks" \
    | jq -r --argjson ok "$acceptable" \
        '[.[] | select(.state as $s | ($ok | index($s)) | not)]
         | sort_by(.name)
         | map("\(.name)=\(.state)")
         | join("\t")')"

  if [ -n "$blocking" ]; then
    printf 'BLOCKED\t%s\n' "$blocking"
    return 0
  fi

  echo "MERGE"
}

main() {
  [ $# -ge 1 ] || usage
  local cmd="$1"; shift

  case "$cmd" in
    verdict)
      if [ "${1:-}" = "--pr" ]; then
        [ -n "${2:-}" ] || usage
        gh pr view "$2" --json statusCheckRollup | verdict
      else
        verdict
      fi
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
