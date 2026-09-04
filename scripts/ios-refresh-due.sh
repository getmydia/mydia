#!/usr/bin/env bash
#
# Decide whether the iOS TestFlight groups need a refresh build, and emit the
# coordinates for one.
#
#   scripts/ios-refresh-due.sh >> "$GITHUB_OUTPUT"
#
# TestFlight deletes a build 90 days after upload, and the installed app then
# refuses to launch. Both external groups are topped up only when a build is
# uploaded, so a long quiet stretch between stable releases is what strands
# testers. This script is the decision; player-ios-refresh.yml is the trigger.
#
# stdout: GITHUB_OUTPUT-shaped `key=value` lines.
# stderr: one line explaining the decision.
#
# The baseline is the newer of the last stable release and the last refresh.
# The refresh records itself as an `ios-refresh/YYYY-MM-DD` tag rather than as
# a successful workflow run, because a weekly run that decides *not due* also
# succeeds: run history would reset the baseline every week and the refresh
# would never fire at all.
#
# The overrides exist for check-ios-refresh-due.sh. Production sets none of
# them. IOS_REFRESH_MARKER uses `${VAR-default}` rather than `${VAR:-default}`
# so a deliberately empty value means "no marker exists" instead of falling
# through to the git lookup, which is how the no-marker cases are tested in a
# repository that has markers.
set -euo pipefail
export LC_ALL=C.UTF-8

readonly DEFAULT_THRESHOLD_DAYS=60
readonly MARKER_PREFIX="ios-refresh/"

die() { echo "ios-refresh-due: $*" >&2; exit 1; }

epoch() { date -u -d "$1" +%s 2>/dev/null || die "cannot parse date '$1'"; }

# `creatordate` here resolves to the tagged commit's committer date, because
# GitHub creates release tags as lightweight refs: `git cat-file -t v0.13.2`
# reports `commit`, not `tag`. That is the best signal available locally, and it
# errs old, because a draft can target a commit from days before it ships. An
# older baseline makes the refresh fire sooner, which is the safe direction
# against a 90-day expiry.
#
# `refs/tags/v*` excludes the metadata-relay tags for free: they are named
# metadata-relay-v*, which does not start with v.
newest_stable() {
  git for-each-ref --sort=-creatordate \
      --format='%(refname:short) %(creatordate:short)' 'refs/tags/v*' \
    | grep -vE -- '-(beta|rc|alpha)' \
    | head -n1
}

# A marker's date comes from its own name, never from a git date field.
#
# These are lightweight tags too, and `creatordate` on a lightweight tag is the
# tagged commit's committer date, not the moment the tag was created. The
# refresh tags the stable release's commit, so reading a git date here would
# report the release's own date: the marker could never advance the baseline
# past the release, and the refresh would re-fire every week for the length of a
# drought. That is the exact failure this marker exists to prevent.
#
# Verified: a lightweight tag created today against a 2020 commit reports
# `creatordate` 2020-01-01, while an annotated tag on the same commit reports
# today.
#
# The `case` both extracts and validates: a marker whose suffix is not a date is
# skipped rather than silently sorting as garbage.
newest_marker() {
  git for-each-ref --format='%(refname:short)' "refs/tags/${MARKER_PREFIX}*" \
    | while IFS= read -r ref; do
        marker_date="${ref#"${MARKER_PREFIX}"}"
        case "$marker_date" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) echo "${ref} ${marker_date}" ;;
        esac
      done \
    | sort -k2 \
    | tail -n1
}

threshold="${IOS_REFRESH_THRESHOLD_DAYS:-$DEFAULT_THRESHOLD_DAYS}"
today="${IOS_REFRESH_TODAY:-$(date -u +%Y-%m-%d)}"

stable="${IOS_REFRESH_STABLE:-$(newest_stable)}"
[ -n "$stable" ] || die "no stable release tag found"

tag="${stable%% *}"
baseline_date="${stable##* }"
baseline_why="stable release ${tag} (${baseline_date})"

marker="${IOS_REFRESH_MARKER-$(newest_marker)}"
if [ -n "$marker" ]; then
  marker_date="${marker##* }"
  if [ "$(epoch "$marker_date")" -gt "$(epoch "$baseline_date")" ]; then
    baseline_date="$marker_date"
    baseline_why="refresh ${marker%% *} (${marker_date})"
  fi
fi

age_days=$(( ( $(epoch "$today") - $(epoch "$baseline_date") ) / 86400 ))

if [ "$age_days" -gt "$threshold" ]; then due=true; else due=false; fi

sha="$(git rev-list -n1 "$tag")"

{
  echo "due=${due}"
  echo "age_days=${age_days}"
  # The date the age was measured from, and which of the two sources won. Emitted
  # because it is the only way to assert that a marker's date came from its name
  # rather than from a git date field: both readings can yield the same `due`.
  echo "baseline_date=${baseline_date}"
  echo "tag=${tag}"
  echo "version=${tag#v}"
  echo "sha=${sha}"
}

echo "ios-refresh-due: ${age_days}d since ${baseline_why}, threshold ${threshold}d, due=${due}" >&2
