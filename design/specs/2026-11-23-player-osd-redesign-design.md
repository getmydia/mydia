# Player: playback OSD redesign

Date: 2026-11-23
Status: approved design, not yet implemented

## Goal

The playback OSD is the one surface #1506 (Frosted restyle) left alone: a
floating frosted card (`ChromePanel`) at the bottom holding volume, transport,
track buttons and the scrubber, plus glass pills along the top. Replace it with
the layout current streamers use: controls float directly over the video on a
gradient scrim, the scrubber runs edge to edge, and a phone gets a large centre
transport.

Background: `design/research/2026-11-22-modern-media-app-ui.md` (floating
translucent playback controls on tvOS 26 and YouTube TV, no live blur on
Android TV or web, gold as a signal, and the Plex lesson that self-hosted users
punish extra presses far more than they reward polish). The visual reference is
the "Playback controls: proposed" artboard on the mockup canvas made alongside
#1506; this spec is the source of truth where they differ.

## Success criteria

- Same controls, same behaviour. Nothing is added or removed from what each
  input tier can do today; only placement and styling change.
- TV press counts and focus order are identical to `master`. Every
  `*_tv_test.dart` passes unchanged under `MYDIA_FORCE_TV=true`.
- The bottom bar never overflows at any width from 320 px up.
- Text and glyphs drawn on the scrim or a pill meet the existing
  `osd_legibility_test` contract over a pure-white frame (4.5:1 text, 3:1
  icon-only), without text shadows.
- `./dev player glass-diff` stays at 0 px (it renders the Liquid Glass lab,
  which this work does not touch).
- The OSD controls (top bar, bottom bar, touch cluster) contain no
  `BackdropFilter`.

## Scope

The OSD material is already identical on every platform: `GlassSurface.osd`
has no Liquid Glass branch, so iOS and macOS draw the same dark card as
Android. The new layout keeps that: one OSD look in both glass modes. The
Liquid `GlassSlider` knob stays on the volume slider, where it is today.

Out of scope, each a possible follow-up:

- Chapter ticks on the scrubber (no chapter data is read today).
- A persistent "Up next" pill (the up-next prompt keeps its near-the-end
  behaviour).
- A picture-in-picture button.
- Asymmetric skip amounts (−10 / +30). Skips stay ±10 s.
- A second title line ("Show · S2 E4"). The OSD title stays the single string
  the player screen passes today.
- The existing touch gap: below the mobile breakpoint there is no touch path
  to the previous episode. Unchanged by this work.

## Layout

```
 [‹ Title of the thing ...............]           [cast | fit]   top bar
                                                                  (scrim)
                     [−10]  [ ▶ ]  [+10]                          touch only
 0:33:12                                             −0:18:04
 ━━━━━━━━━━━━━━━━━━━━━━━━━━━●──────────────                       scrubber
 [vol]            [⏮ −10 ▶ +10 ⏭]          [CC | audio | quality | ⛶]
```

### All tiers

- **Scrim.** `ChromeScrim` sits under every other chrome layer and fades with
  `ChromeVisibility`. Solid OSD fill behind each bar, fading to transparent
  beyond it (profile under Materials). No blur.
- **Top bar.** Back and the title together on the left; the title is
  left-aligned and ellipsizes, and is no longer a centred pill. Cast and
  scaling share one pill on the right. Keys `backKey`, `titleKey`, `castKey`
  keep their names. Placement still goes through `PlayerTopBarSlot` (windowed
  desktop reaches into the window-chrome band).
- **Bottom bar.** `ChromeBottomBar`, full width inside the safe area, 24 px
  horizontal padding (16 px below `Breakpoints.mobile`), no `maxWidth`. From
  top to bottom:
  1. Timecodes: elapsed left, `−remaining` right. They move out of the
     scrubber row, which today draws them either side of the bar. The remote
     tier keeps its larger size (`PlaybackChrome.remoteTimeFontSize`).
  2. The scrubber, full width.
  3. One control row: volume left, transport centre, secondary pill right.
     The two sides keep equal flex so the transport stays optically centred,
     as `ChromePanel` does today.
