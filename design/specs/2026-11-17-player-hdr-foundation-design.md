# HDR foundation: honest capabilities, enforcement and tonemapping

## Why

HDR playback is wrong in three independent ways today.

- The native player claims `hdr10`, `hdr10plus`, `hlg` and `dolby_vision`
  from a static list (`device_profile_native.dart`), whatever the device can
  actually do.
- The server ignores that list. `Mydia.Streaming.Compatibility` skips HDR on
  purpose (see the comment above `codecs_playable?/4`), because the HLS
  transcoder has no tonemapping filter and refusing direct play would only
  trade wrong colors for washed-out ones.
- The player renders mpv into a Flutter texture, which is 8-bit SDR on every
  platform. media_kit uses `vo=gpu`, which tonemaps HDR10 and HLG but cannot
  apply Dolby Vision RPU reshaping, so DV profile 5 plays purple and green.

The end goal is real HDR output on HDR displays, Apple first, then Android,
Windows and Linux. That needs a native rendering surface per platform and is
specified separately. This spec is the part every platform needs first: a
file that cannot be shown in HDR is still shown with correct color, either
tonemapped by the player or tonemapped by the server.

## Roadmap

1. **This spec.** Capability semantics, server enforcement, server
   tonemapping, client tonemapping, visibility.
2. **Apple HDR output.** mpv `vo=gpu-next` through libplacebo and
   Vulkan/MoltenVK in a native view on a CAMetalLayer with EDR, driven by
   `target-colorspace-hint`. Subtitles, OSD, track selection and stats stay in
   mpv. Needs a custom libmpv build for Apple (the media_kit prebuilt is not
   known to carry libplacebo or Vulkan), and starts with a spike: HDR10 and
   DV 8.1 in EDR on a Mac. Chosen over AVPlayer because one mechanism carries
   to the other platforms and the player keeps a single engine.
3. Android, 4. Windows (d3d11 HDR swapchain), 5. Linux (Wayland color
   management). Each reuses what spec 2 proves.

## Goal

- `hdrFormats` in the client's device profile is truthful for every client.
- The server direct-plays or remuxes an HDR file only to a client that plays
  that format with correct color, and otherwise transcodes it with a
  tonemap to SDR.
- The server never forces a transcode it cannot tonemap correctly.
- The viewer can see, in stats for nerds, what HDR format the file carries
  and who tonemapped it.

## Non-goals

- HDR output on any display (specs 2 to 5).
- HDR transcode output. Transcodes stay 8-bit SDR bt709 H.264.
- Dolby Vision on the native player before spec 2.
- The cast receiver profile, which keeps `hdrFormats: []`.

## 1. Capability semantics and server enforcement

### What `hdrFormats` means

A format in `hdrFormats` means the client plays it **with correct color**,
whether it shows true HDR or tonemaps locally. It does not mean the screen is
HDR.

An SDR Mac playing an HDR10 file by direct play and tonemapping in mpv gets a
better picture than a server transcode of the same file, so it must keep
direct playing. Whether the screen is HDR is decided on the device by spec 2
and never crosses the wire.

### Tokens

The vocabulary is `Mydia.Library.Hdr.profile_tokens/1`'s: `dolby_vision`,
`hdr10+`, `hdr10`, `hlg`.

Shipped players send `hdr10plus`. `Mydia.Streaming.DeviceProfile` normalizes
`hdr10plus` to `hdr10+` when it casts the list, for as long as players older
than this change are in circulation. The player stops sending `hdr10plus`.

### Per-client claims

| Client | Claims | Reason |
| --- | --- | --- |
| Native (iOS, macOS, Windows, Linux) | `hdr10+`, `hdr10`, `hlg` | mpv `vo=gpu` tonemaps these. No `dolby_vision` until spec 2, because the RPU is ignored. |
| Android | `hdr10+`, `hdr10`, `hlg`, or nothing | Gated on the verification in section 3. |
| Web | from the browser | `matchMedia('(dynamic-range: high)')` and `MediaCapabilities.decodingInfo` with an HDR `transferFunction`. A browser that answers no for all formats claims nothing. |
| Cast receiver | nothing | Unchanged. |

