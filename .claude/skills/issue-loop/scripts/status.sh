#!/usr/bin/env bash
# Prints the state of every issue the loop knows about.
# Usage: status.sh [--json]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ ${1:-} == --json ]]; then
  find "$STATE_DIR/issues" -name '*.json' -print0 2>/dev/null |
    xargs -0 -r jq -s 'sort_by(.issue)'
  exit 0
fi

rows=$(find "$STATE_DIR/issues" -name '*.json' -print0 2>/dev/null |
  xargs -0 -r jq -r '
    [ (.issue | tostring),
      (.phase // "new"),
      (.agent // "-"),
      (if .pr then "#\(.pr)" else "-" end),
      ((.verdict.confidence // "") | tostring),
      ((.note // .verdict.reason // "") | .[0:64])
    ] | @tsv' | sort -n)

if [[ -z $rows ]]; then
  echo "No issue-loop state yet. Run triage.sh first."
  exit 0
fi

{
  printf 'ISSUE\tPHASE\tAGENT\tPR\tCONF\tNOTE\n'
  printf '%s\n' "$rows"
} | column -t -s $'\t'

echo
printf '%s\n' "$rows" | awk -F'\t' '{c[$2]++} END {for (p in c) printf "%s=%d  ", p, c[p]; print ""}'

echo
echo "attach to an agent: claude attach <AGENT>    tail its output: claude logs <AGENT>"
