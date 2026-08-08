#!/usr/bin/env bash
# Assert that every Apple deployment-target literal in the player agrees, per
# platform.
#
# The minimum OS version is duplicated across a Podfile, an Xcode project and a
# podspec on each Apple platform, and nothing in the toolchain keeps them in
# step. By August 2026 they had drifted far enough that the shipped iOS app
# declared a lower minimum than the Pods it linked against, which is what
# earned an ITMS-90068 warning from App Store Connect.
#
# This asserts agreement, not any particular version. Raising a platform's
# minimum stays a player-side edit and no version literal lives in CI.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

status=0
ios_found=""
macos_found=""

# A dotted version literal. Kept on its own line, well away from any path
# containing the word the Check / Flutter Pin scan looks for, so that scan
# never sees a version pattern and that word on one line.
num='[0-9][0-9.]*[0-9]'

# Every shape a deployment target takes, per platform: a Podfile `platform`
# directive, an Xcode build setting, and a podspec `s.platform`. The build
# setting also turns up inside Podfile post_install blocks that force pods up
# to the app's own floor, so a Podfile can carry two literals rather than one.
#
# Each file is scanned with its platform's whole set rather than one pattern
# per file, so a second literal added to any of them is caught automatically.
ios_pattern='platform :ios,|IPHONEOS_DEPLOYMENT_TARGET|s\.platform *= *:ios,'
macos_pattern='platform :osx,|MACOSX_DEPLOYMENT_TARGET|s\.platform *= *:osx,'

# scan <platform> <file>
#
# Records every version literal on lines of <file> that declare a deployment
# target. A file that is missing, or that yields no literal, is an error: a
# check that passes because it found nothing is worse than no check at all.
scan() {
  local platform="$1" file="$2"
  local pattern hits

  case "$platform" in
    ios) pattern="$ios_pattern" ;;
    macos) pattern="$macos_pattern" ;;
  esac

  if [ ! -f "$file" ]; then
    printf '::error::%s is missing, so its deployment target cannot be checked\n' "$file"
    status=1
    return
  fi

  hits="$(grep -hE "$pattern" "$file" | grep -oE "$num" | sort -u || true)"

  if [ -z "$hits" ]; then
    printf '::error::%s declares no deployment target, so it cannot be checked\n' "$file"
    status=1
    return
  fi

  while IFS= read -r value; do
    case "$platform" in
      ios) ios_found+="$value $file"$'\n' ;;
      macos) macos_found+="$value $file"$'\n' ;;
    esac
  done <<<"$hits"
}

# scan_app_framework_plist <file>
#
# The one optional source. MinimumOSVersion sits on the line after its <key>,
# and the build toolchain deletes the key outright at build time, so an absent
# key is correct and contributes no value. The file itself must still exist.
scan_app_framework_plist() {
  local file="$1"
  local hits

  if [ ! -f "$file" ]; then
    printf '::error::%s is missing, so its minimum OS version cannot be checked\n' "$file"
    status=1
    return
  fi

  hits="$(grep -A1 -E '<key>MinimumOSVersion</key>' "$file" | grep -oE "$num" | sort -u || true)"
  [ -z "$hits" ] && return

  while IFS= read -r value; do
    ios_found+="$value $file"$'\n'
  done <<<"$hits"
}

# verdict <label> <collected>
verdict() {
  local label="$1" found="$2"
  local distinct count

  [ -z "$found" ] && return

  distinct="$(printf '%s' "$found" | awk 'NF {print $1}' | sort -u)"
  count="$(printf '%s\n' "$distinct" | wc -l)"

  if [ "$count" -gt 1 ]; then
    printf '::error::%s deployment targets disagree: %s\n' \
      "$label" "$(printf '%s' "$distinct" | tr '\n' ' ')"
    printf '%s' "$found" | awk 'NF' | sort | sed 's/^/  /'
    status=1
  else
    printf 'OK: every %s deployment target is %s\n' "$label" "$distinct"
  fi
}

scan ios player/ios/Podfile
scan ios player/ios/Runner.xcodeproj/project.pbxproj
scan ios player/rust_builder/ios/mydia_player_p2p.podspec
scan_app_framework_plist player/ios/Flutter/AppFrameworkInfo.plist

scan macos player/macos/Podfile
scan macos player/macos/Runner.xcodeproj/project.pbxproj
scan macos player/rust_builder/macos/mydia_player_p2p.podspec

verdict iOS "$ios_found"
verdict macOS "$macos_found"

if [ "$status" -ne 0 ]; then
  printf '\n'
  printf 'Every file above must name the same minimum for its platform.\n'
  printf 'Set them all to the same value and re-run.\n'
fi

exit "$status"
