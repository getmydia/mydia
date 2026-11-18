# Apple HDR output: mpv gpu-next on an EDR layer, macOS first

Spec 2 of the HDR roadmap in
`design/specs/2026-11-17-player-hdr-foundation-design.md` (spec 1). Spec 1
makes HDR color correct everywhere by tonemapping. This spec makes HDR files
show as HDR on a Mac with an HDR screen.

## Why

The player renders mpv into a Flutter texture through media_kit's
`VideoController`. The texture is 8-bit SDR, so an HDR file can at best be
tonemapped down to SDR, and Dolby Vision RPU reshaping is impossible because
`vo=gpu` ignores the RPU.

mpv's `vo=gpu-next` renders through libplacebo, applies the RPU, and with
`target-colorspace-hint` tells macOS the layer is PQ or HLG. macOS then
composites it with EDR: highlights brighter than UI white, up to the screen's
headroom. The roadmap chose this over AVPlayer so the player keeps one engine
and the mechanism carries to the other platforms.

## Spike findings (2026-11-17)

Run on an M1 MacBook Air (SDR panel with EDR headroom up to 2.0) and an M2 Pro
MacBook Pro (XDR panel, headroom up to 16).

- Homebrew mpv with gpu-next, libplacebo 7.387 and MoltenVK 1.4.2 picks a
  10-bit `HDR10_ST2084` swapchain for HDR10, sets the Metal layer to
  `ITUR_2100_PQ` with EDR metadata, and the screen's headroom rises (1.2 to
  1.5 on the Air, 1.2 to 13.8 on the Pro). DV 8.1 is decoded as
  `dolbyvision` and its peak comes from the RPU's L1 metadata, so the RPU is
  read. HLG works (mpv 0.42 outputs it as PQ).
- Stock libmpv cannot be embedded with gpu-next on macOS. The mac backend
  ignores `--wid` and opens its own window, up to upstream master on
  2026-11-17. The render API offers OpenGL, D3D11 and software only.
- A 50-line patch to `video/out/mac_common.swift` and
  `video/out/vulkan/context_mac.m` makes `wid` an `NSView*` host: mpv adds its
  view, with the Metal layer, as a subview instead of creating a window. It
  applied unchanged to mpv 0.41.0 and 0.42.0.
- With the patch, a Flutter macOS app hosting the view in an `AppKitView` showed
  HDR10 in EDR with Flutter widgets drawn over it. On the Pro, with a clip of
  SDR content at 203 nits plus 203, 1,000 and 4,000-nit patches, the patches
  stepped up in brightness and the 203-nit patch matched Flutter's white.
  Resize, fullscreen and a button over the video worked.
- `mpv_terminate_destroy` on the main thread deadlocks: the video output's
  teardown does `DispatchQueue.main.sync`.
- No `libmpv-darwin-build` variant (through v0.7.3) carries libplacebo,
  shaderc or MoltenVK.
- Synthetic HDR clips made by tagging `testsrc2` as PQ put most pixels near
  10,000 nits. libplacebo's dynamic peak detection then lowers exposure for the
  whole frame and nothing looks brighter than UI white. Test clips must place
  SDR content at reference white (see Testing).

## Goal

- On macOS, every file plays through gpu-next in a platform view. HDR files
  show in EDR on screens with headroom, and are tonemapped by libplacebo on
  screens without.
- Dolby Vision, including profile 5, plays with its RPU applied.
- Nothing about tracks, subtitles, chrome, stats, casting or the HLS and p2p
  plumbing changes for the viewer, apart from the picture.
- Any Mac where gpu-next cannot start still plays, on the texture path.

## Non-goals

- iOS, iPadOS and tvOS. mpv has no iOS Vulkan context, so they need either a
  UIView port of the patch or a Metal render API. They get their own spec,
  which reuses this one's build pipeline.
- Android, Windows and Linux (specs 3 to 5).
- Picture tuning beyond mpv's defaults, such as the `high-quality` profile.
- Contributing the patch upstream.

## 1. The libmpv build

### The fork

`getmydia/libmpv-darwin-build` is a fork of `media-kit/libmpv-darwin-build`,
the Nix-based builder behind media_kit's Apple libraries. It adds a
`video-hdr` variant, built for `macos-universal` only, containing:

