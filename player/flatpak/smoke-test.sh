#!/usr/bin/env bash
# Launches the installed Flatpak under Xvfb and asserts it survives ten
# seconds, then exits cleanly on SIGTERM. Catches a missing or unresolvable
# shared library, libmpv above all, which is the failure this package exists
# to remove.
#
# Usage: player/flatpak/smoke-test.sh <branch>
set -euo pipefail

BRANCH="${1:?branch required (stable or beta)}"
LOG="$(mktemp)"

echo "Launching dev.mydia.player//${BRANCH} under Xvfb"
xvfb-run -a --server-args="-screen 0 1280x800x24" \
  flatpak run --branch="$BRANCH" dev.mydia.player >"$LOG" 2>&1 &
WRAPPER_PID=$!

sleep 10

# If the app dies, xvfb-run exits too, so the wrapper's liveness is a valid
# proxy for the app's.
if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
  echo "::error::Player exited within 10 seconds. Output follows:"
  cat "$LOG"
  exit 1
fi

echo "Still running after 10s. Last output:"
tail -n 20 "$LOG"

kill -TERM "$WRAPPER_PID" 2>/dev/null || true
wait "$WRAPPER_PID" 2>/dev/null || true

# A dynamic-linker failure prints to stderr before dying, so a clean run must
# not mention one even if the process happened to survive the ten seconds.
if grep -qiE 'error while loading shared libraries|cannot open shared object' "$LOG"; then
  echo "::error::Dynamic linker error in output:"
  cat "$LOG"
  exit 1
fi

# The Secret Service permission does not crash anything when missing. It
# silently costs the user their pairing on the next launch, which no runtime
# smoke test can observe in ten seconds. Assert on the exported metadata
# instead, which is what actually governs the installed app.
#
# This reads metadata rather than making a live D-Bus call on purpose: a real
# call would need a session bus and a running Secret Service on the runner,
# neither of which is guaranteed, and would turn a correctness check into a
# flaky one.
echo "Checking exported permissions"
PERMS="$(flatpak info --show-permissions "dev.mydia.player//${BRANCH}")"
if ! grep -qx 'org.freedesktop.secrets=talk' <<<"$PERMS"; then
  echo "::error::Exported app is missing org.freedesktop.secrets=talk."
  echo "Credential writes would fail and pairings would not survive a restart."
  echo "Permissions follow:"
  echo "$PERMS"
  exit 1
fi

echo "PASS: smoke test clean"
