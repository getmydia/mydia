# HDR Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HDR files play with correct color on every client: the server
enforces honest `hdrFormats` claims and tonemaps HDR when it transcodes, and
the player claims only what it renders correctly.

**Architecture:** A boot-time `Tonemap` probe records which ffmpeg tonemap
filters work. `Compatibility` uses it to decide when an HDR file must
transcode for a client, and `HardwareAccel.Args` uses it to add the tonemap
filter chain to any HDR encode. The player narrows its `hdrFormats` per
platform and shows an HDR row in stats for nerds.

**Tech Stack:** Elixir/Phoenix, ffmpeg (`zscale`, `tonemap`, `libplacebo`,
`tonemap_vaapi`), Flutter/media_kit (mpv).

**Spec:** `design/specs/2026-11-17-player-hdr-foundation-design.md`

## Global Constraints

- Tokens on the wire: `dolby_vision`, `hdr10+`, `hdr10`, `hlg`, which are
  `Mydia.Library.Hdr.profile_tokens/1`'s. The server accepts the legacy
  `hdr10plus` as `hdr10+`.
- Native player claims `["hdr10+", "hdr10", "hlg"]`. No `dolby_vision`.
- Transcode output stays 8-bit SDR bt709 H.264.
- A format the server cannot tonemap correctly is never forced to transcode.
- Fixtures are synthetic (ffmpeg `testsrc2`). No real movie or TV titles
  anywhere.
- No em dashes in code comments, docs or copy.
- Commit with `git commit -F <msgfile>` from the worktree, one commit per
  step that says so, and check each with `git show --stat`.

## Review Focus

1. **A file with `hdr_format: nil` and `dolby_vision_profile: 5`** (DV 5 has
   no base). `Hdr.sdr?/1` is false, so it must not be treated as SDR.
   Pinned in Task 2.
2. **A transcode of an HDR file requested by an old player that still claims
   everything.** Compatibility passes it, but if the session still encodes
   (bitrate cap, downscale), the encode must tonemap. Tonemapping depends on
   the source and the encode, never on the client. Pinned in Task 4.
3. **An HDR10 file on a VAAPI host without `tonemap_vaapi`** must drop to
   the software tier, not fall back to an untonemapped `scale_vaapi`. Pinned
   in Task 4.
4. **The `HardwareAccel` GenServer not running** (every test, and installs
   that skip it). Tonemapping is reported as unavailable and enforcement is
   off, so the existing streaming tests keep passing unchanged. Pinned in
   Task 3.
5. **A shipped player sending `hdrFormats: ["hdr10", "hdr10plus", "hlg",
   "dolby_vision"]`** must keep direct-playing every file it plays today.
   Pinned in Task 2.

---

### Task 1: `Hdr.from_media_file/1` and `DeviceProfile` token normalization

**Files:**
- Modify: `lib/mydia/library/hdr.ex`
- Modify: `lib/mydia/streaming/candidates.ex:175-196` (use the new function)
- Modify: `lib/mydia/streaming/device_profile.ex` (the `from_map/1` pipeline,
  and the "HDR is parsed but not enforced" moduledoc section)
- Test: `test/mydia/library/hdr_test.exs`,
  `test/mydia/streaming/device_profile_test.exs`

**Interfaces:**
- Produces: `Hdr.from_media_file(MediaFile.t() | nil) :: Hdr.t()`, which
  reads `hdr_format`, `dolby_vision_profile` and `dolby_vision_bl_compat_id`.
  `nil` gives `%Hdr{}`.
- Produces: `DeviceProfile.from_map/1` maps every `"hdr10plus"` entry to
  `"hdr10+"` after downcasing.

- [ ] **Step 1: Write the failing tests.**
  - `from_media_file/1` with `%MediaFile{hdr_format: :hdr10, dolby_vision_profile: 8, dolby_vision_bl_compat_id: 1}`
    returns `%Hdr{base: :hdr10, dv_profile: 8, bl_compat_id: 1}`.
  - `from_media_file(nil) == %Hdr{}`.
  - `DeviceProfile.from_map(%{"hdrFormats" => ["HDR10Plus", "hlg"]})` returns
    `hdr_formats: ["hdr10+", "hlg"]`.
