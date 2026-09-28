#!/usr/bin/env bash
# Launches the AppImage under Xvfb and asserts it survives ten seconds with no
# dynamic linker error, then checks every bundled ELF resolves. The AppImage
# counterpart of player/flatpak/smoke-test.sh.
#
# Usage: player/appimage/smoke-test.sh [--install-host-baseline] <path-to-AppImage>
#
# Run it in a clean ubuntu:22.04 with --install-host-baseline, never in the
# build image, whose -dev packages would hide a library the AppImage forgot.
# The baseline is exactly the AppImage excludelist's contract: the GL stack,
# X11/xcb, fontconfig, freetype, ALSA and friends that every desktop provides
# and that the AppImage must not bundle. If the test fails for a library
# outside this list, bundle that library; never grow this list to make it pass.
set -euo pipefail

if [ "${1:-}" = --install-host-baseline ]; then
  shift
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    xvfb xauth file \
    libgl1 libegl1 libgles2 libgl1-mesa-dri libgbm1 libdrm2 libglx0 \
    libx11-6 libx11-xcb1 libxcb1 libxcb-dri2-0 libxcb-dri3-0 \
    libfontconfig1 libfreetype6 libharfbuzz0b libfribidi0 libexpat1 \
    libasound2 libgpg-error0 libcom-err2 libgmp10 libuuid1 zlib1g >/dev/null
fi

IMAGE="$(readlink -f "${1:?AppImage path required}")"
WORK="$(mktemp -d)"
LOG="$WORK/run.log"
trap 'rm -rf "$WORK"' EXIT

# CI runners and containers have no FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1

xvfb-run -a --server-args="-screen 0 1280x800x24" "$IMAGE" >"$LOG" 2>&1 &
WRAPPER_PID=$!
sleep 10

if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
  echo "::error::Player exited within 10 seconds. Output follows:"
  cat "$LOG"
  exit 1
fi
kill -TERM "$WRAPPER_PID" 2>/dev/null || true
wait "$WRAPPER_PID" 2>/dev/null || true

if grep -qiE 'error while loading shared libraries|cannot open shared object|Cannot find libmpv' "$LOG"; then
  echo "::error::Library load error in output:"
  cat "$LOG"
  exit 1
fi

# media_kit dlopens libmpv, so the run above only proves the libraries it
# happened to load. Check every ELF in the image resolves with the same paths
# AppRun sets.
(cd "$WORK" && "$IMAGE" --appimage-extract >/dev/null)
ROOTFS="$WORK/squashfs-root"
export LD_LIBRARY_PATH="$ROOTFS/usr/lib/mydia-player/lib:$ROOTFS/usr/lib"
missing="$(find "$ROOTFS/usr/lib" -type f \( -name '*.so*' -o -name mydia-player \) \
  -exec sh -c 'file -b "$1" | grep -q ELF && ldd "$1" | sed "s|^|$1: |"' _ {} \; \
  | grep 'not found' || true)"
if [ -n "$missing" ]; then
  echo "::error::Unresolved libraries:"
  echo "$missing"
  exit 1
fi

echo "Smoke test passed"