- **Skip Intro and Up Next** stay bottom-right, just above the bottom bar, at
  `ChromeMetrics.cornerInsetBottom` computed from the bar's real height.
- **Subtitle lift.** `ChromeSubtitleLift` takes its reference box from the
  bottom bar, so captions clear the controls as they do the panel today.
- **Toast obstruction.** `ChromeToastObstruction` wraps the bottom bar as it
  wraps the panel today.

### Touch (`InputCapabilities.touchPrimary`)

- `TouchTransport`, a centre cluster: −10 s, play/pause, +10 s. It replaces
  `CenterPlayButton`.
- The bottom row carries no transport: volume (where `showVolume` allows it
  today) and the secondary pill.
- Double-tap left/right seeking in `gesture_controls.dart` is unchanged.

### Pointer (desktop, web)

- No centre cluster. The bottom row's transport is today's full cluster:
  previous episode, −10 s, play/pause, +10 s, next episode; below
  `Breakpoints.mobile` the compact (play/pause only) variant, as today.
- Double-click fullscreen and window drag on the surface are unchanged.

### Remote (TV, `InputCapabilities.directionalPrimary`)

- Same as pointer, without volume, fullscreen and back. Scaling keeps its slot
  in the secondary pill; the top bar takes no focus.
- Focus wiring is untouched: the `osd-controls` `FocusMemoryRegion` with
  play/pause as its initial id, the scrubber as its own region inside it,
  `_osdPolicy`, the remembered control on UP from the scrubber, and auto-hide
  restarted on key activity.

## Materials

### Shared

- **Scrim profile.** The legibility contract is the panel's today: behind the
  top bar and the bottom bar the scrim is `DepthTokens.osdTint` at
  `DepthTokens.osdFillOpacity` (0.85), the exact fill `osd_legibility_test`
  measures. Beyond each bar it fades to transparent over
  `ChromeScrim.fadeExtent` (96 px). Bare glyphs and text on the scrim are then
  rated exactly as they are on the panel today.
- **Text.** Title 15 / w600; timecodes 12 / w500 (remote tier 18) with
  tabular figures; both `osdTextColors` as today. No text shadows.
- **Scrubber** (`video_progress_bar.dart`). Track 4 px, white 22 %; buffered
  white 42 %; played `palette.accent` (gold, today white). Thumb a 14 px
  white dot (today 12) that grows to 18 px (today 16) while hovered, dragged
  or focused. `ScrubBubble` and its thumbnails are unchanged.
- **Touch cluster.** Play/pause a 68 px white disc (white 95 %) with a dark
  glyph and a soft drop shadow; ±10 s are 48 px discs in the pill material.
- **Icons.** `ControlButton` glyphs sit bare on the scrim or inside group
  pills, no per-button backdrop, as today.
- **Pills** (top-right group, secondary group, back, the ±10 discs): a new
  `GlassSurface.osdPill` constructor with the OSD fill, hairline, pill radius
  and pill shadow, and no blur. The chrome no longer uses `GlassSurface.osd`,
  which removes its live `BackdropFilter` (`DepthTokens.osdBlurSigma`) from
  the controls. `GlassSurface.osd` itself is unchanged: the OSD dialogs and
  sheets (`osd_dialog.dart`, `osd_sheet.dart`), the stats panel and the Up
  Next prompt keep it.
- **TV focus:** the existing offset gold ring and `FocusEmphasis` at the
  control size (1.025). The focused scrubber shows the 18 px thumb.

## Components

All under `player/lib/presentation/widgets/video_controls/`.