- everything `video-default` contains;
- libplacebo (`mk-pkg-libplacebo`);
- shaderc, which libplacebo uses to compile shaders at runtime;
- MoltenVK, built from source;
- the `wid` patch, in the existing `patches/` directory.

There is no Vulkan loader. mpv and libplacebo link MoltenVK directly as their
Vulkan implementation, so nothing depends on finding an ICD manifest at
runtime. The spike hit exactly that failure with Homebrew's loader
(`VK_ERROR_INCOMPATIBLE_DRIVER` until `VK_ICD_FILENAMES` was set). iOS will
need direct linking anyway.

The variant stays within `video-default`'s licensing: libplacebo is LGPL,
shaderc and MoltenVK are Apache-2.0, and no GPL encoder is added.

Releases are tagged after the upstream release they rebase on, for example
`v0.7.3-mydia.1`. The fork's own CI builds them, so mydia's CI gains no macOS
build job.

### Consuming it

`player/packages/media_kit_libs_macos_video_hdr` is a local package holding
media_kit's macOS Makefile and podspec, pointed at the fork's release URL with
a pinned sha256. `pubspec.yaml` overrides `media_kit_libs_macos_video` with it
under `dependency_overrides`. media_kit itself is untouched, and every other
platform keeps the stock libraries.

The macOS app is not sandboxed and updates through Sparkle, so the bundled
frameworks are signed and notarized with the app the same way media_kit's are
today.

### The patch

- `MacCommon.config` checks `option.vo.WinID`. When it is set, it creates
  mpv's view as usual, adds it as an autoresizing subview of the host
  `NSView` instead of creating a window, and observes the view's frame and the
  host window's backing-properties and screen notifications.
- `surfacePixelSize()` returns the window's pixel frame, or the embedded view's
  bounds converted to backing pixels. `context_mac.m`'s `resize` uses it
  instead of reading `window.framePixel`.
- `isVisible()` uses the host window's occlusion state.
- `uninit` removes the observers and the host reference.

Each rebase re-applies the patch, and the fork's CI runs the smoke test in
Testing before publishing. If upstream mpv gains `wid` support or a Metal or
Vulkan render API on macOS, the patch is dropped.

## 2. The native surface plugin

`MpvSurfacePlugin` lives in `macos/Runner` and is registered in
`MainFlutterWindow`, like `NativeTabBarPlugin`.

- It registers the platform view factory `mydia/mpv-surface`. The view,
  `MpvHostView`, is a layer-backed `NSView` with a black background. mpv adds
  its own view inside it.
- It talks to mpv through the libmpv C API with the `player.handle` that
  media_kit exposes.

### Who writes to mpv

Every write that creates, changes or destroys the video output goes through
the plugin, on its own serial background queue, and replies to Dart
asynchronously. That covers `wid`, `vo`, `vid`, `panscan`, the quality options
in section 4, and teardown.

The reason is the deadlock found in the spike. mpv's mac video output does
`DispatchQueue.main.sync` while it is created and torn down. Dart can run on
the main thread on macOS, depending on Flutter's thread-merging setting, and a
synchronous `mpv_set_property` from it would block the main thread while mpv
waits on it.

### attach(handle, viewId)

