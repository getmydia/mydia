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

notes=""
source_label=""

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
