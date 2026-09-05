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
# The marker-tag case below creates a real tag, so cleanup has to cover it even
# when an assertion fails partway through.
readonly PROBE_TAG="ios-refresh/9999-12-31"
trap 'git tag -d "$PROBE_TAG" >/dev/null 2>&1 || true; rm -f "$err"' EXIT

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

# Plain-text conversion, asserted against one release that exercises every rule.
#
# The fixture must be a SHIPPED version. This block was pinned to 0.14.0 while
# 0.14.0 was still in beta, and naming a subheading inside notes that were always
# going to be rewritten before the stable release meant the rewrite failed CI on
# an assertion about the fixture rather than anything about the script. Point it
# at the newest released version, never the one in flight.
readonly FIXTURE=0.13.0
readonly FIXTURE_FILE="priv/changelog/${FIXTURE}.md"

extract_player() { awk '/^## Player$/ { i = 1; next } /^## / { i = 0 } i' "$1"; }

# The fixture has to keep carrying the constructs, or every "did not survive"
# case below passes by vacuum. Decided here by grep against the file, the same
# way section membership is decided above.
extract_player "$FIXTURE_FILE" | grep -q '^### ' ||
  note_failure "${FIXTURE}: no '### ' under '## Player', so the subheading assertions prove nothing"
extract_player "$FIXTURE_FILE" | grep -qF '`' ||
  note_failure "${FIXTURE}: no backticks under '## Player', so the backtick assertion proves nothing"
extract_player "$FIXTURE_FILE" | grep -qF '(#' ||
  note_failure "${FIXTURE}: no PR references under '## Player', so the PR-ref assertion proves nothing"

out="$("$SCRIPT" "$FIXTURE" HEAD "v${FIXTURE}" 2>/dev/null)"

case "$out" in
  *'`'*)   note_failure "${FIXTURE}: backticks survived the plain-text conversion" ;;
esac
case "$out" in
  *'**'*)  note_failure "${FIXTURE}: bold markers survived the plain-text conversion" ;;
esac
# Bullets here carry more than one parenthetical PR-ref group per line (a
# mid-sentence group plus a trailing one), which a stripping pattern anchored to
# end of line only catches the last of.
case "$out" in
  *'(#'*)  note_failure "${FIXTURE}: a PR reference survived the plain-text conversion" ;;
esac
case "$out" in
  *'### '*) note_failure "${FIXTURE}: a subheading kept its hashes" ;;
esac
# The first subheading, so this cannot fail merely because the 4000-character
# budget cut the section short.
case "$out" in
  *'Detail pages and chrome'*) : ;;
  *) note_failure "${FIXTURE}: the subheading text itself was dropped" ;;
esac
# A trailing sentence period must survive its PR reference being stripped.
case "$out" in
  *'rendered identically.'*) : ;;
  *) note_failure "${FIXTURE}: stripping '(#332).' also ate the sentence period" ;;
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

# player-ios-refresh.yml pushes `ios-refresh/<date>` tags to record a TestFlight
# refresh. previous_tag() must never return one: it is not a release, and the
# commit range it implies has nothing to do with what changed since one.
#
# This passes today even without the grep guard in previous_tag(), because
# `-version:refname` orders a non-version name lexicographically against the
# version tags and `ios-` sorts below `v0-`: a marker lands at the bottom of the
# list, where head -n1 never reaches it. That is a property of the prefix, not of
# the code. A prefix sorting after `v` goes straight to position 1. This case
# exists to catch that, so it asserts the invariant that matters rather than
# pretending to exercise the guard.
git tag -f "$PROBE_TAG" HEAD >/dev/null 2>&1

if "$SCRIPT" 9.9.9 HEAD v9.9.9 >/dev/null 2>"$err"; then
  prev="$(sed -n 's/^testflight-notes: prev=//p' "$err")"
  case "$prev" in
    "")   note_failure "marker tag: no previous tag was reported, so this assertion proves nothing" ;;
    v*)   : ;;
    *)    note_failure "marker tag: previous_tag() returned '${prev}', which is not a release tag" ;;
  esac
else
  note_failure "marker tag: script exited non-zero: $(cat "$err")"
fi

git tag -d "$PROBE_TAG" >/dev/null 2>&1 || true

[ "$fail" -eq 0 ] || exit 1
echo "testflight notes: all $(find priv/changelog -name '*.md' | wc -l | tr -d ' ') bundled changelogs pass"