- [ ] **Step 2: Run them.** `./dev mix test test/mydia/library/hdr_test.exs test/mydia/streaming/device_profile_test.exs`
  should FAIL: `from_media_file/1` is undefined, and the list is `["hdr10plus", "hlg"]`.
- [ ] **Step 3: Implement.** Make `candidates.ex` build its `%Hdr{}` through
  `from_media_file/1`. Add a private `normalize_hdr_tokens/1` step after
  `downcase_list(:hdr_formats)`, and keep the comment saying why the alias
  exists (players older than this change).
- [ ] **Step 4: Run the same tests plus `test/mydia/streaming/candidates_test.exs`.** All PASS.
- [ ] **Step 5: Commit.** `feat(streaming): normalize hdr10plus and build Hdr from a media file`

### Task 2: `Tonemap` capability struct and HDR enforcement in `Compatibility`

**Files:**
- Create: `lib/mydia/streaming/tonemap.ex`
- Modify: `lib/mydia/streaming/compatibility.ex`: replace the "HDR is
  deliberately NOT checked" comment, and extend `check_compatibility/2` and
  `conditions_reject?/2`
- Test: `test/mydia/streaming/tonemap_test.exs`,
  `test/mydia/streaming/compatibility_hdr_test.exs`

**Interfaces:**
- Produces: `%Mydia.Streaming.Tonemap{zscale: boolean, libplacebo: boolean, vaapi: boolean}`,
  all defaulting to `false`.
- Produces: `Tonemap.none() :: t()`.
- Produces: `Tonemap.can_tonemap?(t(), Hdr.t()) :: boolean`.
  - SDR gives `true` (nothing to do).
  - DV with no base (profile 5) requires `libplacebo`.
  - Any other HDR requires `zscale or libplacebo`.
- Produces: `Tonemap.current() :: t()`, which reads
  `:persistent_term.get({Mydia.Streaming.Tonemap, :current}, none())`.
  `Tonemap.put_current(t()) :: :ok` writes it. Task 3 calls `put_current`.
- Produces: `Compatibility.check_compatibility(media_file, profile, opts \\ [])`
  with `opts[:tonemap]` defaulting to `Tonemap.current()`. Same for
  `conditions_reject?/3`.
- Produces: `Compatibility.hdr_rejects?(MediaFile.t(), DeviceProfile.t(), Tonemap.t()) :: boolean`.
  It is true only when all of these hold:
  - the file is HDR (`not Hdr.sdr?`),
  - `Tonemap.can_tonemap?` is true for it,
  - `Hdr.profile_tokens(hdr)` and `profile.hdr_formats` share no member.

- [ ] **Step 1: Write the failing tests** (`tonemap_test.exs`).
  - `can_tonemap?(none(), %Hdr{}) == true`.
  - `can_tonemap?(%Tonemap{zscale: true}, %Hdr{base: :hdr10})` is true.
  - The same struct with `%Hdr{dv_profile: 5}` is false.
  - `%Tonemap{libplacebo: true}` with `%Hdr{dv_profile: 5}` is true.