DV 8.1 and DV 8.4 still direct-play on the native player, because their
tokens include the `hdr10` or `hlg` base and mpv renders the base layer.
DV profile 5 has no base token, so it transcodes.

The claims move into the per-platform builders
(`ios_codec_capabilities.dart`, `android_codec_capabilities.dart`,
`device_profile_web.dart`) rather than the shared static list in
`device_profile_native.dart`, which keeps the native default.

### The server rule

In `Compatibility`, next to the codec checks:

- An SDR file (`Hdr.sdr?/1`) passes.
- An HDR file passes when `Hdr.profile_tokens(file)` and the client's
  `hdr_formats` share at least one member.
- An HDR file that fails transcodes, never remuxes, because remux cannot
  change color.

The rule applies to a format only when the server can tonemap it (section 2).
For a format the server cannot tonemap correctly, behavior is exactly what it
is today: the HDR check passes. A wrong-ish direct play beats a confidently
wrong transcode.

Shipped players keep sending `dolby_vision`, so they keep today's behavior for
every file. Nothing regresses for a player that has not updated.

## 2. Server tonemapping

### Probe

A `Tonemap` capability is probed at boot alongside
`Mydia.Streaming.HardwareAccel.Probe` and held the same way.

- `zscale` and `tonemap` are checked with `ffmpeg -filters`. Both are
  compiled-in CPU filters, so the listing is enough.
- `libplacebo` needs a Vulkan device and `tonemap_vaapi` needs a VA device at
  runtime, so each gets a real one-frame test run. A listing alone lies, the
  same lesson `Probe` documents for `-hwaccels`.

Verified on 2026-11-17: the production image's Alpine 3.24 ffmpeg 8.1.3 lists
`zscale`, `tonemap`, `tonemap_vaapi` and `libplacebo`. Nix's
`ffmpeg_6-headless` lists `zscale` and `tonemap` but not `libplacebo`.

The probe yields the set of HDR kinds the server tonemaps correctly:

- `zscale` and `tonemap` present: HDR10, HDR10+, HLG, and DV with an HDR10 or
  HLG base.
- `libplacebo` passes its test run: additionally DV profile 5.

### Filter selection

In `Mydia.Streaming.HardwareAccel.Args`, which stays pure. Tonemapping applies
only when the source is HDR and the session is a transcode.

- **DV profile 5:** `libplacebo` with `apply_dolbyvision=1`, tonemapping to
  bt709, folded together with the scale. It is the only filter that reads the
  RPU.
- **HDR10, HDR10+, HLG and DV with a base, software tier:** `zscale` to linear
  light, `format=gbrpf32le`, `zscale=p=bt709`, `tonemap=tonemap=hable:desat=0`,
  `zscale=t=bt709:m=bt709:r=tv`, `format=yuv420p`, with the existing
  `height_expression/1` scale folded in. ffmpeg's `tonemap` filter has no
  BT.2390 curve (that lives in libplacebo and `tonemap_opencl`), so `hable`
  is the curve here.
- **HLG** never takes the VAAPI path below: `tonemap_vaapi` is built around
  HDR10 static metadata.
- **VAAPI full hardware:** `tonemap_vaapi=format=nv12:t=bt709:m=bt709:p=bt709`
  after `scale_vaapi`, when its probe passed (Intel iHD). Otherwise an HDR
  session drops to the software tier. Mesa has no VA tonemap, and a hybrid
  download and upload for the CPU tonemap is no faster than software.

Output is always 8-bit SDR bt709 H.264, as today.

### Visibility