Sets, in order: `wid` (the host view's pointer), `vo=gpu-next`,
`gpu-api=vulkan`, `gpu-context=macvk`, `target-colorspace-hint=yes`,
`hwdec=videotoolbox`, the options in section 4, then `vid=auto`.

media_kit opens every player with `vid=no`, so no video output exists until
`vid=auto`, and mpv reads `wid` when it creates one. This is the sequence
media_kit's `VideoController` follows today with `vo=libmpv`, and on macOS
`VideoController` is no longer constructed.

The spike set `wid` before `mpv_initialize`. The plan's first task confirms
that setting it at runtime, before the output exists, behaves the same. If it
does not, the patch reads the option when the output is configured, which it
already does.

### detach(handle)

Sets `vid=no` and waits until `current-vo` reads empty, so the output is
destroyed while the host view still exists. The player screen calls it before
`player.dispose()`. That also keeps the video output out of the
`mpv_terminate_destroy` media_kit runs from Dart five seconds after dispose,
the second route to the same deadlock.

A host view leaving its window without a detach (hot restart, an error path)
runs `detach` from `viewWillMove(toWindow: nil)`.

If the output has not gone after 3 seconds, the plugin logs it and returns, so
closing the player never hangs.

### Resize, fullscreen and screens

The patched mpv follows its view's autoresizing and the window's
notifications. The plugin does nothing for them.

### Reporting

An event channel sends `{edrHeadroom, potentialHeadroom, screenName}` when the
host window's screen or headroom changes, for the stats panel.

## 3. The Flutter side

### PlayerVideoSurface

`_buildBody` in `player_screen.dart` builds `PlayerVideoSurface` where it now
builds `Video(...)`.

- On macOS it is a `Stack`: `AppKitView('mydia/mpv-surface')`, then
  `MydiaSubtitleView`, then the chrome.
- Everywhere else it is today's `Video(controller: ...)`.

The path is chosen once, from the platform, and kept in the screen's state.
**Settings → Diagnostics → Use the legacy video output** (stored as
`legacy_mac_video_output`) forces the texture path on macOS. It is the escape
hatch for running every file through the new path: a viewer whose video looks
wrong or does not start turns it on.

### Player screen changes on macOS

- No `VideoController` is built.
- `_openPlayerAndStart` calls the plugin's `attach` once the platform view
  exists, before `open`.
- Both dispose paths (`_disposePlayer` and the supersede path) call `detach`
  before `player.dispose()`.
- The loading, error and cast views replace the surface, as they replace
  `Video` today.

### Chrome without VideoState

`playbackChromeBuilder` takes a `Player` and a `SubtitleLift` instead of
media_kit's `VideoState`, which is all the chrome read from it, and serves both
outputs. On other platforms, `Video`'s `controls:` callback adapts:
`(state) => build(state.widget.controller.player, VideoStateSubtitleLift(state))`.
On macOS the surface passes the player and a `SurfaceSubtitleLift`.

### Subtitles

- Text tracks: `MydiaSubtitleView` is a small copy of media_kit's
  `SubtitleView`, which only reads `player.stream.subtitle`. It keeps the
  animated padding and uses `subtitleViewConfigurationFor`, so sizing matches
  the other platforms.
- Bitmap tracks: mpv draws them when `subtitle_render.dart` says so, now into
  the HDR surface, where libplacebo places them at SDR white.
- `SurfaceSubtitleLift` drives both, as `VideoStateSubtitleLift` does: overlay
  padding for text, `sub-pos` for bitmaps.

### Fit and fill

Today a `BoxFit` on `Video`. On the surface it becomes mpv's `panscan`: 0 for
fit, 1.0 for fill, sent through the plugin.

### What does not change

Fullscreen, always-on-top, keyboard shortcuts, scrubbing and its thumbnails,
cast and stats sampling all work on the `Player` or the window, not on the
texture.

On an HDR screen, Flutter's SDR white (subtitles, chrome) looks dimmer next to
HDR highlights. That is how EDR composites SDR content, as in QuickTime and
Infuse, and is not a defect.

## 4. mpv options, spec 1 and stats

### Undoing media_kit's quality cuts

media_kit sets `scale=bilinear`, `dscale=bilinear`, `dither=no`,
`hdr-compute-peak=no`, `correct-downscaling=no`, `linear-downscaling=no` and
`sigmoid-upscaling=no` on every player, for a texture path on weak GPUs.
`hdr-compute-peak=no` in particular degrades HDR tone mapping. `attach` sets
each back to mpv's default. The spike ran on those defaults, 4K HDR10 on the
M1 Air without dropped frames.

### Tone mapping

Spec 1's options for the SDR texture (`tone-mapping=bt.2390`,
`target-trc=srgb`) apply only on the texture path, so the escape hatch and the
other platforms keep them. On the surface, `target-colorspace-hint` decides:
PQ or HLG into EDR when the screen has headroom, and libplacebo's own tone
mapping to SDR when it does not.

### Capability claims

This amends spec 1's per-client table.

