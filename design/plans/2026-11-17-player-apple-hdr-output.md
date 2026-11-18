# Apple HDR Output (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, play every file through mpv `vo=gpu-next` in a native platform view, so HDR shows in EDR and Dolby Vision gets its RPU applied.

**Architecture:** A getmydia fork of `libmpv-darwin-build` ships a `video-hdr` libmpv (libplacebo, shaderc, MoltenVK, `wid`-embedding patch) that the player swaps in through a `dependency_overrides` package. A Swift `MpvSurfacePlugin` hosts mpv's view in an `AppKitView` and makes every video-output write on a background queue. On macOS the player screen builds `PlayerVideoSurface` (platform view, Flutter text subtitles, chrome) instead of media_kit's `Video`, keeping media_kit's `Player` for everything else.

**Tech Stack:** Flutter 3.47 (macOS `AppKitView`), media_kit 1.2.6 / media_kit_video 2.0.1, Swift (AppKit, XCTest), libmpv 0.42 + libplacebo + MoltenVK, Nix (fork build), ffmpeg + dovi_tool (fixtures).

**Spec:** `design/specs/2026-11-17-player-apple-hdr-output-design.md`. It builds on spec 1, `design/specs/2026-11-17-player-hdr-foundation-design.md`.

## Global Constraints

- Prerequisite: spec 1's implementation is merged before Tasks 9, 10 and 11 start. They edit spec 1's texture tone-mapping options, its macOS capability claims and its stats HDR row. Tasks 1 to 8 do not depend on spec 1.
- macOS only. iOS, Android, Windows, Linux and web keep media_kit's stock libraries and the `Video` widget, byte for byte.
- Fork: `getmydia/libmpv-darwin-build`, variant `video-hdr`, target `macos-universal` only, tags `v<upstream>-mydia.<n>` (first: `v0.7.3-mydia.1`).
- Vulkan: MoltenVK linked directly. No Vulkan loader, no ICD manifest, no `VK_ICD_FILENAMES`.
- Licensing: LGPL as `video-default`. No GPL component.
- Attach order: `wid`, `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=macvk`, `target-colorspace-hint=yes`, `hwdec=videotoolbox`, quality options, then `vid=auto` last.
- Quality options restored on attach, to mpv defaults: `scale=lanczos`, `dscale=hermite`, `dither=fruit`, `correct-downscaling=yes`, `linear-downscaling=yes`, `sigmoid-upscaling=yes`, `hdr-compute-peak=auto`.
- No mpv call from the main thread in `MpvSurfacePlugin`. Every write runs on its serial queue `dev.mydia.mpv-surface`.
- Timeouts: video output start check 2 s after `vid=auto`; detach gives up after 3 s and logs.
- Fit/fill: `panscan=0.0` for fit, `panscan=1.0` for fill.
- Escape hatch setting key `legacy_mac_video_output` (bool, default false). Recorded-failure key `mac_surface_failed_version` (the app version string).
- `dolby_vision` is claimed on macOS only when `macDolbyVisionVerified` is true. It ships false and Task 12 flips it.
- No real titles in fixtures, tests or code. Fixtures are generated, never committed.
- No em dashes in docs or comments. Commits use the author email `arsfeld@gmail.com`.
- macOS builds and XCTests run on the MacBook Air (`alexandres-macbook-air-1.bat-boa.ts.net`, has Xcode). The MacBook Pro (`alexandres-macbook-pro.bat-boa.ts.net`) has no Xcode: it runs built apps and the XDR checks only.

## Review Focus

