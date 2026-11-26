# Player: Liquid Glass playback OSD

Date: 2026-11-25
Status: approved design, not yet implemented

## Goal

The playback OSD is the last floating control layer that ignores the Liquid
Glass setting. `docs/liquid-glass.md` says so outright: `GlassSurface.osd` and
`GlassSurface.osdPill` never take the Liquid Glass path, so on iOS and macOS
the player draws the same dark cards and pills as Android while every other
screen is glass. Bring the OSD onto Liquid Glass on iOS and macOS, keeping the
layout from `design/specs/2026-11-23-player-osd-redesign-design.md` unchanged.

Background: `design/research/2026-11-25-liquid-glass-player-controls.md`. The
lessons this design takes from it:

- Glass on discrete controls, not on the scrubber. Infuse shipped a glass seek
  bar and removed it within weeks (moving blur was distracting and hurt
  subtitle legibility); Apple's own player reportedly keeps the seek bar solid.
- Dim under clear glass over video. Apple's HIG suggests a dark dimming layer of
  about 35% and AVKit's controls bring their own. Without it, white glyphs vanish in
  bright scenes, which Infuse users still report.
- Gate by platform with the old look as the fallback (Swiftfin, VLC, CNN).
- Keep the OSD in Flutter's layer stack where possible. Native glass in
  platform views sits above Flutter and bleeds through dialogs and sheets.

## Success criteria

- On iOS, with Liquid Glass on, the OSD pills and panels refract the playing
  video with the lens and panel profiles.
- On macOS, with Liquid Glass on, the OSD reads as the same glass system
  (tint, rim, light, shadow) over the HDR surface, without refraction.
- Every other platform, and either Apple platform with the setting off or
  Reduce Transparency on, renders the OSD exactly as `master` does.
- White labels and glyphs on the OSD meet 4.5:1 and icons 3:1 over the full
  grey sweep (0 to 1) in every glass mode.
- No layout, behaviour, focus order or press count changes. Every existing
  OSD and `*_tv_test.dart` test passes unchanged.
- The full OSD holds 60 fps over 4K HEVC playback on the oldest iPhone we test
  on.

## Non-goals

- Glass on the scrubber track, timecodes or subtitles.
- Morphing or emergence animations between OSD states.
- Native `NSGlassEffectView` / `UIGlassEffect` glass (see "Follow-up spike").
- Liquid Glass OSD on Android, Android TV, Windows, Linux or web, even when the
  setting is turned on there.

## The gate: `OsdGlass`

A new inherited value, provided by the player screen, carries one of three
modes:

| Mode | When | Renders |
| --- | --- | --- |
| `off` | Setting off, platform not iOS/macOS, or Reduce Transparency on | Today's `osd` / `osdPill` recipes |
| `sampled` | iOS; macOS on the texture fallback path | `LiquidGlassFilter` (the shader) |
| `dry` | macOS on `VideoOutputPath.surface` | `DryLiquidGlass` (below) |

`sampled` additionally requires `LiquidGlassSupport.available`; without the
shader, a `sampled` request renders `dry`. The mode follows the playback's
output path, so a macOS surface failure that falls back to the texture
switches the OSD from `dry` to `sampled` for that playback.

Why two modes: on iOS media_kit draws video into a Flutter texture, which a
`BackdropFilter` samples. On macOS the video is mpv's `gpu-next` output in an
`AppKitView` platform view (`docs/playback.md`, "macOS video output"), which
the shader is not expected to see. Flutter still composites its layers over the
platform view with normal alpha, so translucency and the scrim work; only the
backdrop sample is lost.

## Surfaces

| Surface | Today | Liquid Glass |
| --- | --- | --- |
| Top-bar pills (`chrome_top_bar.dart`) | `osdPill` | Lens, control role (tint and adaptive max) |
| Bottom-bar pills (`chrome_bottom_bar.dart`) | `osdPill` | Lens, control role |
| Touch transport skip pills (`touch_transport.dart`) | `osdPill` | Lens, control role |
| Touch transport play disc | Opaque white disc, dark glyph | Lens capsule, white glyph (the `PrimaryPlayButton` treatment) |
| Up next (`up_next_prompt.dart`) | `osd` | Panel, `OsdElevation` shadow kept |
| Skip segment (`skip_segment_button.dart`) | `osd` | Panel |
| Stats panel, `osd_sheet.dart`, `osd_dialog.dart` | `osd` | Panel |
| Volume knob | `GlassSlider` clear knob | Unchanged |
| Scrubber thumb (`video_progress_bar.dart`) | Material thumb | `GlassSlider`-style clear knob |
| Scrubber track, timecodes, subtitles | Solid | Unchanged |

`GlassSurface.osd` and `GlassSurface.osdPill` read `OsdGlass` and choose the
recipe; call sites do not change. Each bar's actions that already sit next to
each other share one capsule rather than one capsule per button, matching
Apple's grouped toolbar and halving the number of backdrop passes.

## The scrim

