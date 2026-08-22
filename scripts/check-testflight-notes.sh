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
  source_label="$(sed -n 's/^testflight-notes: source=//p' "$err")"

  [ -n "$out" ] || note_failure "${version}: produced no output"

  chars="$(printf '%s' "$out" | wc -m | tr -d ' ')"
  if [ "$chars" -gt "$MAX_CHARS" ]; then
    note_failure "${version}: ${chars} characters, over the ${MAX_CHARS} limit"
  fi

  # Membership is decided here, by grep, not by the script. A renamed heading
  # or a broken extraction pattern then shows up as a failure instead of a
  # quiet fall-through to commit subjects, which would still be non-empty,
  # still under the cap, and still wrong.
  if grep -qx '## Player' "$f" && [ "$source_label" != "bundled" ]; then
    note_failure "${version}: has a '## Player' section but reported source=${source_label}"
  fi
done

# Plain-text conversion, asserted against a release known to exercise every rule.
out="$("$SCRIPT" 0.14.0 HEAD v0.14.0 2>/dev/null)"

case "$out" in
  *'`'*)   note_failure "0.14.0: backticks survived the plain-text conversion" ;;
esac
case "$out" in
  *'**'*)  note_failure "0.14.0: bold markers survived the plain-text conversion" ;;
esac
case "$out" in
  *'(#'*)  note_failure "0.14.0: a PR reference survived the plain-text conversion" ;;
esac
case "$out" in
  *'### '*) note_failure "0.14.0: a subheading kept its hashes" ;;
esac
case "$out" in
  *'Remote control between players'*) : ;;
  *) note_failure "0.14.0: the subheading text itself was dropped" ;;
esac

# A trailing sentence period must survive its PR reference being stripped.
out="$("$SCRIPT" 0.13.0 HEAD v0.13.0 2>/dev/null)"
case "$out" in
  *'rendered identically.'*) : ;;
  *) note_failure "0.13.0: stripping '(#332).' also ate the sentence period" ;;
esac

# 0.13.0 has bullets with more than one parenthetical PR-ref group per line
# (a mid-sentence group plus a trailing one), which a stripping pattern
# anchored to end of line only catches the last of.
case "$out" in
  *'(#'*) note_failure "0.13.0: a PR reference survived the plain-text conversion" ;;
esac

# The commit-log fallback, for a version with no bundled file. The previous tag
# is pinned so the commit range does not drift as new releases land.
if out="$(TESTFLIGHT_PREV_TAG=v0.13.0 "$SCRIPT" 9.9.9 HEAD v9.9.9 2>"$err")"; then
  source_label="$(sed -n 's/^testflight-notes: source=//p' "$err")"
  [ -n "$out" ] || note_failure "fallback: produced no output"
  chars="$(printf '%s' "$out" | wc -m | tr -d ' ')"
  if [ "$chars" -gt "$MAX_CHARS" ]; then
    note_failure "fallback: ${chars} characters, over the ${MAX_CHARS} limit"
  fi
  if [ "$source_label" != "gitlog" ]; then
    note_failure "fallback: reported source=${source_label}, wanted gitlog"
  fi
else
  note_failure "fallback: script exited non-zero: $(cat "$err")"
fi

# Commit subjects reach testers too, so they get the same cleanup the bundled
# section gets. A squash merge appends its PR number to the subject, so this is a
# real case rather than a theoretical one.
#
# Both ends of this range are immutable, and it is deliberately NOT the range
# used above: `v0.13.0..HEAD` runs to 120+ subjects, and the marked-up one sits
# far past the point the 4000-character budget stops keeping lines, so it never
# reaches the output and the assertion would pass without testing anything.
# `v0.13.2..7f080ff3` is 46 subjects with the marked-up one first.
if out="$(TESTFLIGHT_PREV_TAG=v0.13.2 "$SCRIPT" 9.9.9 7f080ff3714f91b186eaa052cf8f721260c6e1ad v9.9.9 2>/dev/null)"; then
  case "$out" in
    *'Address PR review feedback'*) : ;;
    *) note_failure "fallback markup: the fixture subject is missing, so this assertion proves nothing" ;;
  esac
  case "$out" in
    *'(#'*) note_failure "fallback markup: a PR reference survived the plain-text conversion" ;;
  esac
  case "$out" in
    *'`'*)  note_failure "fallback markup: backticks survived the plain-text conversion" ;;
  esac
else
  note_failure "fallback markup: script exited non-zero"
fi

[ "$fail" -eq 0 ] || exit 1
echo "testflight notes: all $(find priv/changelog -name '*.md' | wc -l | tr -d ' ') bundled changelogs pass"
