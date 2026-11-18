# media_kit_libs_macos_video (HDR build)

A local replacement for `media_kit_libs_macos_video` 1.1.4, wired in through
`dependency_overrides` in `player/pubspec.yaml`. The pubspec keeps the upstream
name so the override resolves; only the directory name differs. The podspec is
named `media_kit_libs_macos_video.podspec` for the same reason (Flutter looks it
up by plugin name).

## Where the frameworks come from

`macos/Makefile` downloads `libmpv-xcframeworks_<tag>_macos-universal-video-hdr.tar.gz`
from a release of https://github.com/getmydia/libmpv-darwin-build, verifies its
sha256, unpacks it into `macos/Frameworks/` and runs media_kit's
`create_framework_symlinks.sh`. CocoaPods runs `make` when it evaluates the
podspec. `.cache/` and `Frameworks/` are git-ignored.

The `video-hdr` variant is mpv 0.42 + FFmpeg 8 with libplacebo (static shaderc),
MoltenVK linked directly, and a patch that lets mpv embed in a host NSView. It
needs macOS 12.0 or newer.

## Bumping the version

1. Tag and release a new build in getmydia/libmpv-darwin-build.
2. In `macos/Makefile`, update both `MPV_XCFRAMEWORKS_VERSION` and
   `MPV_XCFRAMEWORKS_SHA256SUM`.
3. Delete `macos/.cache` and `macos/Frameworks`, then `flutter clean` and rebuild.

## NOTICE

The app ships these Apache-2.0 components inside the libmpv build; their license
text is registered in the player's license page (`lib/main.dart`,
`assets/licenses/apache-2.0.txt`):

- MoltenVK
- shaderc
- SPIRV-Tools
- SPIRV-Cross