`ChromeScrim` today has a solid plateau in the OSD fill colour behind each bar.
A glass pill over a flat dark band refracts nothing and disappears. In the
`sampled` and `dry` modes the scrim drops the plateau and becomes a pure
gradient: `DepthTokens.osdLiquidScrimOpacity` (start at 0.35, the HIG's figure)
at the edge, fading to nothing over the band height plus today's
`fadeExtentFor`. The `off` mode keeps today's scrim exactly.

## Dry glass

`DryLiquidGlass` is a sibling of `LiquidGlassFilter` for surfaces whose
backdrop cannot be sampled. It paints, from the same `LiquidGlassProfile`:

- a fixed tint fill (`DepthTokens.osdDryTintOpacity`, set by the legibility
  sweep, not by eye);
- the rim hairline and the top and bottom light;
- the press glow under the pointer (`glass_interaction.dart`);
- the profile shadow.

It pushes no backdrop layer: no blur, no bend, no adaptive tint. It is a
`CustomPainter` behind the child, so it costs no backdrop pass.

## Legibility

`liquid_glass_legibility_test.dart` gains OSD cases, and
`osd_legibility_test.dart` keeps its `off`-mode contract:

- **Sampled.** For each grey from 0 to 1 in steps of 0.05, darken it by the
  scrim's alpha at the lightest point of the gradient a pill overlaps, apply
  the lens or panel profile's brightness lift, then the adaptive curve
  (`liquidAdaptiveAlpha`) with the surface's role: control tokens
  (`liquidControlTintOpacity` / `liquidControlAdaptiveMax`) for pills, modal
  tokens (`liquidModalTintOpacity` / `liquidModalAdaptiveMax`) for panels.
- **Dry.** The same sweep against `osdDryTintOpacity`.
- Thresholds: white labels 4.5:1, icons 3:1.

A failing case is fixed in the scrim or the OSD tint tokens, never by relaxing
a threshold.

## Accessibility

- Reduce Transparency: `off` mode.
- Increase Contrast: the existing visible rim and `liquidHighContrastTintBoost`.
- Reduce Motion: no press swell, as elsewhere.
- `FocusHighlight` rings keep working on glass pills (macOS keyboard, iOS Full
  Keyboard Access).

## Motion

The glass rides the OSD's existing fade. No morph, no emergence.

## Performance

Each lens surface costs two backdrop passes, and `BackdropGroup` cannot share
them while the shader is loaded (`docs/liquid-glass.md`, "Two backdrop
passes"). Grouping each bar into shared capsules caps a phone's visible OSD at
roughly five glass surfaces. Profile on the oldest test iPhone with 4K HEVC
playing and the OSD up. If raster time exceeds the frame budget, the touch
transport's skip pills return to `osdPill` first; the play disc stays glass.
Dry glass has no backdrop pass and needs no budget.

## Testing

`flutter test` has no Impeller, so tests check structure (see
`docs/liquid-glass.md`, "Tests"):

- `OsdGlass` resolution: iOS gives `sampled`; macOS surface gives `dry`; macOS
  texture gives `sampled`; any other platform or the setting off gives `off`;
  Reduce Transparency gives `off`; no shader turns `sampled` into `dry`.
- Each surface in the table picks the expected recipe in each mode.
- `ChromeScrim` has no plateau in the glass modes and is unchanged in `off`.
- The legibility sweeps above.
- Every existing OSD test passes in `off`.

Visual evidence: a new `osd` scene in the glass lab (the top and bottom bars and
up next, over a bright and a dark frame, in `sampled` and `dry`), rendered by
`./dev player glass-diff`. The PR carries its side-by-side next to `artwork`,
plus device screenshots from iOS and the macOS HDR surface.

## Docs

`docs/liquid-glass.md`: replace the sentence saying the OSD never uses Liquid
Glass, and add an "OSD" section covering the three modes, the scrim change and
dry glass. Add the new files to its piece table and to
`scripts/glass-paths.sh` where they are glass files.

## Files

| File | Change |
| --- | --- |
| `player/lib/presentation/widgets/glass_surface.dart` | `osd` / `osdPill` branch on `OsdGlass` |
| `player/lib/presentation/widgets/glass/osd_glass.dart` | New: the mode, its resolution and the inherited widget |
| `player/lib/presentation/widgets/glass/dry_liquid_glass.dart` | New: the dry painter |
| `player/lib/core/theme/depth_tokens.dart` | `osdLiquidScrimOpacity`, `osdDryTintOpacity` |
| `player/lib/presentation/widgets/video_controls/chrome_scrim.dart` | Gradient-only variant in glass modes |
| `player/lib/presentation/widgets/video_controls/touch_transport.dart` | Glass play disc |
| `player/lib/presentation/widgets/video_controls/chrome_top_bar.dart`, `chrome_bottom_bar.dart` | Shared capsules per group |
| `player/lib/presentation/widgets/video_controls/video_progress_bar.dart` | Clear glass thumb |
| `player/lib/presentation/screens/player/player_screen.dart` | Provides `OsdGlass` from the setting, platform and output path |
| `player/tool/liquid_glass_lab/` | `osd` scene |
| `player/docs/liquid-glass.md` | OSD section |

## Follow-up spike: native glass on macOS

Not part of this spec's plan. It is a short spike with a written answer and no
shipped code. It answers two questions:

1. Can a Flutter `BackdropFilter` sample the `AppKitView` at all? Measure it;
   this design infers it cannot.
2. Can an `NSGlassEffectView` inserted between `MpvHostView` and the Flutter
   view follow pill rects reported over a channel, through the OSD fade and a
   window resize, without visible lag?

If the first answer is no and the second is yes, a later spec replaces `dry`
with native glass on macOS.
