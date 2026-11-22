#!/usr/bin/env bash
#
# Mark the issues a published Mydia release fixes.
#
#   scripts/release-mark-fixed-issues.sh [--dry-run] <tag>
#
# Run by release-mark-fixed-issues.yml after release.yml publishes, and by hand
# (through that workflow) to backfill. With --dry-run it reads everything and
# prints what it would write.
#
# Which issues: every PR merged between the previous release and <tag>, and the
# issues those PRs close (closing keywords or the "Development" sidebar link).
# An issue closed without a linked PR is not found.
#
#   beta    v0.19.0-beta.3  since the previous release of either kind
#   stable  v0.19.0         since the previous stable release, so it covers
#                           every beta of the version
#
# What it does to each issue:
#
#   - sets milestone vX.Y.Z (the tag without -beta.N), creating it if needed
#   - beta: comments "Fixed in <tag>", unless an earlier beta of the same
#     version already did
#   - stable: comments "Now in stable <tag>" (or "Fixed in <tag>" when no beta
#     carried it)
#
# A stable release then closes its milestone. Each comment carries a hidden
# marker, so re-running for the same tag posts nothing twice.
#
# PRs are found from merge commit subjects ("Merge pull request #N", or a
# squash subject ending "(#N)"), which costs no API call per commit.
set -euo pipefail
export LC_ALL=C.UTF-8

usage() {
  echo "usage: $0 [--dry-run] <tag>" >&2
  exit 2
}

DRY_RUN=false
TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) usage ;;
    *) [[ -z "$TAG" ]] || usage; TAG="$arg" ;;
  esac
done
[[ -n "$TAG" ]] || usage

REPO="${REPO:-getmydia/mydia}"
OWNER="${REPO%/*}"
NAME="${REPO#*/}"

readonly TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$'
if [[ ! "$TAG" =~ $TAG_RE ]]; then
  echo "$TAG is not a Mydia release tag (vX.Y.Z or vX.Y.Z-beta.N); nothing to do."
  exit 0
fi

MILESTONE="${TAG%%-*}"
if [[ "$TAG" == *-beta.* ]]; then KIND=beta; else KIND=stable; fi
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"

# jq: a sort key that orders vX.Y.Z after every vX.Y.Z-beta.N.
readonly VERSION_KEY='def vkey: capture("^v(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-beta\\.(?<d>[0-9]+))?$")
  | [(.a|tonumber), (.b|tonumber), (.c|tonumber), ((.d // "1000000000")|tonumber)];'

# The previous published release this one is measured from.
PREV=$(gh release list --repo "$REPO" --limit 200 --exclude-drafts --json tagName \
  | jq -r --arg tag "$TAG" --arg kind "$KIND" --arg re "$TAG_RE" "$VERSION_KEY"'
      [ .[].tagName
        | select(test($re))
        | select($kind == "beta" or (test("-beta\\.") | not)) ]
      | map(select(vkey < ($tag | vkey)))
      | sort_by(vkey) | last // empty')

if [[ -z "$PREV" ]]; then
  echo "::error::No published release precedes $TAG; cannot tell which issues it fixes." >&2
  exit 1
fi
echo "Marking issues fixed in $TAG ($KIND), commits $PREV...$TAG, milestone $MILESTONE"

# PR numbers from the commit subjects in the range.
mapfile -t PRS < <(
  gh api --paginate "repos/${REPO}/compare/${PREV}...${TAG}?per_page=100" \
    --jq '.commits[].commit.message | split("\n")[0]' \
    | sed -nE 's/^Merge pull request #([0-9]+) from .*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' \
    | sort -un
)
echo "${#PRS[@]} PR(s) in range"

# Closed-as-completed issues in this repository that those PRs close. Batched
# 50 PRs per GraphQL query through aliases.
ISSUES=()
for ((i = 0; i < ${#PRS[@]}; i += 50)); do
  query="query { repository(owner: \"${OWNER}\", name: \"${NAME}\") {"
  for pr in "${PRS[@]:i:50}"; do
    # issueOrPullRequest, because a "(#N)" subject can name an issue, which
    # pullRequest() would turn into a query error.
    query+=" pr${pr}: issueOrPullRequest(number: ${pr}) { ... on PullRequest {"
    query+=" closingIssuesReferences(first: 50) {"
    query+=" nodes { number state stateReason repository { nameWithOwner } } } } }"
  done
  query+=" } }"
  mapfile -t -O "${#ISSUES[@]}" ISSUES < <(
    gh api graphql -f query="$query" \
      | jq -r --arg repo "$REPO" \
        '.data.repository[] | .closingIssuesReferences.nodes[]?
         | select(.repository.nameWithOwner == $repo
                  and .state == "CLOSED" and .stateReason == "COMPLETED")
         | .number'
  )
done
mapfile -t ISSUES < <(printf '%s\n' "${ISSUES[@]}" | sed '/^$/d' | sort -un)
echo "${#ISSUES[@]} issue(s) fixed: ${ISSUES[*]:-none}"

run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@" >/dev/null
  fi
}

milestone_number() {
  gh api --paginate "repos/${REPO}/milestones?state=all&per_page=100" \
    --jq ".[] | select(.title == \"${MILESTONE}\") | .number"
}

MILESTONE_NUMBER=""
if ((${#ISSUES[@]} > 0)) || [[ "$KIND" == stable ]]; then
  MILESTONE_NUMBER=$(milestone_number)
  if [[ -z "$MILESTONE_NUMBER" ]]; then
    echo "Creating milestone $MILESTONE"
    if $DRY_RUN; then
      MILESTONE_NUMBER="<new>"
    else
      MILESTONE_NUMBER=$(gh api -X POST "repos/${REPO}/milestones" \
        -f title="$MILESTONE" --jq .number)
    fi
  fi
fi

readonly MARKER_PREFIX="<!-- mydia-release:${MILESTONE}:"

for issue in "${ISSUES[@]}"; do
  echo "#${issue}"
  run gh api -X PATCH "repos/${REPO}/issues/${issue}" -F milestone="$MILESTONE_NUMBER"

  bodies=$(gh api --paginate "repos/${REPO}/issues/${issue}/comments?per_page=100" --jq '.[].body')

  if [[ "$KIND" == beta ]]; then
    if grep -qF "$MARKER_PREFIX" <<<"$bodies"; then
      echo "  already announced for $MILESTONE"
      continue
    fi
    body="Fixed in [${TAG}](${RELEASE_URL}), a beta release. Thanks for reporting it!"
  else
    if grep -qF "${MARKER_PREFIX}stable -->" <<<"$bodies"; then
      echo "  already announced in stable"
      continue
    fi
    if grep -qF "${MARKER_PREFIX}beta -->" <<<"$bodies"; then
      body="Now in the stable release, [${TAG}](${RELEASE_URL})."
    else
      body="Fixed in [${TAG}](${RELEASE_URL}). Thanks for reporting it!"
    fi
  fi
  run gh api -X POST "repos/${REPO}/issues/${issue}/comments" \
    -f body="${body}"$'\n\n'"${MARKER_PREFIX}${KIND} -->"
done

if [[ "$KIND" == stable ]]; then
  echo "Closing milestone $MILESTONE"
  run gh api -X PATCH "repos/${REPO}/milestones/${MILESTONE_NUMBER}" \
    -f state=closed -f description="Released in ${RELEASE_URL}"
fi
