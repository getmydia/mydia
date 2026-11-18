#!/bin/sh

# Copied from media_kit's `media_kit_libs_macos_video` (upstream shares this
# script across its `media_kit_libs_{ios,macos}_{audio,video}` packages) for
# this package, which ships the video-hdr libmpv build instead. Keep it in
# step with upstream's copy. The one local change: a missing or empty
# framework directory fails instead of creating no links and succeeding.

set -e
set -u

SRC_DIR="$1"
SYMLINKS_DIR="$2"

# Computes the relative path between two given paths
#
# Example:
# ```
# relpath Frameworks/Mpv.xcframework/ios-arm64 Frameworks/.symlinks/mpv
# ../../Mpv.xcframework/ios-arm64
# ```
#
# Source: https://stackoverflow.com/a/14914070
relpath() {
    [ $# -ge 1 ] && [ $# -le 2 ] || return 1
    current="${2:+"$1"}"
    target="${2:-"$1"}"
    [ "$target" != . ] || target=/
    target="/${target##/}"
    [ "$current" != . ] || current=/
    current="${current:="/"}"
    current="/${current##/}"
    appendix="${target##/}"
    relative=''
    while appendix="${target#"$current"/}"
        [ "$current" != '/' ] && [ "$appendix" = "$target" ]; do
        if [ "$current" = "$appendix" ]; then
            relative="${relative:-.}"
            echo "${relative#/}"
            return 0
        fi
        current="${current%/*}"
        relative="$relative${relative:+/}.."
    done
    relative="$relative${relative:+${appendix:+/}}${appendix#/}"
    echo "$relative"
}

# Create symbolic links from a given source directory to a destination directory
# for a specific framework
#
# Example:
# ```
# create_framework_symlinks Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv
# Frameworks/.symlinks/mpv/ios -> ../../Mpv.xcframework/ios-arm64
# Frameworks/.symlinks/mpv/ios-simulator -> ../../Mpv.xcframework/ios-arm64_x86_64-simulator
# ```
create_framework_symlinks() {
    SRC_DIR="$1"
    SYMLINKS_DIR="$2"

    # In a pipeline `find` failing would not stop `set -e`: the loop's
    # status is the pipeline's. Listing first makes a failure exit here.
    [ -d "${SRC_DIR}" ] || {
        echo "create_framework_symlinks: ${SRC_DIR} is not a directory" >&2
        exit 1
    }
    SLICES="$(find "${SRC_DIR}" -mindepth 1 -maxdepth 1 -type d)"
    [ -n "${SLICES}" ] || {
        echo "create_framework_symlinks: no slices in ${SRC_DIR}" >&2
        exit 1
    }

    echo "${SLICES}" | while read SRC; do
        SLUG="$(basename "${SRC}")"
        NAME="$(echo "${SLUG}" | cut -d '-' -f 1 -f 3)"

        SRC_RELATIVE="$(relpath "${SYMLINKS_DIR}" "${SRC}")"

        ln -s "${SRC_RELATIVE}" "${SYMLINKS_DIR}/${NAME}"
    done
}

create_framework_symlinks "${SRC_DIR}" "${SYMLINKS_DIR}"
