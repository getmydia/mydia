#!/usr/bin/env bash
# Prints the mpv stack's source tags as shell assignments:
#   eval "$(player/appimage/pins.sh)"
#
# libass, libplacebo and mpv are read from the Flatpak manifest, which stays
# their single source of truth. FFmpeg is pinned here because the Flatpak
# takes it from the GNOME runtime and has no tag to share. mpv 0.41 needs
# FFmpeg 6.1 or newer (libavcodec >= 60.31.102); Ubuntu 22.04 ships 4.4.
set -euo pipefail
manifest="$(dirname "$0")/../flatpak/dev.mydia.player.yml"

tag_of() {
  awk -v m="  - name: $1" '
    $0 == m {inside=1; next}
    /^  - name: / {inside=0}
    inside && /^ +tag: / {gsub(/^ +tag: |'"'"'/, ""); print; exit}' "$manifest"
}

printf 'LIBASS_TAG=%s\n' "$(tag_of libass)"
printf 'LIBPLACEBO_TAG=%s\n' "$(tag_of libplacebo)"
printf 'MPV_TAG=%s\n' "$(tag_of mpv)"
printf 'FFMPEG_TAG=%s\n' n7.1.5
