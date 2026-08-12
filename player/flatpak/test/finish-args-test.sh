#!/usr/bin/env bash
# Asserts the Flatpak manifest declares every runtime permission the player
# depends on, and records why each one is there.
#
# The Secret Service entry earns the whole file. Its absence did not crash
# anything, it silently cost every Flatpak user their pairing on the next
# launch: flutter_secure_storage reaches the host keyring through libsecret
# over D-Bus, and a Flatpak sandbox denies every session bus name that is not
# listed here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MANIFEST="$REPO_ROOT/player/flatpak/dev.mydia.player.yml"

# Read only the finish-args block, so a match inside modules: or in a prose
# comment cannot satisfy an assertion.
finish_args="$(awk '/^finish-args:/{f=1;next} /^[a-z-]+:/{f=0} f' "$MANIFEST")"

if [ -z "$finish_args" ]; then
  echo "FAIL: could not parse a finish-args block out of $MANIFEST"
  exit 1
fi

fail=0

require_arg() {
  local arg="$1" why="$2"
  # Strip indentation and match the whole line, so --share=network cannot be
  # satisfied by a longer argument that merely starts with it.
  if ! printf '%s\n' "$finish_args" \
     | sed 's/^[[:space:]]*//' \
     | grep -qxF -- "- $arg"; then
    echo "FAIL: finish-args is missing $arg"
    echo "      Without it: $why"
    fail=1
  fi
}

require_arg --share=network \
  "the player cannot reach the server or any p2p peer"
require_arg --socket=wayland \
  "the window does not open on a Wayland session"
require_arg --socket=fallback-x11 \
  "the window does not open on an X11 session"
require_arg --socket=pulseaudio \
  "playback has no audio"
require_arg --device=dri \
  "hardware video decode is unavailable"
require_arg --talk-name=org.freedesktop.secrets \
  "every credential write fails, so a pairing does not survive a restart"

[ "$fail" -eq 0 ] || exit 1

echo "PASS"
