#!/usr/bin/env bash
# Assert that a built player APK or AAB ships exactly the ABIs we intend.
#
# Flutter's Gradle plugin sets defaultConfig.ndk.abiFilters to its own fixed
# list (armeabi-v7a, arm64-v8a, x86_64) in FlutterPlugin.kt's
# configureAbiWithoutSplits, clearing whatever the project declared first. The
# player holds that off with disable-abi-filtering=true in
# player/android/gradle.properties. That property is internal to Flutter, and
# nothing warns if a future version renames or drops it -- at which point
# x86_64 silently returns and the download grows by about 62 MB.
#
# This asserts an exact set rather than a blocklist, so it catches three
# distinct regressions:
#
#   - x86_64 coming back, after a Flutter upgrade or a reverted property
#   - armeabi-v7a going missing, which would quietly end Android TV support:
#     Chromecast with Google TV and most TV boxes are 32-bit, no arm64
#   - the partial-APK state where --target-platform is applied but the
#     abiFilters are not, which strips the Flutter engine's x86_64 slices while
#     leaving third-party x86_64 libraries behind. That APK still advertises
#     x86_64 and crashes on launch there.
set -euo pipefail

# Sorted under LC_ALL=C and comma-joined. "arm64" sorts before "armeabi"
# because '6' precedes 'e'.
expected="arm64-v8a,armeabi-v7a"

apk="${1:-player/build/app/outputs/flutter-apk/app-release.apk}"

if [ ! -f "$apk" ]; then
  printf '::error::%s does not exist, so its ABIs cannot be checked\n' "$apk"
  exit 1
fi

# Directory names directly under lib/ are the ABI set. An Android App Bundle
# (.aab) nests the same native libs one level deeper, under base/lib/<abi>/,
# so both layouts are matched. zipinfo -1 lists bare paths, so the ^lib/ (or
# ^base\/lib\/) anchor cannot match a path with lib/ somewhere in the middle.
# The [^/]+/ after it requires an ABI segment to actually be present, so a
# bare "lib/" or "base/lib/" directory record (some zip tools store one,
# Flutter's own output does not) can't match and contribute an empty ABI
# ahead of the real names once sorted. The C locale is pinned so a runner's
# locale cannot reorder the comparison string.
actual="$(unzip -Z1 "$apk" \
  | awk -F/ '/^lib\/[^/]+\//{print $2} /^base\/lib\/[^/]+\//{print $3}' \
  | LC_ALL=C sort -u | paste -sd, -)"

# An APK with no lib/ entries yields an empty string and fails here, which is
# intended: a check that passes because it found nothing is worse than no
# check at all.
if [ "$actual" != "$expected" ]; then
  printf '::error::%s ships ABIs [%s], expected [%s]\n' "$apk" "$actual" "$expected"
  printf '\n'
  printf 'Check that disable-abi-filtering=true is still honoured by the current\n'
  printf 'Flutter version (player/android/gradle.properties) and that the\n'
  printf 'abiFilters in player/android/app/build.gradle.kts are intact.\n'
  exit 1
fi

printf 'OK: %s ships exactly [%s]\n' "$apk" "$actual"