- [ ] **Step 2: Write the failing tests** (`compatibility_hdr_test.exs`). Each
  passes an explicit `tonemap:` opt and never touches persistent_term. Use an
  mp4 HEVC file with a profile allowing mp4/hevc/aac so that only HDR
  decides.

  | file | client `hdr_formats` | tonemap | expect |
  | --- | --- | --- | --- |
  | SDR | `[]` | zscale | `:direct_play` |
  | `base: :hdr10` | `["hdr10"]` | zscale | `:direct_play` |
  | `base: :hdr10` | `[]` | zscale | `:needs_transcoding` |
  | `base: :hdr10` (mkv container) | `[]` | zscale | `:needs_transcoding` (never `:needs_remux`) |
  | DV 8, `base: :hdr10` | `["hdr10"]` | zscale | `:direct_play` |
  | DV 5, `base: nil` | `["hdr10", "hlg"]` | zscale + libplacebo | `:needs_transcoding` |
  | DV 5, `base: nil` | `["hdr10"]` | zscale only | `:direct_play` (cannot tonemap, today's behavior) |
  | `base: :hdr10_plus` | `["hdr10+"]` | zscale | `:direct_play` |
  | `base: :hdr10` | `[]` | `none()` | `:direct_play` |
  | any HDR | shipped-player list `["hdr10","hdr10+","hlg","dolby_vision"]` | zscale + libplacebo | `:direct_play` (Review Focus 5) |

  Also: `conditions_reject?/3` is true for the `base: :hdr10` / `[]` / zscale
  row, so `HLS_COPY` candidates drop out.
- [ ] **Step 3: Run them.** `./dev mix test test/mydia/streaming/tonemap_test.exs test/mydia/streaming/compatibility_hdr_test.exs`
  should FAIL: the module is undefined.
- [ ] **Step 4: Implement.** In `check_compatibility`, `hdr_rejects?` true
  means `:needs_transcoding`, checked before both branches. `conditions_reject?/3`
  ORs it in. The callers in `candidates.ex:111`,
  `stream_controller.ex:320` and `common_types.ex:169` stay on the default
  opt. `Tonemap.current/0` is a `persistent_term` read, which keeps per-file
  GraphQL resolution free of GenServer calls. Say that in the moduledoc.
- [ ] **Step 5: Run the new tests plus `test/mydia/streaming/`.** All PASS,
  and every existing test is unchanged because `Tonemap.current()` is
  `none()` in test.
- [ ] **Step 6: Commit.** `feat(streaming): transcode HDR a client cannot show, when the server can tonemap it`

### Task 3: Tonemap probe at boot

**Files:**
- Create: `lib/mydia/streaming/tonemap/probe.ex`
- Modify: `lib/mydia/streaming/hardware_accel.ex`: add a `tonemap_probe`
  field to `State` (default `&Tonemap.Probe.run/1`), run it in
  `handle_continue(:probe, ...)` after the hardware probe, call
  `Tonemap.put_current/1`, and log the result next to `log_result/1`.
- Test: `test/mydia/streaming/tonemap/probe_test.exs`,
  `test/mydia/streaming/hardware_accel_test.exs`

**Interfaces:**
- Consumes: `Tonemap`, `Tonemap.put_current/1` (Task 2), and
  `Capabilities.device` / `backend`.
- Produces: `Tonemap.Probe.run(keyword) :: Tonemap.t()`.
  - Opts are `device: String.t() | nil` and `vaapi?: boolean`.
  - `runner: (String.t(), [String.t()], timeout -> {:ok, binary} | {:error, term})`
    defaults to `&Mydia.BoundedCommand.run/3`, so tests inject output.
- Produces: `Tonemap.Probe.parse_filters(binary) :: %{zscale: boolean, tonemap: boolean, libplacebo: boolean, tonemap_vaapi: boolean}`.

- [ ] **Step 1: Write the failing tests.**
  - `parse_filters/1` on the four real lines below gives all four `true`, and
    on `""` gives all four `false`:

    ```
     .. libplacebo        N->V       Apply various GPU filters from libplacebo
     .S tonemap           V->V       Conversion to/from different dynamic ranges.
     .. tonemap_vaapi     V->V       VAAPI VPP for tone-mapping
     .S zscale            V->V       Apply resizing, colorspace and bit depth conversion.
    ```

  - `run/1` with a runner that lists all four filters and fails every test
    run gives `%Tonemap{zscale: true, libplacebo: false, vaapi: false}`.
  - `run/1` with a runner that succeeds everything and `vaapi?: true` gives
    all three `true`.
  - `run/1` with `vaapi?: false` never invokes the vaapi test run (assert the
    runner's received args).
  - `zscale` is true only when both `zscale` and `tonemap` are listed.
- [ ] **Step 2: Run them.** They should FAIL: the module is undefined.
- [ ] **Step 3: Implement.** Use the same `@probe_timeout_ms` and
  `executable(:ffmpeg_path, "ffmpeg")` pattern as `HardwareAccel.Probe`.
  The test runs, each against `-f lavfi -i testsrc=size=320x240:duration=0.2:rate=5 -frames:v 1 -f null -`:
  - **libplacebo:** `-init_hw_device vulkan` with `-vf libplacebo=format=yuv420p`.
  - **vaapi:** `-init_hw_device vaapi=hw:<device> -filter_hw_device hw` with
    `-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,format=p010,hwupload,tonemap_vaapi=format=nv12`.

  A failed run logs its stderr at info and leaves that flag false. The
  moduledoc says a filter listing is not proof, citing `HardwareAccel.Probe`.
- [ ] **Step 4: Add a `hardware_accel_test.exs` case.** Start the GenServer
  with stub `probe` and `tonemap_probe` functions and assert
  `Tonemap.current()` after `capabilities/1` returns. Reset with
  `on_exit(fn -> :persistent_term.erase({Mydia.Streaming.Tonemap, :current}) end)`,
  and make the module `async: false` if it is not already (Review Focus 4).
- [ ] **Step 5: Run the tests.** `./dev mix test test/mydia/streaming/tonemap test/mydia/streaming/hardware_accel_test.exs`
  PASS.
- [ ] **Step 6: Check by hand.** Run `./dev up -d` and `./dev logs phoenix`.
  The log shows the tonemap result line. On the dev host (Nix ffmpeg 6) it
  should report zscale true and libplacebo false.
- [ ] **Step 7: Commit.** `feat(streaming): probe which ffmpeg tonemap filters work at boot`

### Task 4: Tonemap filter chains in `HardwareAccel.Args`

**Files:**
- Modify: `lib/mydia/streaming/hardware_accel/args.ex`
- Modify: `lib/mydia/streaming/stream_plan.ex:103-133`: pass
  `hdr: Hdr.from_media_file(media_file)` and
  `tonemap: Keyword.get_lazy(opts, :tonemap, &Tonemap.current/0)` to
  `AccelArgs.build/2`, and add `tonemap` to `%StreamPlan.Video{}`
- Modify: `lib/mydia/streaming/ffmpeg_hls_transcoder.ex`: next to
  `Logger.info("Encoding tier: ...")`, log `Tonemap: <method>` when it is
  not `:none`
- Test: `test/mydia/streaming/ffmpeg_hdr_tonemap_args_test.exs`

**Interfaces:**
- Consumes: `Tonemap.t()`, `Hdr.t()`, `Hdr.from_media_file/1`.
- Produces: `%Args{}` gains `tonemap: :none | :zscale | :libplacebo | :vaapi`.
- Produces: `Args.tonemap_method(Tonemap.t(), Hdr.t(), tier) :: :none | :zscale | :libplacebo | :vaapi`
  (public, for tests). The rules, applied in order:
  - SDR, or `can_tonemap?` false: `:none`.
  - DV with no base: `:libplacebo`.
  - `tier == :full_hardware`, base `:hdr10` or `:hdr10_plus`, and
    `tonemap.vaapi`: `:vaapi`.
  - Otherwise: `:zscale` if `tonemap.zscale`, else `:libplacebo`.
- Tier override: `:zscale` and `:libplacebo` force `tier: :software`, with
  software input and codec args. That is how a hybrid or full-hardware host
  without VA tonemap drops to software (Review Focus 3).

- [ ] **Step 1: Write the failing tests.** Each calls `Args.build/2` with an
  explicit `hdr:`, `tonemap:` and `max_height: 720` and asserts the exact
  `-vf` value. `H` stands for the existing `2*trunc(min(720\,ih)/2)`.
  - SDR, software: unchanged `scale=-2:H` (regression guard).
  - HDR10, software, zscale:
    `scale=-2:H,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p`
  - HLG with `vaapi: true` on full_hardware: still the zscale string, and
    `tier == :software`.
  - HDR10, full_hardware, vaapi:
    `scale_vaapi=w=-2:h=H,tonemap_vaapi=format=nv12:t=bt709:m=bt709:p=bt709`
    with VAAPI input args kept and `tonemap == :vaapi`.
  - HDR10, full_hardware, `vaapi: false`, zscale: software tier, the zscale
    string, and `input == []`.
  - DV 5, libplacebo:
    `input == ["-init_hw_device", "vulkan"]` and
    `-vf libplacebo=w=-2:h=H:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:tonemapping=bt.2390:apply_dolbyvision=1:format=yuv420p`.
  - HDR10 with `Tonemap.none()`: plain `scale=-2:H`, `tonemap == :none`.
  - Review Focus 2: `StreamPlan.for_hls/2` with an HDR10 HEVC file,
    `max_bitrate: 4000`, `capabilities: Capabilities.software("t")` and
    `tonemap: %Tonemap{zscale: true}` gives `plan.video.tonemap == :zscale`.
- [ ] **Step 2: Run them.** `./dev mix test test/mydia/streaming/ffmpeg_hdr_tonemap_args_test.exs`
  should FAIL.
- [ ] **Step 3: Implement.** Thread `hdr` and `tonemap` through
  `build/2`. Filter construction stays in `filter_args`-style private
  functions, so `height_expression/1` is still written once.
- [ ] **Step 4: Run the new test plus `test/mydia/streaming/ffmpeg_*_test.exs` and `hls_session_plan_test.exs`.** All PASS.
- [ ] **Step 5: Commit.** `feat(streaming): tonemap HDR to SDR bt709 when transcoding`

### Task 5: Live ffmpeg check and speed measurement

**Files:**
- Create: `test/support/hdr_fixture.ex` (generates clips into a tmp dir;
  no binary fixtures committed)
- Create: `test/mydia/streaming/ffmpeg_hdr_tonemap_live_test.exs`
- Modify: `lib/mydia/streaming/README.md`: add an HDR section with the
  measured speed factors

**Interfaces:**
- Produces: `Mydia.HdrFixture.hdr10_clip(dir, height) :: Path.t()` and
  `Mydia.HdrFixture.hlg_clip(dir, height) :: Path.t()`. Each is a 2-second
  HEVC 10-bit mkv from `testsrc2`:
  - **HDR10:** `-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc`
    plus x265 `master-display` and `max-cll` params.
  - **HLG:** `-color_trc arib-std-b67`.

  Task 7 reuses the generation commands for the Android check.

- [ ] **Step 1: Write the live test.** Use `@moduletag :requires_ffmpeg` and
  the skip pattern of `ffmpeg_scale_live_test.exs`. It also skips unless
  `ffmpeg -filters` lists zscale. For each clip:
  1. Build args through `FfmpegHlsTranscoder.build_ffmpeg_args/3` with
     `tonemap: %Tonemap{zscale: true}`, then run them.
  2. ffprobe the first segment.
  3. Assert `color_transfer` is `bt709` (or absent and `pix_fmt == "yuv420p"`
     with `color_primaries` not `bt2020`), and a non-empty playlist.
- [ ] **Step 2: Run it.** `./dev mix test test/mydia/streaming/ffmpeg_hdr_tonemap_live_test.exs`
  PASS (not skipped) on the dev host.
- [ ] **Step 3: Measure.** Run the software zscale transcode on 1080p and
  2160p HDR10 clips of 20 s, with `-benchmark`, and record the realtime speed
  factor in the README section, next to plain `scale` for the same clip.
- [ ] **Step 4: Verify the libplacebo string by hand** on any host where the
  probe reports `libplacebo: true`, for example the production image locally
  with `docker run` and `--device /dev/dri`. Run the Task 4 DV 5 filter
  string against the HDR10 clip. If ffmpeg rejects an option, fix the string
  in Task 4's code and test, and note it in the commit. If no host has
  Vulkan, write that in the README section and leave the flag to the probe.
- [ ] **Step 5: Commit.** `test(streaming): run HDR tonemapping through a real ffmpeg, record its cost`

### Task 6: Player HDR claims (native and web) and mpv tonemap options

**Files:**
- Create: `player/lib/core/player/hdr_claims.dart`
- Modify: `player/lib/core/player/device_profile_native.dart:71-78`: drop
  the "naming time bomb" comment and use `nativeHdrFormats`
- Modify: `player/lib/core/player/device_profile_native.dart:106-130`: on
  Android, `profile.copyWith(hdrFormats: androidHdrFormats)` on both return
  paths
- Modify: `player/lib/core/player/device_profile_web.dart`
- Modify: `player/lib/core/player/video_output_config.dart`
- Test: `player/test/core/player/hdr_claims_test.dart`,
  `player/test/core/player/video_output_config_test.dart`

**Interfaces:**
- Produces: `const List<String> nativeHdrFormats = ['hdr10+', 'hdr10', 'hlg'];`
- Produces: `const List<String> androidHdrFormats = [];`, set by Task 7.
- Produces: `List<String> webHdrFormats({required bool highDynamicRange, required bool pq, required bool hlg})`.
  - Returns `[]` unless `highDynamicRange`.
  - Otherwise `pq` adds `hdr10+` and `hdr10`, and `hlg` adds `hlg`.
- Produces: `const Map<String, String> sdrTonemapMpvOptions = {'tone-mapping': 'bt.2390', 'hdr-compute-peak': 'auto', 'target-trc': 'srgb'};`.
  It is applied with `NativePlayer.setProperty` wherever the existing
  per-player native setup sets properties (`audio_language_native.dart`
  shows the pattern), on every non-web platform.

- [ ] **Step 1: Write the failing tests.**
  - `nativeHdrFormats` equals the list above and never contains
    `dolby_vision` or `hdr10plus`.
  - The `webHdrFormats` truth table: all false gives `[]`; HDR true with
    neither curve gives `[]`; `pq` only gives `['hdr10+', 'hdr10']`; both
    give all three.
  - `sdrTonemapMpvOptions` has the three exact pairs.
- [ ] **Step 2: Run them.** `cd player && flutter test test/core/player/hdr_claims_test.dart`
  should FAIL.
- [ ] **Step 3: Implement.** The web glue in `device_profile_web.dart` uses
  `package:web`:
  - `window.matchMedia('(dynamic-range: high)').matches`.
  - `navigator.mediaCapabilities.decodingInfo` for
    `{type: 'media-source', video: {contentType: 'video/mp4; codecs="hvc1.2.4.L153.B0"', width: 3840, height: 2160, bitrate: 20000000, framerate: 24, transferFunction: 'pq' | 'hlg'}}`.
    Any exception means `false`.

  It returns `const DeviceProfile.webDefault().copyWith(hdrFormats: webHdrFormats(...))`.
- [ ] **Step 4: Run `flutter test test/core/player/` and `flutter analyze`.** Both clean.
- [ ] **Step 5: Commit.** `feat(player): claim only the HDR formats each platform renders correctly`

### Task 7: Android HDR verification gate

Manual, on the "Loving Room Chromecast" test device over ADB (see the
reference memory for connecting). No code changes unless the check passes.

- [ ] **Step 1:** Generate 20-second 1080p HDR10 and HLG clips with Task 5's
  commands, and put them in a Files library the player can reach. Pair the
  device's Files source with a local folder, or use the dev server.
- [ ] **Step 2:** Play each clip on the Chromecast with the zero-copy
  default. Take a screenshot with `adb exec-out screencap -p`. Play the same
  clip on the Linux desktop player and screenshot it.
- [ ] **Step 3:** Compare. On correct output, testsrc2's colored bars and
  gradient look like the desktop's, and are not grey and low contrast
  (washed out) or blown to flat white (clipped).
  - **Correct:** set `androidHdrFormats` to `nativeHdrFormats`, update the
    Task 6 test, and write what was seen and on which device in the doc
    comment on `androidHdrFormats`.
  - **Wrong:** leave it `[]` and write the observation in the same doc
    comment.
- [ ] **Step 4: Commit.** Either `feat(player): claim HDR on Android after verifying zero-copy rendering`
  or `docs(player): record why Android claims no HDR`.

### Task 8: HDR row in stats for nerds

**Files:**
- Modify: `player/lib/core/playback/stats/playback_stats.dart`: add
  `StatsContext.hdr` of type `StatsHdr?`
- Modify: `player/lib/core/playback/stats/stats_report.dart`:
  - add `StatsRowId.hdr` after `video`,
  - add a `StatsHdrValue` value class,
  - emit the row after the video row (not hidden in compact),
  - add the copy-text line `HDR: <format>, tonemapped by <player|server>`.
- Modify: `player/lib/presentation/screens/player/stats_context_builder.dart`
  (a new `sourceHdrOf(PlanInputs?)` next to `sourceCodecOf`, and a
  `sourceHdr` parameter on `buildStatsContext`)
- Modify: `player/lib/presentation/screens/player/player_screen.dart:6072-6085`:
  pass `sourceHdr: sourceHdrOf(_planInputs)`
- Modify: `player/lib/l10n/formatters.dart` (row label and value wording),
  `player/lib/l10n/app_en.arb` and the other `app_*.arb` per
  `player/docs/l10n.md`
- Test: `player/test/presentation/screens/player/stats_context_builder_test.dart`,
  and the existing stats report test file

**Interfaces:**
- Produces: `class StatsHdr { final String format; final HdrTonemapper by; }`
  and `enum HdrTonemapper { player, server }`.
  - `format` is the server's display string (`"HDR10"`, `"Dolby Vision"`,
    `"HLG"`, `"HDR10+"`), plus `" $profile"` when a DV profile is known
    (`"Dolby Vision 8"`).
  - `by` is `server` when the mode is `PlaybackMode.transcode`, otherwise
    `player`.
- Produces: `({String format, int? dvProfile})? sourceHdrOf(PlanInputs? inputs)`.
  It reads the selected file's `hdrFormat` and `dolbyVisionProfile` from
  wherever `sourceCodecOf` reads the codec, and returns null for SDR or an
  unknown format.
- New arb keys:
  - `statsRowHdr`: `"HDR"`
  - `statsHdrByPlayer`: `"{format}, tonemapped by player"`
  - `statsHdrByServer`: `"{format}, tonemapped by server"`

- [ ] **Step 1: Write the failing tests.**
  - HDR10 plus `PlaybackMode.direct` gives
    `StatsHdr(format: 'HDR10', by: player)`.
  - Dolby Vision with profile 8 plus transcode gives
    `format: 'Dolby Vision 8', by: server`.
  - An SDR source gives `hdr == null` and no `StatsRowId.hdr` row.
  - The copy text contains `HDR: HDR10, tonemapped by player`.
- [ ] **Step 2: Run them.** `flutter test test/presentation/screens/player/stats_context_builder_test.dart`
  should FAIL.
- [ ] **Step 3: Implement.** Then run `flutter gen-l10n` (or the project's
  equivalent from `player/docs/l10n.md`).
- [ ] **Step 4: Run `flutter test test/presentation/screens/player/ test/core/playback/` and `flutter analyze`.** Both clean.
- [ ] **Step 5: Commit.** `feat(player): show the HDR format and who tonemapped it in stats`

### Task 9: Docs and final verification

**Files:**
- Modify: `lib/mydia/streaming/README.md`: a short "HDR" section.
  - Tokens, and the "plays with correct color" meaning.
  - Enforcement only for tonemappable formats.
  - The probe, and where to see its log line.
- Modify: `player/docs/playback.md`: under "Compatibility", the per-platform
  claims, and the fact that native drops `dolby_vision` until `gpu-next`.

- [ ] **Step 1:** Write both sections.
- [ ] **Step 2:** Run `./dev mix precommit`, in chunks if it outruns the
  Bash timeout (see `test/README.md`), and `cd player && flutter analyze && flutter test`.
  Everything passes.
- [ ] **Step 3:** Run `git diff --stat origin/master...HEAD`. Every file
  listed appears in some task above.
- [ ] **Step 4: Commit.** `docs: describe HDR claims, enforcement and tonemapping`
