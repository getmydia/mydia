#!/usr/bin/env bash
#
# Assert scripts/dev-builds/publish.sh holds its contract, against an rclone
# local-filesystem "bucket" instead of R2. Needs rclone and jq.
# Cases run through run_case by name, which shellcheck cannot follow.
# shellcheck disable=SC2329
set -euo pipefail
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PUBLISH="$here/publish.sh"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

tmp=""
setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bucket"
  printf 'payload-%s' "$RANDOM" > "$tmp/artifact"
}
teardown() { rm -rf "$tmp"; }

# publish <platform> <version> <build> [extra-json] [object-key]
publish() {
  local platform="$1" version="$2" build="$3" extra="${4:-}"
  local ext=apk
  [ "$platform" = macos ] && ext=dmg
  local key="${5:-${platform}/mydia-player-${platform}-${version}.${ext}}"
  (
    cd "$tmp"
    export DEV_BUILDS_REMOTE="$tmp/bucket"
    export DEV_BUILD_PLATFORM="$platform"
    export DEV_BUILD_SOURCE="$tmp/artifact"
    export DEV_BUILD_FILE="$key"
    export DEV_BUILD_VERSION="$version"
    export DEV_BUILD_NUMBER="$build"
    unset GITHUB_STEP_SUMMARY
    if [ -n "$extra" ]; then export DEV_BUILD_EXTRA="$extra"; else unset DEV_BUILD_EXTRA; fi
    "$PUBLISH"
  ) > "$tmp/out.log" 2>&1
}

index() { cat "$tmp/bucket/index.json"; }
q() { index | jq -e "$1" > /dev/null; }

run_case() {
  local name="$1"
  setup
  if "$name"; then echo "PASS: $name"; else note_failure "$name"; cat "$tmp/out.log" >&2 || true; fi
  teardown
}

bootstrap_empty_bucket() {
  publish android 1.0.0-dev.1 100000001 || return 1
  local sha
  sha="$(shasum -a 256 "$tmp/artifact" | cut -d' ' -f1)"
  q '.builds | length == 1' &&
    q '.builds[0].build | type == "number"' &&
    q '.builds[0].size | type == "number"' &&
    index | jq -e --arg sha "$sha" '.builds[0].sha256 == $sha' > /dev/null &&
    [ -f "$tmp/bucket/android/mydia-player-android-1.0.0-dev.1.apk" ]
}

zero_byte_index() {
  : > "$tmp/bucket/index.json"
  publish android 1.0.0-dev.1 100000001 || return 1
  q '.builds | length == 1'
}

malformed_rows_dropped() {
  cat > "$tmp/bucket/index.json" <<'EOF'
{"builds":[null,"x",{"platform":"android"},{"platform":"macos","version":"0.9.0","build":90000000,"file":"macos/old.dmg"}]}
EOF
  publish android 1.0.0-dev.1 100000001 || return 1
  q '.builds | length == 2' && q '[.builds[].platform] | sort == ["android","macos"]'
}

keeps_five_per_platform() {
  local i
  for i in 1 2 3 4 5 6; do publish android "1.0.0-dev.$i" "10000000$i" || return 1; done
  publish macos 1.0.0-dev.1 100000001 || return 1
  publish macos 1.0.0-dev.2 100000002 || return 1
  q '[.builds[] | select(.platform == "android")] | length == 5' &&
    q '[.builds[] | select(.platform == "macos")] | length == 2' &&
    q '[.builds[].build] | . == (sort | reverse)' &&
    [ ! -f "$tmp/bucket/android/mydia-player-android-1.0.0-dev.1.apk" ] &&
    [ -f "$tmp/bucket/android/mydia-player-android-1.0.0-dev.2.apk" ]
}

refuses_older_than_kept() {
  local i
  for i in 10 11 12 13 14; do publish android "1.0.0-dev.$i" "$i" || return 1; done
  cp "$tmp/bucket/index.json" "$tmp/before.json"
  if publish android 1.0.0-dev.3 3; then return 1; fi
  grep -q 'older than the five newest android builds' "$tmp/out.log" &&
    cmp -s "$tmp/before.json" "$tmp/bucket/index.json"
}

extra_fields_preserved() {
  publish macos 1.0.0-dev.1 100000001 '{"ed_signature":"abc","length":42,"minimum_system_version":"13.0"}' || return 1
  q '.builds[0].ed_signature == "abc"' &&
    q '.builds[0].length | type == "number"' &&
    q '.builds[0].length == 42' &&
    q '.builds[0].minimum_system_version == "13.0"'
}

android_entry_shape() {
  publish android 1.0.0-dev.1 100000001 || return 1
  q '.builds[0] | keys == ["build","file","platform","published_at","sha256","size","version"]'
}

same_version_replaced_per_platform() {
  publish macos 1.0.0-dev.1 100000001 || return 1
  publish android 1.0.0-dev.1 100000001 || return 1
  publish android 1.0.0-dev.1 100000001 || return 1
  q '[.builds[] | select(.platform == "android")] | length == 1' &&
    q '[.builds[] | select(.platform == "macos")] | length == 1'
}

# A re-dispatch of a version under a new object key (macOS keys carry the
# DMG digest) must repoint the index and then remove the superseded object,
# which nothing references any more.
replaced_object_deleted() {
  publish macos 1.0.0-dev.1 100000001 '' macos/a-aaaa.dmg || return 1
  publish macos 1.0.0-dev.1 100000001 '' macos/a-bbbb.dmg || return 1
  q '[.builds[] | select(.platform == "macos")] | length == 1' &&
    q '.builds[0].file == "macos/a-bbbb.dmg"' &&
    [ -f "$tmp/bucket/macos/a-bbbb.dmg" ] &&
    [ ! -f "$tmp/bucket/macos/a-aaaa.dmg" ]
}

# The script also runs on the macOS runner: bash 3.2 and BSD userland.
portable_userland() {
  [ -f "$PUBLISH" ] || return 1
  ! grep -vE '^[[:space:]]*#' "$PUBLISH" | grep -nE 'stat -c|sha256sum|mapfile|declare -A'
}

missing_required_env_fails() {
  if (cd "$tmp" && env -i PATH="$PATH" HOME="$tmp" DEV_BUILDS_REMOTE="$tmp/bucket" "$PUBLISH") > "$tmp/out.log" 2>&1; then
    return 1
  fi
  [ ! -f "$tmp/bucket/index.json" ]
}

for c in bootstrap_empty_bucket zero_byte_index malformed_rows_dropped \
  keeps_five_per_platform refuses_older_than_kept extra_fields_preserved \
  android_entry_shape same_version_replaced_per_platform replaced_object_deleted \
  portable_userland \
  missing_required_env_fails; do
  run_case "$c"
done

exit "$fail"
