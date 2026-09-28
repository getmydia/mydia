#!/usr/bin/env bash
# pins.sh reads three tags out of the Flatpak manifest. If that manifest is
# reordered or a module renamed, this fails instead of the AppImage quietly
# building a different mpv than the Flatpak.
set -euo pipefail
cd "$(dirname "$0")/../../.."

out="$(player/appimage/pins.sh)"
eval "$out"

manifest=player/flatpak/dev.mydia.player.yml
for pair in "libass:$LIBASS_TAG" "libplacebo:$LIBPLACEBO_TAG" "mpv:$MPV_TAG"; do
  module="${pair%%:*}" tag="${pair#*:}"
  [ -n "$tag" ] || { echo "FAIL: empty tag for $module"; exit 1; }
  # The tag must appear inside that module's block, not merely somewhere.
  awk -v m="  - name: $module" -v t="$tag" '
    $0 == m {inside=1; next}
    /^  - name: / {inside=0}
    inside && index($0, "tag: ") && index($0, t) {found=1}
    END {exit !found}' "$manifest" \
    || { echo "FAIL: $module tag $tag not in its manifest block"; exit 1; }
done

[[ "$FFMPEG_TAG" =~ ^n[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || { echo "FAIL: FFMPEG_TAG '$FFMPEG_TAG' is not an FFmpeg release tag"; exit 1; }

echo "OK: $out" | tr '\n' ' '; echo