| Client | Claims |
| --- | --- |
| macOS, surface path | `hdr10+`, `hdr10`, `hlg`, and `dolby_vision` once verified (below) |
| macOS, escape hatch on | spec 1's native claims |

The claim keeps spec 1's meaning: the client plays the format with correct
color, whatever the screen. Server behavior is unchanged.

`dolby_vision` covers profile 5, which has no base layer and plays correctly
only if the RPU is applied. The spike verified DV 8.1 only. The plan has a
manual step that plays a real profile 5 file on the MacBook Pro, and macOS
claims `dolby_vision` only after it passes.

### Stats for nerds

Spec 1's HDR row reads, on macOS:

- `HDR output, PQ, headroom 13.8x` when `video-target-params/gamma` is PQ or
  HLG and the plugin reports headroom above 1;
- `tonemapped by player (libplacebo)` otherwise;
- the source label adds `RPU applied` when mpv reports the `dolbyvision`
  color matrix.

## 5. Failures

- **gpu-next does not start** (MoltenVK fails, no usable Metal device): after
  `vid=auto` on a file with a video track, the plugin polls for up to 2
  seconds. `current-vo` set means started. mpv deselecting the video track
  (`vid` reads `no`, or the track is listed with none selected) means the
  video output was rejected: the screen detaches, rebuilds the playback on the
  texture path, and records the failure for the running app version, so later
  playbacks go straight to the texture path until an update. The stats Why row
  says so. Neither by the deadline is a slow start, not a failure: that
  playback falls back to the texture path and nothing is recorded.
- **Hardware decode fails:** mpv falls back to software decode, as today.
- **Detach does not complete:** logged after 3 seconds, and the screen
  continues closing.

## Testing

**Dart**

- `PlayerVideoSurface` picks the path from the platform and the escape hatch.
- `playbackChromeBuilder` with a `VideoStateSubtitleLift` and a
  `SurfaceSubtitleLift`.
- `MydiaSubtitleView` and `SurfaceSubtitleLift`.
- The fit and fill to `panscan` mapping.
- The macOS capability builder, with and without the hatch and the DV flag.
- The stats HDR row's labels.
- The fallback flow, with a fake plugin.

**Native (RunnerTests)**

The plugin reaches mpv through a small protocol, so a fake can assert:

- `wid` and the gpu-next options are set before `vid=auto`;
- `detach` waits for `current-vo` to clear;
- `viewWillMove(toWindow: nil)` triggers a detach;
- no mpv call happens on the main thread.

**Fork CI**

After each build, a Swift probe embeds the built libmpv in a window, plays the
calibrated clip and asserts `current-vo` is `gpu-next` and the swapchain is
PQ. If the macOS arm64 runner has no usable Metal device, that check becomes a
manual release step.

**Fixtures**

Generated by a committed script, never committed themselves, and never from
real titles. The PQ clips (HDR10, and Dolby Vision 8.1 built on the same
base) put SDR content at 203 nits (`zscale` with `npl=203`) and add fixed
patches at 203, 1,000 and 4,000 nits, with mastering metadata to match. The
HLG clip has no patches: HLG has no absolute nits. This replaces spec 1's `testsrc2`-tagged-as-PQ clips, which the spike
showed are unusable for judging brightness. DV 8.1 clips get an RPU from
`dovi_tool generate`.

**Manual, before release**

On the MacBook Pro (XDR), the MacBook Air and an SDR external screen: the
levels clip, HDR10, HLG, DV 8.1, a real DV profile 5 file kept locally, an SDR
file, bitmap and text subtitles, fill, fullscreen, dragging the window between
screens, closing during playback, and ten open-and-close cycles in a row.
Dropped frames are read from stats at 4K60.

## Risks

- **Patch drift.** Upstream changes to mpv's mac output code can break the
  patch. The fork's smoke test catches it at rebase.
- **Platform view cost.** Flutter composites widgets over a macOS platform view
  with extra layers. The manual pass checks dropped frames.
- **App size and power.** shaderc and MoltenVK add an estimated 15 to 25 MB,
  which the plan measures. gpu-next costs more GPU than a bilinear texture.
  The escape hatch covers a user who needs the old path.
- **Intel Macs.** The build is universal, but no Intel Mac is available for
  testing. The automatic fallback is their safety net.