1. **Closing the player while mpv is still creating its output** (close within 200 ms of opening): no hang and no crash, because the plugin serializes detach behind attach on its queue. Owned by Task 4: test `detachQueuedBehindAttachWaitsForIt`.
2. **Moving to the next episode** (one `Player` disposed, a new one created, same screen): the old surface detaches before its player is disposed, and the new surface attaches to the new handle, never the old one. Owned by Task 8: test `nextSourceDetachesOldHandleBeforeAttachingNew`.
3. **A Mac where gpu-next never starts** (no Metal device, broken MoltenVK): playback continues on the texture path in the same session, and later sessions skip the surface until the app version changes. Owned by Task 8: tests `surfaceStartFailureFallsBackToTexture` and `recordedFailureForOtherVersionIsIgnored`.
4. **The hatch flipped while a video plays**: the running playback keeps its path. The next playback uses the new one. Owned by Task 8: test `pathIsFixedPerPlayback`.
5. **A file with no video track** (audio-only): no 2 s failure is reported and no fallback is recorded. Owned by Task 8: test `audioOnlySourceNeverReportsSurfaceFailure`.

---

### Task 1: Calibrated HDR fixture generator

**Files:**
- Create: `scripts/generate-hdr-fixtures.sh`
- Modify: `.gitignore` (add `test/fixtures/hdr/`)

**Interfaces:**
- Produces: `scripts/generate-hdr-fixtures.sh <outdir>` writes `levels_hdr10.mp4`, `levels_hlg.mp4`, `levels_dv81.mp4` and `sdr_testsrc.mp4`. Used by Task 3's smoke test, Task 12's manual pass, and spec 1's integration test.

- [ ] **Step 1: Write the script** with `set -euo pipefail`. HDR10 clip:
  - `testsrc2` at 1920x1080, 24 fps, 12 s;
  - `zscale` from bt709 into PQ / bt2020 with `npl=203`, so SDR white sits at 203 nits;
  - `geq` patches at 10-bit limited luma 573, 722 and 855, giving 203, 1,000 and 4,000 nits, at x 240, 760 and 1280 (400x300 each, y 140);
  - x265 `hdr10=1`, master-display `L(40000000,1)`, `max-cll=4000,203`.

  The HLG clip uses the same chain with `t=arib-std-b67` and no patches (HLG has no absolute nits). The DV 8.1 clip:
  - `dovi_tool generate` with profile 8.1 and L1 `max_pq=3079`;
  - `dovi_tool inject-rpu` into the HDR10 stream;
  - muxed with tag `dvh1`.

  `dovi_tool` and `ffmpeg` come from `nix shell nixpkgs#dovi-tool nixpkgs#ffmpeg-full` when they are not on `PATH`.
- [ ] **Step 2: Run it.** `scripts/generate-hdr-fixtures.sh /tmp/hdrfx`. Expected:
  - `ffprobe` reports `smpte2084` for `levels_hdr10` and `levels_dv81`, and `arib-std-b67` for `levels_hlg`;
  - for `levels_dv81`, `ffprobe -show_frames -read_intervals %+#1` lists `Dolby Vision RPU Data` side data.
- [ ] **Step 3: Commit.** `test(player): generate calibrated HDR fixtures`.

### Task 2: Fork the builder and add the `video-hdr` variant

Work happens in the new fork repo, not in mydia. Creating the fork is an outward action: confirm with the user before running `gh repo fork`.

**Files (fork repo `getmydia/libmpv-darwin-build`):**
- Create: `nix/packages/mk-pkg-libplacebo/{default.nix,targets.nix}`
- Create: `nix/packages/mk-pkg-shaderc/{default.nix,targets.nix}`
- Create: `nix/packages/mk-pkg-moltenvk/{default.nix,targets.nix}`
- Modify: `nix/packages/mk-pkg-mpv/default.nix` (the variant gets `-Dvulkan=enabled -Dlibplacebo=enabled`, links MoltenVK directly)
- Modify: the variant lists in `nix/packages/*/targets.nix` and `Makefile` to add `video-hdr`, macOS universal only
- Modify: `.github/workflows/ci.yaml` (build `video-hdr`)
- Modify: `nix/packages/mk-out-frameworks` (new frameworks `Placebo`, `Shaderc`, `MoltenVK`)

**Interfaces:**
- Produces: release asset `libmpv-xcframeworks_<tag>_macos-universal-video-hdr.tar.gz` holding today's `video-default` frameworks plus `Placebo.xcframework`, `Shaderc.xcframework`, `MoltenVK.xcframework`. The layout matches `video-default`, so media_kit's `create_framework_symlinks.sh` works on it unchanged.

