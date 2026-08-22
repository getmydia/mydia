#!/usr/bin/env bash
#
# Produce plain-text app release notes for the stores from the bundled changelog.
#
#   scripts/testflight-notes.sh <version> <sha> <tag>
#
# stdout: the notes. Always non-empty, never more than 4000 characters, which is
#         the limit App Store Connect applies to a beta build's "What to Test".
# stderr: one line, `testflight-notes: source=bundled|gitlog|placeholder`.
#
# Apple counts characters, not bytes, and the notes are not pure ASCII, so every
# length here is measured with bash's ${#var} under a UTF-8 locale. Do not switch
# to awk's length(): mawk, the default awk on some runner images, counts bytes.

set -euo pipefail
export LC_ALL=C.UTF-8

readonly MAX_CHARS=4000
readonly REPO_URL="https://github.com/getmydia/mydia"

die() { echo "testflight-notes: $*" >&2; exit 1; }

[ "$#" -eq 3 ] || die "usage: $0 <version> <sha> <tag>"
readonly VERSION="$1" SHA="$2" TAG="$3"

git cat-file -e "${SHA}^{commit}" 2>/dev/null || die "'${SHA}' is not a commit"

# The heading match is exact. A renamed or whitespace-padded heading extracts
# nothing and falls through, which check-testflight-notes.sh is what catches.
extract_player_section() {
  awk '/^## Player$/ { inside = 1; next } /^## / { inside = 0 } inside { print }'
}

# Markdown to plain text. The awk pass folds any continuation line onto the
# bullet above it, so fit_to_budget can only ever cut between whole bullets.
# Bullets are one line each in every current changelog; this is insurance
# against a future wrapped one.
#
# The PR-reference sed pattern strips every parenthetical group on a line,
# not just a trailing one: a bullet can carry a mid-sentence group and a
# trailing group in the same line, e.g. "Poster cards ... (#344). Search
# posters ... (#347). ... gone (#345)." A sentence period sits outside the
# parentheses either way, so it is left in place naturally.
to_plain_text() {
  awk '
    /^[[:space:]]*$/ { if (buf != "") { print buf; buf = "" } print ""; next }
    /^- /            { if (buf != "") print buf; buf = $0; next }
    /^### /          { if (buf != "") { print buf; buf = "" } sub(/^### /, ""); print; next }
                     { if (buf != "") buf = buf " " $0; else buf = $0 }
    END              { if (buf != "") print buf }
  ' | sed -E '
    s/`([^`]*)`/\1/g
    s/\*\*([^*]*)\*\*/\1/g
    s/\[([^]]*)\]\([^)]*\)/\1/g
    s/[[:space:]]*\(#[0-9]+(,[[:space:]]*#[0-9]+)*\)//g
  ' | cat -s \
    | sed -e '/./,$!d' \
    | awk 'NF { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }'
}

# Keep whole lines until the budget is spent. Once a line does not fit, every
# later line is dropped too, so the output never ends mid-bullet.
# Returns 1 when something was dropped, 0 when everything fit.
fit_to_budget() {
  local budget="$1" line total=0 truncated=0 i n has_bullet=0
  local -a kept=()

  while IFS= read -r line; do
    if [ "$truncated" -eq 1 ]; then continue; fi
    local len=$(( ${#line} + 1 ))
    if (( total + len > budget )); then truncated=1; continue; fi
    total=$(( total + len ))
    kept+=("$line")
  done

  n=${#kept[@]}
  while (( n > 0 )) && [ -z "${kept[$((n-1))]//[[:space:]]/}" ]; do n=$(( n - 1 )); done

  # Only a bullet list can end on a dangling subheading. The placeholder
  # fallback is a single prose line and must survive this untouched.
  for (( i = 0; i < n; i++ )); do
    case "${kept[$i]}" in "- "*) has_bullet=1; break ;; esac
  done
  if (( has_bullet )); then
    while (( n > 0 )); do
      case "${kept[$((n-1))]}" in
        "- "*) break ;;
        *) n=$(( n - 1 )) ;;
      esac
    done
  fi

  if (( n > 0 )); then printf '%s\n' "${kept[@]:0:$n}"; fi
  return $truncated
}

# The tag being built does not exist yet: GitHub creates it when the workflow
# publishes the draft. So the newest existing tag is the previous release. The
# grep -vFx is defensive against a re-dispatch where it somehow already does.
#
# TESTFLIGHT_PREV_TAG exists for check-testflight-notes.sh, which needs a
# deterministic commit range. Production never sets it.
previous_tag() {
  if [ -n "${TESTFLIGHT_PREV_TAG:-}" ]; then
    echo "$TESTFLIGHT_PREV_TAG"
    return
  fi
  # An empty filtered list (no tag left after excluding metadata-relay tags and
  # $TAG itself) makes the last grep exit non-zero even though head still runs
  # and prints nothing. Under pipefail that failing status is the pipeline's
  # status, and set -e would abort the whole script right here, silently,
  # before Source 3's placeholder fallback is ever reached. The trailing
  # `|| true` keeps this a clean empty result so the `if [ -n "$prev" ]` guard
  # at the call site can handle it. Do not remove this as dead code.
  git tag --sort=-version:refname | grep -v metadata-relay | grep -vFx "$TAG" | head -n1 || true
}

notes=""
source_label=""

# --- Source 1: the bundled `## Player` section --------------------------------
# Read from the pinned commit, not the working tree: a draft release can target
# a commit older than the ref this runs on.
notes_path="priv/changelog/${VERSION}.md"
if git cat-file -e "${SHA}:${notes_path}" 2>/dev/null; then
  notes="$(git show "${SHA}:${notes_path}" | extract_player_section | to_plain_text)"
  [ -n "$notes" ] && source_label="bundled"
fi

# --- Source 2: commits touching the app since the previous tag ----------------
if [ -z "$notes" ]; then
  prev="$(previous_tag)"
  if [ -n "$prev" ]; then
    notes="$(git log --format='- %s' "${prev}..${SHA}" -- player/ || true)"
    [ -n "$notes" ] && source_label="gitlog"
  fi
fi

# --- Source 3: a line naming the version --------------------------------------
# External TestFlight distribution rejects empty notes, so this never yields "".
if [ -z "$notes" ]; then
  notes="Mydia Player ${VERSION}. No app changes in this build."
  source_label="placeholder"
fi

# The link is only useful when there is a release page to link to, and only
# earns its characters when something was actually dropped.
tail_text=""
case "$TAG" in
  v*) tail_text=$'\n\n'"Full notes: ${REPO_URL}/releases/tag/${TAG}" ;;
esac

budget=$(( MAX_CHARS - ${#tail_text} ))
fitted="$(printf '%s\n' "$notes" | fit_to_budget "$budget")" && truncated=0 || truncated=1

if [ "$truncated" -eq 1 ] && [ -n "$tail_text" ]; then
  printf '%s%s\n' "$fitted" "$tail_text"
else
  printf '%s\n' "$fitted"
fi

echo "testflight-notes: source=${source_label}" >&2
