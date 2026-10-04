#!/usr/bin/env bash
#
# Assert scripts/ondemand-version.sh holds its contract against a throwaway
# repository with real tags and merges. The workflow that calls it can only be
# dispatched from the default branch, so this is the only place its version
# derivation runs before merge.
set -euo pipefail
export LC_ALL=C.UTF-8

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ondemand-version.sh"
BUILD_NUMBER="$ROOT/scripts/build-number.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate from the developer's git config (signing, hooks, default branch).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

REPO="$WORK/repo"
fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

expect_version() {
  local label="$1" want="$2" commit="$3" got
  shift 3
  got="$(cd "$REPO" && "$SCRIPT" "$@" "$commit" 2>&1)" || got="(failed) $got"
  [ "$want" = "$got" ] || note_failure "$label: got '$got', wanted '$want'"
  "$BUILD_NUMBER" "$want" >/dev/null || note_failure "$label: build-number.sh rejects '$want'"
}

expect_failure() {
  local label="$1" commit="$2"
  shift 2
  if (cd "$REPO" && "$SCRIPT" "$@" "$commit" >/dev/null 2>&1); then
    note_failure "$label: should have failed"
  fi
}

commit() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
tag() { git -C "$REPO" tag "$1"; }

git init -q -b master "$REPO"

commit one; commit two; commit three
expect_version "no tag yet" "0.1.0-dev.3" HEAD

tag v0.15.0
expect_failure "the tagged commit itself" HEAD

commit four; commit five
expect_version "after stable" "0.16.0-dev.2" HEAD

tag v0.16.0-beta.2
git -C "$REPO" checkout -q -b feature
commit f1; commit f2; commit f3
expect_version "feature branch counts its own commits" "0.16.0-beta.2.dev.3" feature
git -C "$REPO" checkout -q master
expect_failure "an unmerged feature tip is not on mainline" feature --mainline master
expect_version "an unmerged feature tip still versions without --mainline" "0.16.0-beta.2.dev.3" feature
git -C "$REPO" merge -q --no-ff -m "merge feature" feature
expect_version "a merge is one first-parent step" "0.16.0-beta.2.dev.1" HEAD
expect_version "a mainline commit keeps its version" "0.16.0-beta.2.dev.1" HEAD --mainline master
expect_version "without --mainline a side-branch commit still versions" "0.16.0-beta.2.dev.2" feature~1
expect_failure "a commit reachable only through a merged side branch" feature~1 --mainline master
expect_failure "a merged feature tip is still off the first-parent line" feature --mainline master

commit six
tag plugins-v2026.10.2
tag metadata-relay-v0.20.0
expect_version "plugin and relay tags are not anchors" "0.16.0-beta.2.dev.2" HEAD

tag v0.16.0-rc13
commit seven
expect_version "legacy no-dot tag normalises" "0.16.0-rc.13.dev.1" HEAD

tag v0.16.0-nightly.1
commit eight
expect_failure "an anchor with an unknown prerelease" HEAD

expect_failure "not a commit" does-not-exist
expect_failure "no argument" ""

# A release tag that exists only on a merged side branch is never the anchor,
# even when it is nearer by ancestry than the tag on master's first-parent line.
# Commit dates are explicit: git describe breaks ancestry ties by date, and
# commits made in the same second would hide the difference.
REPO="$WORK/repo2"
git init -q -b master "$REPO"
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
commit a; commit b
export GIT_AUTHOR_DATE="@1700000100 +0000" GIT_COMMITTER_DATE="@1700000100 +0000"
commit c
tag v0.16.0-beta.2
git -C "$REPO" checkout -q -b hotfix HEAD~1
export GIT_AUTHOR_DATE="@1700000200 +0000" GIT_COMMITTER_DATE="@1700000200 +0000"
commit h1; commit h2
tag v0.15.1
git -C "$REPO" checkout -q master
export GIT_AUTHOR_DATE="@1700000300 +0000" GIT_COMMITTER_DATE="@1700000300 +0000"
git -C "$REPO" merge -q --no-ff -m "merge hotfix" hotfix
export GIT_AUTHOR_DATE="@1700000400 +0000" GIT_COMMITTER_DATE="@1700000400 +0000"
commit d
expect_version "a tag on a merged side branch is not the anchor" "0.16.0-beta.2.dev.2" HEAD

if [ "$fail" -eq 0 ]; then
  echo "scripts/ondemand-version.sh: all cases passed"
fi
exit "$fail"