- [ ] **Step 1:** `gh repo fork media-kit/libmpv-darwin-build --org getmydia --clone` (after the user confirms). Branch `mydia/video-hdr` from tag `v0.7.3`.
- [ ] **Step 2:** Add the three `mk-pkg-*` packages, following `mk-pkg-libass` as the template. Pin the versions to libplacebo `v7.387.0`, MoltenVK `v1.4.2` and the shaderc release libplacebo 7.387 names. Build each with `nix develop -c make` on a Mac with Nix and Xcode. Expected: each package's output has its `.a` for arm64 and x86_64.
- [ ] **Step 3:** Wire the `video-hdr` variant into mpv's build. Expected: `nix develop -c make VERSION=v0.7.3-mydia.0` produces the `video-hdr` tarball.
- [ ] **Step 4:** Verify the result. `otool -L Mpv.framework/Mpv` lists no `libvulkan`. `nm` shows `vkCreateMetalSurfaceEXT` resolved from MoltenVK. The `mpv_client_api_version()` probe in Task 3's smoke test links.
- [ ] **Step 5:** Commit in the fork: `feat: add video-hdr variant with libplacebo, shaderc and MoltenVK`.

### Task 3: The `wid` patch, the smoke probe, the first release

**Files (fork repo):**
- Create: `patches/mpv-mac-wid-embed.patch` (the spike's patch: `video/out/mac_common.swift`, `video/out/vulkan/context_mac.m`, as described in spec section 1 "The patch")
- Create: `smoke/probe.swift`, `smoke/run.sh`
- Create: `smoke/make-levels.sh` (Task 1's script, copied into the fork; the probe plays its `levels_hdr10.mp4`)
- Modify: `nix/packages/mk-pkg-mpv/default.nix` (apply the patch for `video-hdr` only)
- Modify: `.github/workflows/ci.yaml` (run `smoke/run.sh` before publishing)

**Interfaces:**
- Consumes: the Task 2 variant, Task 1's fixture script.
- Produces: release `v0.7.3-mydia.1` with the `video-hdr` tarball and its sha256 in the release notes. Task 4 consumes it.

The probe must use the runtime order the player will use. That settles the spec's open question about setting `wid` at runtime.

- [ ] **Step 1: Write the probe.** It mirrors media_kit's sequence:
  1. Create the mpv handle with `vid=no`, then call `mpv_initialize`.
  2. Create an `NSWindow` with a host `NSView`.
  3. On a background queue, set the Global Constraints attach order with `wid` = the host view pointer, then `loadfile levels.mp4`.

  After 5 s it asserts:
  - `current-vo == "gpu-next"`;
  - `video-target-params/gamma == "pq"`;
  - exactly one on-screen window for the process (`CGWindowListCopyWindowInfo`);
  - the host view has a descendant `CAMetalLayer` with `wantsExtendedDynamicRangeContent == true`.

  Then, on the background queue:
  - set `vid=no`;
  - poll until `current-vo` is empty, failing if that takes more than 3 s;
  - call `mpv_terminate_destroy`.

  Exit 0 on success, 1 with a message on any failed assertion.
- [ ] **Step 2: Run it against an unpatched build.** Expected: FAIL on "exactly one on-screen window" (mpv opens its own).
- [ ] **Step 3: Add the patch to the `video-hdr` mpv build and rebuild.**
- [ ] **Step 4: Run the probe again.** Expected: PASS. If `current-vo` stays empty, mpv did not pick up a runtime `wid`. In that case, change the patch to read `option.vo.WinID` inside `MacCommon.config` on every call rather than caching it, rebuild, and re-run.
- [ ] **Step 5: Run the probe in CI.** On the GitHub `macos-14` arm64 runner, set `continue-on-error: false`. If the runner lacks a usable Metal device (the probe reports `current-vo` empty with a `VK_ERROR` in the log), switch the CI step to an artifact-only build and record that in the fork's README as a manual release step: "run `smoke/run.sh` on a Mac before tagging".
- [ ] **Step 6: Tag and publish `v0.7.3-mydia.1`.** Record the tarball's sha256. Commit: `feat: embed mpv's mac output in a host NSView via --wid`.

### Task 4: Swap in the `video-hdr` libmpv on macOS

**Files:**
- Create: `player/packages/media_kit_libs_macos_video_hdr/{pubspec.yaml,macos/Makefile,macos/media_kit_libs_macos_video_hdr.podspec,macos/create_framework_symlinks.sh,macos/Classes/MediaKitLibsMacosVideoPlugin.swift,README.md}`
- Modify: `player/pubspec.yaml` (`dependency_overrides: media_kit_libs_macos_video: {path: packages/media_kit_libs_macos_video_hdr}`)

**Interfaces:**
- Consumes: Task 3's release URL and sha256.
- Produces: macOS builds link the `video-hdr` frameworks. The package keeps the name `media_kit_libs_macos_video`, so the override resolves; only its directory name differs.

- [ ] **Step 1: Create the package.** Copy `media_kit_libs_macos_video` 1.1.4's macOS files. Set `MPV_XCFRAMEWORKS_VERSION=v0.7.3-mydia.1`, the download URL to the fork's release, and `MPV_XCFRAMEWORKS_SHA256SUM` to Task 3's hash. The README says where the frameworks come from and how to bump the version: a new tag, then update both values.
- [ ] **Step 2: Build.** `flutter pub get && flutter build macos --debug` on the Air. Expected: success, and `Contents/Frameworks` contains `Placebo.framework` and `MoltenVK.framework`.
- [ ] **Step 3: Check nothing changed for the texture path.** Play `sdr_testsrc.mp4` and `levels_hdr10.mp4` in the built app. Expected: both play as before. Nothing uses gpu-next yet.
- [ ] **Step 4: Run the existing suite.** `flutter test` in `player/`. Expected: all pass. The override is macOS-native only.
- [ ] **Step 5: Commit.** `build(player): ship the video-hdr libmpv on macOS`.

### Task 5: Path choice and its settings

**Files:**
- Create: `player/lib/core/player/mac_video_output.dart`
- Modify: `player/lib/core/settings/settings_service.dart` (keys `legacy_mac_video_output`, `mac_surface_failed_version`)
- Modify: `player/lib/presentation/screens/settings/diagnostics_screen.dart` (`_PlaybackSection`: a macOS-only switch "Use the legacy video output", and a line showing the active output)
- Modify: `player/lib/l10n/app_en.arb` (+ `@` descriptions)
- Test: `player/test/core/player/mac_video_output_test.dart`, `player/test/core/settings/settings_service_mac_video_output_test.dart`

**Interfaces:**
- Produces:
  - `enum VideoOutputPath { texture, surface }`
  - `VideoOutputPath chooseVideoOutputPath({required TargetPlatform platform, required bool isWeb, required bool legacyHatch, required String? failedVersion, required String appVersion})`
  - `SettingsService.getLegacyMacVideoOutput() -> Future<bool>`, `setLegacyMacVideoOutput(bool)`
  - `SettingsService.getMacSurfaceFailedVersion() -> Future<String?>`, `setMacSurfaceFailedVersion(String)`

- [ ] **Step 1: Write the failing tests.**
  - `chooseVideoOutputPath` returns `surface` only for macOS, not web, hatch off, and `failedVersion != appVersion`. Cover each of the four conditions flipping it to `texture`.
  - `recordedFailureForOtherVersionIsIgnored`: failed `1.4.0` with app `1.5.0` gives `surface`.
  - Settings round-trip each key and default to `false` and `null`.
- [ ] **Step 2: Run.** `flutter test test/core/player/mac_video_output_test.dart test/core/settings/settings_service_mac_video_output_test.dart`. Expected: FAIL, undefined names.
- [ ] **Step 3: Implement** the function and the settings methods, following the `stats_overlay_enabled` pattern. Add the diagnostics switch, shown only when `defaultTargetPlatform == TargetPlatform.macOS && !kIsWeb`, with its label from l10n. The status line reads "Video output: gpu-next" or "Video output: texture" plus "(fallback recorded)" when the failed version matches.
- [ ] **Step 4: Run** the tests above, plus `test/presentation/screens/settings/diagnostics_screen_test.dart` and `test/l10n/arb_consistency_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(player): choose the macOS video output path`.

### Task 6: `MpvSurfacePlugin` (Swift)

**Files:**
- Create: `player/macos/Runner/MpvSurface/MpvApi.swift` (protocol + live implementation over the libmpv C API)
- Create: `player/macos/Runner/MpvSurface/MpvHostView.swift`
- Create: `player/macos/Runner/MpvSurface/MpvSurfacePlugin.swift`
- Modify: `player/macos/Runner/MainFlutterWindow.swift` (register the plugin with `flutterViewController`, held strongly like `nativeTabBar`)
- Modify: `player/macos/Runner.xcodeproj/project.pbxproj` (add the files; link `Mpv.framework` headers via the pod's module)
- Test: `player/macos/RunnerTests/MpvSurfacePluginTests.swift`

**Interfaces:**
- Produces, on method channel `mydia/mpv-surface`:
  - `attach({handle: int, viewId: int, options: List<[String, String]>}) -> {started: bool}`. It applies `wid` first (the host view pointer), then each option in order, then `vid=auto`. It resolves `started` after polling `current-vo` for up to 2 s, but only when `track-list` has a video track. With no video track it resolves `started: true` immediately.
  - `setOption({handle: int, name: String, value: String}) -> null`
  - `detach({handle: int}) -> null`. Sets `vid=no` and waits for `current-vo` to be empty, up to 3 s. Logs on timeout.
- Produces, on event channel `mydia/mpv-surface/display`: `{edrHeadroom: double, potentialHeadroom: double, screenName: String}`, sent on the host window's screen change and on `NSApplication.didChangeScreenParametersNotification`.
- Produces, on platform view factory id `mydia/mpv-surface`: an `MpvHostView`, creation args `{}`.
- `protocol MpvApi { func setOption(_ h: OpaquePointer, _ k: String, _ v: String) -> Int32; func getString(_ h: OpaquePointer, _ k: String) -> String? }`

- [ ] **Step 1: Write the failing XCTests** with a `FakeMpvApi` that records `(name, value, Thread.isMainThread)`:
  - `attachSetsWidFirstAndVidAutoLast`
  - `attachNeverCallsMpvOnMainThread`
  - `detachWaitsForCurrentVoToClear`: the fake reports `gpu-next` for 3 polls, then empty, and detach completes after that.
  - `detachGivesUpAfterThreeSeconds`: uses an injected clock.
  - `detachQueuedBehindAttachWaitsForIt`: attach is still polling when detach arrives, and the order seen is attach writes, then `vid=no`.
  - `viewLeavingWindowDetaches`: `viewWillMove(toWindow: nil)` triggers detach for the attached handle.
  - `noVideoTrackStartsImmediately`
- [ ] **Step 2: Run.** `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -only-testing:RunnerTests/MpvSurfacePluginTests` on the Air. Expected: FAIL, types missing.
- [ ] **Step 3: Implement.**
  - The serial queue is `DispatchQueue(label: "dev.mydia.mpv-surface")`.
  - The polls sleep on the queue (50 ms step), never on main.
  - Replies to Flutter hop to main.
  - The host view pointer is taken on main when attach is received, before dispatching to the queue.
  - `MpvHostView`: `wantsLayer = true`, black `layer.backgroundColor`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(player): mpv surface plugin for macOS`.

### Task 7: Chrome without `VideoState`, and Flutter text subtitles

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/custom_video_controls.dart`
- Create: `player/lib/presentation/widgets/video_surface/mydia_subtitle_view.dart`
- Create: `player/lib/presentation/widgets/video_surface/surface_subtitle_lift.dart`
- Test: `player/test/presentation/widgets/video_surface/mydia_subtitle_view_test.dart`, `player/test/presentation/widgets/video_surface/surface_subtitle_lift_test.dart`, `player/test/presentation/widgets/video_controls/custom_video_controls_adapter_test.dart`

**Interfaces:**
- Produces:
  - `Widget Function(Player player, SubtitleLift lift) playbackChromeBuilder({...same named params as today...})`
  - `Widget Function(VideoState) customVideoControlsBuilderWithCallback({...})`, kept as `(state) => playbackChromeBuilder(...)(state.widget.controller.player, VideoStateSubtitleLift(state))`
  - `class MydiaSubtitleView extends StatefulWidget { MydiaSubtitleView({required Player player, required SubtitleViewConfiguration configuration, MydiaSubtitleViewController? controller}) }`
  - `class MydiaSubtitleViewController { void setPadding(EdgeInsets padding, {required Duration duration}); }`
  - `class SurfaceSubtitleLift implements SubtitleLift { SurfaceSubtitleLift({required Player player, required MydiaSubtitleViewController subtitles, required Size Function() box}); }` with value equality on `(player, subtitles)`.

- [ ] **Step 1: Write the failing tests.**
  - The adapter builds the same `PlaybackChrome` with `player` taken from the state.
  - `MydiaSubtitleView` shows the lines from a faked `player.stream.subtitle`, joined by newlines, and nothing for `['', '']`.
  - `setPadding` animates the bottom padding over `duration`.
  - `SurfaceSubtitleLift.apply(bottom: 80, ...)` calls `setPadding(EdgeInsets.fromLTRB(16, 0, 16, 80))` and `applySubtitlePosition` with `subPosForLift(...)` for the given box and video size.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The builder split is mechanical: the body moves into `playbackChromeBuilder`.
  - `MydiaSubtitleView` follows media_kit_video 2.0.1's `SubtitleView` (text style, `textScaler`, `AnimatedPadding`), but reads only `player.state.subtitle` and `player.stream.subtitle`.
  - `SurfaceSubtitleLift` mirrors `VideoStateSubtitleLift`.
- [ ] **Step 4: Run** them, plus `test/presentation/widgets/video_controls/`. Expected: PASS.
- [ ] **Step 5: Commit.** `refactor(player): build playback chrome from a Player and a SubtitleLift`.

### Task 8: `PlayerVideoSurface` and the player screen on macOS

**Files:**
- Create: `player/lib/core/player/mpv_surface_channel.dart` (Dart client of Task 6's channels, with an abstract `MpvSurface` interface)
- Create: `player/lib/core/player/surface_attach_options.dart`
- Create: `player/lib/presentation/widgets/video_surface/player_video_surface.dart`
- Modify: `player/lib/presentation/screens/player/player_screen.dart` (`_openPlayerAndStart` near the `VideoController(` at ~2957; `_disposePlayer` ~5382; supersede path ~5787; `_buildBody` ~5892; fit/fill handling around `_scaling` ~1140 and ~5952)
- Modify: `player/lib/core/player/video_output_config.dart` (doc comment: macOS on the surface path does not use it)
- Test: `player/test/core/player/surface_attach_options_test.dart`, `player/test/presentation/screens/player/player_screen_mac_surface_test.dart`

**Interfaces:**
- Consumes: `chooseVideoOutputPath` and settings (Task 5); channel contract (Task 6); `playbackChromeBuilder`, `MydiaSubtitleView`, `SurfaceSubtitleLift` (Task 7).
- Produces:
  - `List<(String, String)> surfaceAttachOptions()`: the Global Constraints order after `wid`, ending with the quality options, excluding `vid`.
  - `abstract interface class MpvSurface { Future<bool> attach(int handle, int viewId); Future<void> setOption(int handle, String name, String value); Future<void> detach(int handle); Stream<DisplayInfo> get display; }`
  - `class DisplayInfo { final double edrHeadroom; final double potentialHeadroom; final String screenName; }`
  - `String panscanFor(VideoScaling s)`: `'0.0'` for fit, `'1.0'` for fill.
  - The screen accepts an injectable `MpvSurface? surface` and `VideoOutputPath Function()? outputPath` for tests, like `createPlayer`.

- [ ] **Step 1: Write the failing tests.**
  - `surfaceAttachOptions()` equals the exact Global Constraints list in order.
  - `panscanFor` mapping.
  - Screen tests with a fake `Player`, a fake `MpvSurface` and the path forced to `surface`:
    - no `VideoController` is constructed;
    - attach happens before `open`;
    - `nextSourceDetachesOldHandleBeforeAttachingNew`;
    - dispose calls `detach` before `player.dispose()`;
    - `surfaceStartFailureFallsBackToTexture`: attach returns false, then the screen rebuilds with `Video`, records the app version via `setMacSurfaceFailedVersion`, and the Why row value is set;
    - `audioOnlySourceNeverReportsSurfaceFailure`: attach returns true for a source with no video, and nothing is recorded;
    - `pathIsFixedPerPlayback`: flipping the hatch mid-playback does not rebuild the surface;
    - toggling fit and fill calls `setOption(handle, 'panscan', ...)`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `PlayerVideoSurface` is a `Stack`:
    - `AppKitView(viewType: 'mydia/mpv-surface', onPlatformViewCreated: ...)`;
    - `MydiaSubtitleView` with `subtitleViewConfigurationFor(constraints.biggest, subtitleSize)`;
    - the chrome from `playbackChromeBuilder`.
  - The screen resolves the path once per `_openPlayerAndStart` and stores it.
  - It awaits the platform view id (a `Completer<int>` completed by `onPlatformViewCreated`) before attach.
  - The fallback recreates the playback on the texture path without re-resolving the source.
  - Add a `StatsWhyKind` value `macSurfaceFallback`, with l10n text "Using the standard video output: the HDR renderer could not start on this Mac".
- [ ] **Step 4: Run** them, plus all of `test/presentation/screens/player/`. Expected: PASS.
- [ ] **Step 5: Manual check on the Air.** `flutter run -d macos`:
  - `levels_hdr10.mp4` plays in EDR, with patches brighter than the chrome's white;
  - text and bitmap subtitles both show and lift with the chrome;
  - fill crops;
  - fullscreen works;
  - closing mid-playback does not hang;
  - the next episode plays;
  - with the hatch on, a new playback uses the texture path.
- [ ] **Step 6: Commit.** `feat(player): play through mpv gpu-next in a platform view on macOS`.

### Task 9: Keep spec 1's texture options off the surface path

**Files:**
- Modify: the function spec 1 adds next to `videoControllerConfigurationFor` in `player/lib/core/player/video_output_config.dart` that sets `tone-mapping`, `hdr-compute-peak` and `target-trc` (named in spec 1's plan)
- Modify: its call site in `player_screen.dart`
- Test: that function's existing test file

**Interfaces:**
- Consumes: `VideoOutputPath` (Task 5).

- [ ] **Step 1: Write the failing test.** For `VideoOutputPath.surface`, the texture tone-mapping options are not applied. For `texture` on macOS (the hatch), they are.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement.** Pass the path in and skip the options for `surface`.
- [ ] **Step 4: Run it.** Expected: PASS.
- [ ] **Step 5: Commit.** `fix(player): leave tone mapping to libplacebo on the macOS surface`.

### Task 10: macOS capability claims

**Files:**
- Modify: spec 1's macOS branch of the native device profile builder (`player/lib/core/player/device_profile_native.dart` or the per-platform builder spec 1 introduced)
- Create: `player/lib/core/player/mac_hdr_claims.dart`
- Test: `player/test/core/player/mac_hdr_claims_test.dart`

**Interfaces:**
- Consumes: `VideoOutputPath` (Task 5), spec 1's token vocabulary (`dolby_vision`, `hdr10+`, `hdr10`, `hlg`).
- Produces:
  - `const bool macDolbyVisionVerified = false;`
  - `List<String> macHdrFormats(VideoOutputPath path, {bool dolbyVisionVerified = macDolbyVisionVerified})`

- [ ] **Step 1: Write the failing tests.**
  - `surface` with verified false gives `['hdr10+', 'hdr10', 'hlg']`;
  - `surface` with verified true gives `['dolby_vision', 'hdr10+', 'hdr10', 'hlg']`;
  - `texture` gives spec 1's native list exactly;
  - the profile builder on macOS uses `macHdrFormats` with the path from `chooseVideoOutputPath`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** The profile builder reads the hatch and the failed-version settings to compute the path, the same way the screen does.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(player): claim HDR formats from the macOS output path`.

### Task 11: Stats HDR row on macOS

**Files:**
- Modify: spec 1's HDR row code in `player/lib/core/playback/stats/` and `player/lib/presentation/screens/player/stats_context_builder.dart`
- Modify: `player/lib/l10n/formatters.dart`, `player/lib/l10n/app_en.arb`
- Test: `player/test/core/playback/stats/stats_report_test.dart`, `player/test/l10n/formatters_test.dart`

**Interfaces:**
- Consumes: `DisplayInfo` (Task 8), mpv's `video-target-params/gamma` and `video-params/colormatrix` via `NativePlayer.getProperty`.
- Produces: a stats value `StatsHdrOutputValue({required String transfer, required double headroom})` for the EDR case, and spec 1's "tonemapped by player" value carrying `(libplacebo)` on the surface path.

- [ ] **Step 1: Write the failing tests.**
  - Gamma `pq` with headroom 13.8 reads `HDR output, PQ, headroom 13.8x`.
  - Gamma `hlg` with headroom 1.5 reads `HDR output, HLG, headroom 1.5x`.
  - Headroom 1.0, or gamma `srgb`, reads `tonemapped by player (libplacebo)`.
  - Colormatrix `dolbyvision` appends `RPU applied` to the source label.
  - The clipboard text matches the panel text in English.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** Headroom is formatted to one decimal with `NumberFormat('0.0', localeName)`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(player): show HDR output and headroom in stats on macOS`.

### Task 12: Manual release pass, Dolby Vision profile 5, docs

**Files:**
- Modify: `player/lib/core/player/mac_hdr_claims.dart` (`macDolbyVisionVerified = true`, only if Step 2 passes)
- Modify: `player/docs/playback.md` (a "macOS video output" section: the surface path, the hatch, the fallback, the libmpv fork and how to bump it, and the main-thread rule)
- Modify: `design/specs/2026-11-17-player-hdr-foundation-design.md` if still unmerged; otherwise note in the PR that spec 1's fixtures are superseded by `scripts/generate-hdr-fixtures.sh`

- [ ] **Step 1: Run the manual matrix from the spec.** Build a release app on the Air and copy it to the MacBook Pro, which has no Xcode.
  - **Machines:** the MacBook Pro XDR screen, the Air screen, and an SDR external (the M34WQ).
  - **Content:**
    - `levels_hdr10` (patches step up on HDR screens);
    - `levels_hlg` and `levels_dv81`;
    - `sdr_testsrc`;
    - a real DV profile 5 file kept locally;
    - bitmap and text subtitles.
  - **Actions:**
    - fill;
    - fullscreen;
    - dragging between screens (the stats headroom updates);
    - closing mid-playback;
    - ten open-and-close cycles;
    - dropped frames at 4K60 read from stats.

  Record the results in the PR description.
- [ ] **Step 2: Check Dolby Vision profile 5** on the MacBook Pro. Expected: no purple or green cast, stats show `RPU applied`. Only then set `macDolbyVisionVerified = true` and update Task 10's test expectations.
- [ ] **Step 3: Measure app size.** Compare `du -sh` of the release `.app` before Task 4 and after. Record the delta in `player/docs/playback.md`.
- [ ] **Step 4: Run** `flutter test` and `flutter analyze` in `player/`, then `./dev mix precommit`. Expected: all pass.
- [ ] **Step 5: Commit.** `docs(player): macOS HDR output, and claim Dolby Vision once verified`.