| File | Change |
| --- | --- |
| `chrome_bottom_bar.dart` | New. `ChromeBottomBar` with the slots `ChromePanel` has (`transport?`, `volume?`, `secondary`, `scrubber`) plus the timecode row. `ChromeMetrics` (renamed from `PanelMetrics`): drops `maxWidth`, keeps the tier flags (`showVolume`, `touchTargets`, `compactTransport`, `showQuality`, `showAlwaysOnTop`, `secondaryGap`, `horizontalPadding`), adds `barHeight`, and derives `cornerInsetBottom` from it. |
| `chrome_panel.dart` | Deleted. No re-export or alias. |
| `chrome_scrim.dart` | New. `ChromeScrim`, the two-band scrim sized from the top and bottom bar heights. |
| `touch_transport.dart` | New. `TouchTransport`: −10 s, play/pause, +10 s, plus previous and next episode outside them at widths from `Breakpoints.mobile` up (where today's in-bar touch transport shows them), so touch tablets lose nothing. |
| `center_play_button.dart` | Deleted. |
| `player/lib/presentation/widgets/glass_surface.dart` | New `GlassSurface.osdPill` constructor (see Materials). |
| `chrome_top_bar.dart` | Left group (back, title), right pill (cast, scaling). |
| `video_progress_bar.dart` | Track, buffer and thumb styling above. |
| `playback_chrome.dart` | Composes the new parts. `_ScrubberRow` loses the inline timecodes, which move to the bar's timecode row (same stream builders, same styles). Focus wiring, `ChromeVisibility`, `ChromeSlide`, buffering indicator unchanged. |
| `skip_segment_button.dart`, `up_next_prompt.dart` | Read `ChromeMetrics.cornerInsetBottom`. |
| `player/lib/presentation/screens/player/player_screen_views.dart`, `player_screen.dart`, `player/lib/core/playback/stats/stats_metrics.dart` | Same rename (the stats panel keeps reading the corner inset). |
| `player/lib/core/player/input_capabilities.dart` | A `@visibleForTesting` override for `touchPrimary`, so widget tests can select the touch tier. |

`VolumeCluster` keeps its `Visibility(maintainState: true)` slot so
`_lastVolume` survives a breakpoint crossing, as `ChromePanel._volumeSlot`
does today.

## Testing

- **Unchanged and must pass:** every `*_tv_test.dart` with
  `MYDIA_FORCE_TV=true`, in particular `player_osd_focus_tv_test`,
  `playback_chrome_tv_test`, `playback_chrome_scrub_tv_test`,
  `tv_scrubber_test`; plus `chrome_top_bar_test` key lookups and
  `panel_controls_test`.
- **Rewritten for the bar:** `chrome_panel_test`, `chrome_panel_golden_test`,
  `chrome_panel_overflow_test`, `chrome_corner_inset_test` become
  `chrome_bottom_bar_*` tests: no overflow at 320, 599, 600, 899, 900, 1280
  and 1920 px (each side of `Breakpoints.mobile` and `Breakpoints.tablet`);
  transport
  centred on the bar by `tester.getRect`; Skip Intro and Up Next rects clear
  the bar.
- **New:**
  - Touch tier shows `TouchTransport` and no transport in the bottom row;
    pointer and remote tiers show no `TouchTransport`.
  - `ChromeScrim` fades out with the chrome.
  - No `BackdropFilter` under the top bar, bottom bar or touch cluster, in
    either glass mode.
  - The subtitle lift reference is the bottom bar's box.
  - `osd_legibility_test`: the scrim plateau equals the OSD fill, and the
    touch play disc's dark glyph clears 4.5:1 on its white fill (replacing
    the `CenterPlayButton` shadow case).
- **Visual:** a bottom-bar golden replacing the panel golden;
  `./dev player glass-diff` at 0 px.
- **Manual:** Android TV emulator (`./dev player android tv-run`): reveal,
  play/pause, scrub, open audio and subtitles, back out, counting presses
  against `master`. Phone in landscape. Desktop windowed and fullscreen.

## Delivery

One PR, with this spec and its implementation plan
(`design/plans/2026-11-23-player-osd-redesign.md`).
