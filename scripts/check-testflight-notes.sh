#!/usr/bin/env bash
#
# Assert scripts/testflight-notes.sh holds its contract against every bundled
# changelog: non-empty output, and at most 4000 characters once fitted.
#
# Length is measured in characters, not bytes. The notes are not pure ASCII.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/.."

readonly SCRIPT="scripts/testflight-notes.sh"
readonly MAX_CHARS=4000

fail=0
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

note_failure() { echo "FAIL: $*" >&2; fail=1; }

for f in priv/changelog/*.md; do
  version="$(basename "$f" .md)"

  if ! out="$("$SCRIPT" "$version" HEAD "v${version}" 2>"$err")"; then
    note_failure "${version}: script exited non-zero: $(cat "$err")"
    continue
  fi

  [ -n "$out" ] || note_failure "${version}: produced no output"

  chars="$(printf '%s' "$out" | wc -m | tr -d ' ')"
  if [ "$chars" -gt "$MAX_CHARS" ]; then
    note_failure "${version}: ${chars} characters, over the ${MAX_CHARS} limit"
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "testflight notes: all $(find priv/changelog -name '*.md' | wc -l | tr -d ' ') bundled changelogs pass"
