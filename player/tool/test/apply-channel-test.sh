#!/usr/bin/env bash
# Runs apply-channel.sh against a copy of every display-name site and checks
# that beta and dev rename all of them, stable renames none, and a site that
# lost its expected text fails the script instead of shipping a stable name.
set -euo pipefail

PLAYER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$PLAYER/tool/apply-channel.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SITES=(
  android/app/src/main/AndroidManifest.xml
  ios/Runner/Info.plist
  macos/Runner/Info.plist
  windows/runner/Runner.rc
  windows/installer.iss
  linux/runner/my_application.cc
  flatpak/dev.mydia.player.desktop
  flatpak/dev.mydia.player.metainfo.xml
)

fresh_copy() {
  rm -rf "$WORK/p"
  for f in "${SITES[@]}"; do
    mkdir -p "$WORK/p/$(dirname "$f")"
    cp "$PLAYER/$f" "$WORK/p/$f"
  done
}

fail() { echo "FAIL: $*"; exit 1; }

# stable: nothing changes
fresh_copy
out="$(GITHUB_ENV= "$SCRIPT" --names-only --root "$WORK/p" 0.16.0)"
for f in "${SITES[@]}"; do
  cmp -s "$PLAYER/$f" "$WORK/p/$f" || fail "stable modified $f"
done
grep -qx 'MYDIA_CHANNEL=stable' <<<"$out" || fail "stable did not report its channel"
[ "$(cat "$WORK/p/.build-channel")" = stable ] || fail ".build-channel not stable"

check_channel() {
  local version="$1" channel="$2" name="$3"
  fresh_copy
  local env_file="$WORK/github_env"
  : > "$env_file"
  GITHUB_ENV="$env_file" "$SCRIPT" --names-only --root "$WORK/p" "$version" >/dev/null
  grep -qx "MYDIA_CHANNEL=$channel" "$env_file" || fail "$channel: GITHUB_ENV missing channel"
  grep -qx "MYDIA_APP_NAME=$name" "$env_file" || fail "$channel: GITHUB_ENV missing name"
  [ "$(cat "$WORK/p/.build-channel")" = "$channel" ] || fail "$channel: .build-channel wrong"
  for f in "${SITES[@]}"; do
    grep -q "$name" "$WORK/p/$f" || fail "$channel: $f does not contain '$name'"
  done
  [ "$(grep -c "\"$name\"" "$WORK/p/windows/runner/Runner.rc")" = 2 ] \
    || fail "$channel: Runner.rc should name it twice"
  grep -q '<name>Mydia</name>' "$WORK/p/flatpak/dev.mydia.player.metainfo.xml" \
    || fail "$channel: developer name in metainfo was rewritten"
}

check_channel 0.16.0-beta.3 beta 'Mydia Player Beta'
check_channel 0.17.0-dev.42 dev 'Mydia Player Dev'

# drift: a site that no longer holds the expected text must fail the script
fresh_copy
perl -0777 -pi -e 's/android:label="Mydia Player"/android:label="Something Else"/' \
  "$WORK/p/android/app/src/main/AndroidManifest.xml"
if GITHUB_ENV= "$SCRIPT" --names-only --root "$WORK/p" 0.16.0-beta.1 >/dev/null 2>&1; then
  fail "script succeeded although AndroidManifest lost its expected label"
fi

echo "apply-channel: all checks passed"