The session logs the tonemap path it chose, including the filter. The
player does not need it on the wire: an HDR source in a transcode session is
tonemapped by the server, and in direct play or stream copy by the player, so
the stats row derives who tonemapped from the playback mode it already has.

## 3. Client tonemapping and visibility

### mpv options

Set explicitly on the SDR texture path, next to
`videoControllerConfigurationFor` in `video_output_config.dart`:
`tone-mapping=bt.2390`, `hdr-compute-peak=auto`, `target-trc=srgb`. Today
these are whatever media_kit's libmpv defaults to.

### Android verification gate

Android uses the zero-copy `hwdec=mediacodec`, whose own comment says mpv
leaves it out of `auto-safe` because its colorspace handling is unverified.
An HDR10 frame through a SurfaceTexture may reach mpv as PQ-encoded RGB that
mpv reads as SDR.

The first Android task plays the synthetic HDR10 and HLG clips (see Testing)
on the Chromecast with Google TV and compares against a desktop rendering.

- Correct: Android claims `hdr10+`, `hdr10`, `hlg`.
- Washed out or clipped: Android claims nothing, and the server tonemaps.
  Falling back to `mediacodec-copy` for HDR is ruled out: it is the stutter
  `video_output_config.dart` exists to avoid.

### Stats for nerds

A new HDR row shows:

- the source format, from the media file (`HDR10`, `DV 8.1`, `HLG`), and
- the rendering: `tonemapped by player` or `tonemapped by server`.

## Testing

**Elixir**

- `Compatibility`: an SDR file passes; HDR10 to an `hdr10` client passes;
  HDR10 to a client claiming nothing transcodes and never remuxes; DV 8.1 to an
  `hdr10` client passes; DV 5 to an `hdr10` client transcodes; a legacy
  `hdr10plus` claim matches an HDR10+ file; with no tonemapper, every HDR file
  passes as today; with no libplacebo, DV 5 passes as today.
- `DeviceProfile`: `hdr10plus` normalizes to `hdr10+`.
- `Args`: exact filter strings for each tier and HDR kind, including the drop
  to software for an HDR session on a backend without `tonemap_vaapi`.
- `Tonemap` probe: parsing of `-filters` output and of failed test runs.
- One integration test, tagged like the other ffmpeg tests: transcode the
  synthetic HDR10 clip and assert the output's `color_transfer` is `bt709`.

**Dart**

- Each platform builder's `hdrFormats`.
- The web claim, with `matchMedia` and `MediaCapabilities` faked.
- The stats row's labels.

**Fixtures**

Synthetic only, generated by `scripts/generate-hdr-fixtures.sh` and never
committed. No real titles. Its calibrated clips (`levels_hdr10`, `levels_hlg`,
`levels_dv81`, plus `sdr_testsrc`) place their SDR content at 203 nits. The PQ
clips add fixed patches at 203, 1,000 and 4,000 nits with matching mastering
metadata (HLG has no absolute nits, so no patches), and the Dolby Vision 8.1
clip carries an RPU from `dovi_tool generate`. They replace the
first plan of `testsrc2` clips tagged as PQ, which put most pixels near 10,000
nits and are useless for judging brightness (spec 2,
`2026-11-17-player-apple-hdr-output-design.md`). DV 5 is covered by an
argument-shape test only, because there is no generated profile 5 fixture.

## Risks

- **`libplacebo` on servers without a GPU.** The test run decides. With no
  Vulkan device the filter fails the probe and DV 5 keeps today's behavior.
- **CPU cost of software tonemapping.** `zscale` in float is heavier than plain
  `scale`. HDR transcodes on CPU-only servers will run closer to realtime. The
  plan measures the speed factor on a 1080p and a 2160p synthetic HDR10 clip
  and records it in `lib/mydia/streaming/README.md`.
- **Web claims.** Browsers answer `dynamic-range: high` per display, not per
  window, so a browser on an SDR monitor of a mixed setup may still claim
  HDR10. That is the browser's tonemapping to own, same as for a native app.
