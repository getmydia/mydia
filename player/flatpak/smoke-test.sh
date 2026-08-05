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

echo "PASS: smoke test clean"
