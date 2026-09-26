#!/usr/bin/env bash
#
# Stamp a player checkout with its release channel before `flutter build`.
#
#   tool/apply-channel.sh [--names-only] [--root <player dir>] <version>
#
# The channel comes from the version: -beta.N is beta, -dev.N is dev,
# anything else is stable. Beta and dev builds get "Mydia Player Beta" /
# "Mydia Player Dev" as their display name on every platform and a badged
# launcher icon. Stable edits nothing, so a release build is byte-identical
# to one made without this script.
#
# CI only. It rewrites tracked files in place; `git checkout player/` undoes it.
# App identity (dev.mydia.player, the Windows AppId, PRODUCT_NAME) is never
# touched, so switching release track still upgrades the same install.
#
# Emits MYDIA_CHANNEL and MYDIA_APP_NAME to $GITHUB_ENV when set, and writes
# <root>/.build-channel for player/flatpak/build.sh, which runs inside the
# flatpak sandbox where the job's environment does not reach.
#
# Edits use perl rather than sed -i, whose flags differ between the Linux,
# macOS and Git Bash on Windows runners this runs on.

set -euo pipefail

names_only=false
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --names-only) names_only=true; shift ;;
    --root) root="$2"; shift 2 ;;
    -*) echo "apply-channel: unknown flag $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

version="${1:?usage: apply-channel.sh [--names-only] [--root dir] <version>}"

case "$version" in
  *-beta.*) channel=beta; name="Mydia Player Beta" ;;
  *-dev.*)  channel=dev;  name="Mydia Player Dev" ;;
  *-*)
    echo "::warning::apply-channel: unrecognised prerelease '$version', branding as stable" >&2
    channel=stable; name="Mydia Player" ;;
  *)        channel=stable; name="Mydia Player" ;;
esac

# Replace one expected pattern in one file, or die. $1 file, $2 perl regex with
# a (prefix) and (suffix) capture around the name, $3 expected match count.
rewrite() {
  local file="$root/$1" regex="$2" want="${3:-1}"
  [ -f "$file" ] || { echo "apply-channel: missing $1" >&2; exit 1; }
  NAME="$name" REGEX="$regex" WANT="$want" perl -0777 -pi -e '
    my $n = s/$ENV{REGEX}/$1$ENV{NAME}$2/g;
    die "apply-channel: expected $ENV{WANT} match(es) in $ARGV, found $n\n"
      unless $n == $ENV{WANT};
  ' "$file"
}

if [ "$channel" != stable ]; then
  rewrite android/app/src/main/AndroidManifest.xml '(android:label=")Mydia Player(")'
  rewrite ios/Runner/Info.plist '(<key>CFBundleDisplayName</key>\s*<string>)Mydia Player(</string>)'
  rewrite macos/Runner/Info.plist '(<key>CFBundleName</key>\s*<string>)\$\(PRODUCT_NAME\)(</string>)'
  rewrite windows/runner/Runner.rc '(VALUE "(?:FileDescription|ProductName)", ")Mydia Player(")' 2
  rewrite windows/installer.iss '(#define MyAppName ")Mydia Player(")'
  rewrite linux/runner/my_application.cc '(gtk_window_set_title\(window, ")Mydia Player("\))'
  rewrite flatpak/dev.mydia.player.desktop '(?m)(^Name=)Mydia Player($)'
  rewrite flatpak/dev.mydia.player.metainfo.xml '(<component[^>]*>\s*<id>dev\.mydia\.player</id>\s*<name>)Mydia Player(</name>)'

  if [ "$names_only" = false ]; then
    : # Task 5 regenerates launcher icons here.
  fi
fi

printf '%s\n' "$channel" > "$root/.build-channel"

if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'MYDIA_CHANNEL=%s\nMYDIA_APP_NAME=%s\n' "$channel" "$name" >> "$GITHUB_ENV"
fi
printf 'MYDIA_CHANNEL=%s\nMYDIA_APP_NAME=%s\n' "$channel" "$name"
