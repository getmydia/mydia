# Slow direct play on old iOS devices, and subtitles lost at fallback

## What happened

An iPad on iOS 15.8.8 (player 0.18.0) resumed a 1080p HEVC episode
(9.6 Mbps MKV, resume at 977 s) on 2026-11-03 at 16:45 UTC. From its uploaded
logs:

| Time | Event |
| --- | --- |
| 04.75 | Plan: `directPlay (directPlayAccepted)`, shape `hvc1.1.4.L120.B0/1080` |
| 06.36 | Source opened |
| 09.82 | `No tracks reported before the cap; continuing` (3 s cap) |
| 09.83 | Subtitle preference applied against the server's list: a GraphQL fetch for an embedded track |
| 13.91 | mpv reports its own track list, including the same embedded English track |
| 15.7 | First frame (`first_frame=11039` from the screen opening) |
| 19.51 | The subtitle fetch returns, 9.7 s later; "Loading subtitle..." was on screen throughout |
| 20.29 | `Subtitle preference applied: English (Full Subtitle) [FLE] via server`; mpv's list goes from 23 to 24 tracks |
| 25.80 | `Falling back to transcode 720p adaptive: decodeTooSlow (26 drops in last 10s)` |
| 29.87 | Transcode verifying; no subtitle restore is logged and no toast is shown |
| 41.25 | The viewer picks English again by hand |

The viewer saw three problems: a slow start, a long "Loading subtitle", and
subtitles silently gone after the switch to transcoding.

## Causes

1. **iOS claims HEVC unconditionally.** `detectDeviceProfile` narrows mpv's
   `decoder-list` only on Android (`android_codec_capabilities.dart`). iOS
   advertises every codec libmpv was built with. An iPad capped at iOS 15.8 has
   an A8 or A8X, neither of which decodes HEVC in hardware, so mpv decoded
   1080p HEVC in software and the device found out only from dropped frames,
   about 20 s in.
2. **The track cap releases an embedded preference to the server.** The
   preference gate (`_awaitingPlayerTracks`) opens when the 3 s cap expires
   even though mpv has not reported any tracks yet. The preference then
   matches the server's list, and fetching an embedded track from the server
   means a server-side extraction from the 1.7 GB source. mpv listed the same
   track 4 s later, at no cost.
3. **A preference-applied subtitle is not carried across a source switch.**
   `_captureSubtitleIntent` carries only the pending or selected track, and
   `subtitleIntentBeforeSwitch` returns null when nothing is selected and the
   viewer did not pick this playback. The preference cannot re-apply on the
   new source either, because `_preferenceAppliedForPlayback` is spent. The
   step that loses the selection is most likely `_syncSelectedSubtitleTrack`
   after the `sub-add`: mpv's list grows a 24th entry for the added file, and
   the sync adopts that entry, or nothing, in place of the server track. The
   absence of the `notCarried` toast rules out the `IntentUnmappable` path, so
   the intent was null. A test pins the exact step before the fix (see
   Testing).

## Design

One PR, three parts.

### 1. Carry a preference-applied subtitle across a switch

- After a server subtitle is added to mpv, a track-list revision keeps the
  selection on the server track. `_syncSelectedSubtitleTrack` prefers a server
  track whose cached media_kit track is the one mpv is showing, and treats the
  mpv entry for a file this playback added as that same server track, never as
  a separate embedded one. The added file's mpv entry is not offered as its
  own row in the subtitle list either.
- When a switch captures no explicit intent and the current selection came
  from the preference, the switch carries the preference: the intent becomes
  "re-apply the preference on the new source", resolved by the same matching
  `_applySubtitlePreference` uses, against the new source's list.
- Whenever a carried choice cannot be applied on the new source, the viewer
  sees the existing `subtitleNoticeNotCarried` toast. A subtitle never
  disappears silently.

### 2. An embedded preference waits for mpv in direct play

- In native direct play, when the preferred track resolves to an **embedded**
  server track and mpv has not yet listed any subtitle tracks, the preference
  keeps waiting past the 3 s cap for mpv's next track-list revision, then
  applies from mpv's own track with no fetch.
- Sidecar (external) tracks are unaffected: they have nothing to wait for and
  apply as soon as the gate opens, as now.
- Backstop: if mpv still has not listed tracks 5 s after the first frame, the
  preference falls back to the server fetch, as it does today. A preference is
  delayed, never dropped.
- Streamed sources (transcode, copy) are unchanged: their subtitles always
  come from the server.

### 3. iOS hardware decode detection

- iOS gains a handler for the existing `dev.mydia.player/codecs` channel,
  registered in `AppDelegate.swift`. A new method `hardwareVideoDecoders`
  returns, for HEVC, VP9 and AV1, whether `VTIsHardwareDecodeSupported`
  reports true. VP9 needs iOS 14 and AV1 needs iOS 17 for their codec
  constants; below that, the codec reports false.
- `detectDeviceProfile`, on iOS only, removes from the mpv-derived
  `videoCodecs` every alias of a codec reported as unsupported (`hevc`,
  `h265`, `h.265`, `hvc1`; `vp9`, `vp09`; `av1`, `av01`). The server then
  transcodes those files from the first second. Decided: no software-decode
  allowance, for the reason `android_codec_capabilities.dart` gives. On weak
  hardware software decoding is stutter, not a rescue. Newer iPhones without
  AV1 hardware (before A17 Pro) will transcode AV1. That is accepted.
- macOS keeps the unconstrained claim: Apple silicon and Intel Macs decode
  these in software without trouble, matching the existing desktop rule.
- A failed or empty probe leaves the claims unconstrained, as the Android
  probe does.
- One log line, `[DeviceProfile] ios hardware decode: hevc=<bool> vp9=<bool>
  av1=<bool>`, so the next uploaded log shows what the device advertised.

## Testing

- **Part 1:** a player-screen widget test reproducing the iPad sequence:
  direct play, the preference applies a server track, mpv publishes a list
  with the added file (one more track), a `decodeTooSlow` fallback, the new
  source's list arrives. It asserts the same server track is selected on the
  transcode and nothing was shown as lost. It is written first and must fail
  on `master`, naming the step that drops the choice. Also: a carried
  preference that matches nothing on the new source shows `notCarried`.
- **Part 2:** a widget test where the cap expires before mpv reports tracks:
  no server subtitle fetch happens, and the preference applies from mpv's
  track when the list arrives. A second test where mpv never reports: the
  server fetch happens after the backstop. A sidecar preference still applies
  at the cap.
- **Part 3:** unit tests for the Dart side with a fake channel: HEVC
  unsupported removes all four HEVC aliases; all supported leaves the profile
  unchanged; a channel error or a missing plugin leaves it unchanged; the
  narrowing does not run on non-iOS platforms. The Swift handler is small
  enough to verify by running the app on a device or simulator and reading
  the log line.

## Out of scope

- Probing hardware decode limits by resolution or bit depth on iOS
  (`VTCopyVideoDecoderCapabilities`-style detail). Binary support is enough
  for the devices that fail today.
- The open/seek cost of resuming deep into a large MKV over p2p (the 37 MB
  initial read before seeking to the cues). Separate investigation if it
  shows up on capable devices.
