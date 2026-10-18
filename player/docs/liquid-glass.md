# Liquid Glass on iOS and macOS

The floating control layer on iOS and macOS uses a Liquid Glass material
drawn by our own shader, `shaders/liquid_glass.frag`. It bends the backdrop
along the edge, frosts and saturates it, tints it adaptively (lighter over
dark content, stronger over bright content), darkens the outer edge over
`liquidEdgeShadeWidth`, adds a soft inner glow and a specular rim, and
blooms a press glow under the finger, tuned to the iOS 27 look. Other platforms keep the frosted
`GlassSurface` recipes, and the playback OSD (`GlassSurface.osd`) never uses
it.

| Piece | File |
| --- | --- |
| Shader | `shaders/liquid_glass.frag` |
| Tokens | `DepthTokens.liquid*` in `lib/core/theme/depth_tokens.dart` |
| Startup gate | `lib/core/theme/liquid_glass/liquid_glass_support.dart` |
| Uniforms | `lib/core/theme/liquid_glass/liquid_glass_uniforms.dart` |
| Adaptive tint maths, accent tint | `lib/core/theme/liquid_glass/liquid_glass_adaptive.dart` |
| Render object | `lib/presentation/widgets/glass/liquid_glass_filter.dart` |
| Press and hover | `lib/presentation/widgets/glass/glass_interaction.dart`, `glass_pointer.dart` |
| Accessibility flags | `lib/core/theme/liquid_glass/glass_accessibility.dart` |
| Lab | `tool/liquid_glass_lab/main.dart` |

## Where glass goes

Glass belongs to the control layer that floats over content: app and title
bars, the dock, rail, drawer and cast pill, floating buttons over heroes,
sheets, dialogs and popovers, and the primary Play button. Content stays
solid: settings rows, inline buttons, switches, sliders, and anything
repeated per item in a scrolling list. `GlassSurface.faux` and
`.hoverOverlay` never take the Liquid Glass path.

## When it runs

`LiquidGlassSupport.initialize()` runs once at startup. It loads the shader
on iOS and macOS when `ImageFilter.isShaderFilterSupported` (Impeller). A
failure logs `[LiquidGlass] ... using frosted glass` and every surface keeps
its frosted recipe. `GlassSurface.appBar`, `.chrome`, `.modal` and
`.control` then pick the recipe:

- Reduce Transparency on: an opaque fill, no backdrop pass.
- Shader loaded: Liquid Glass, with a stronger tint and a visible rim under
  Increase Contrast.
- Otherwise: the frosted recipe.

Flutter does not expose Reduce Transparency, so the Runners report both
flags over `mydia/native-tab-bar` (`glassAccessibility`,
`glassAccessibilityChanged`).

## The app bar's scroll edge

`GlassSurface.appBar` is not a full glass surface. It is a scroll edge band:
a backdrop blur (`liquidScrollEdgeBlurSigma`) under a vertical gradient of
the ground colour, `liquidScrollEdgeTopOpacity` at the top and over the first
60% of the height, fading to `liquidScrollEdgeBottomOpacity` at the bottom,
with no rim and no refraction. Content scrolls under it and dissolves into
the bar instead of meeting a hard edge. The chips and buttons placed on it
are ordinary glass controls. Reduce Transparency still gets the opaque fill,
and Increase Contrast adds `liquidHighContrastTintBoost` to both ends.

## Two backdrop passes

`RenderLiquidGlass` pushes two nested `BackdropFilterLayer`s. The outer one
blurs and carries the `BackdropGroup` key, so grouped surfaces share it. The
inner one runs `ImageFilter.shader` on the blurred result. Composing the two
with `ImageFilter.compose` shifted the shader's coordinates (the rim landed
inset on the right and bottom only), so they stay separate. Each surface
costs two backdrop passes.

## The shader's coordinate assumption

The inner layer's input is the blurred backdrop under the surface, and the
shader assumes the surface fills it, centred. The lab's grid mode proves it:
the rim must sit on the clip edge on all four sides. Re-check it after a
Flutter upgrade.

## Tint and legibility

Each role has a base tint and an adaptive maximum. For each pixel the shader
reads the brightest luma of the blurred backdrop in a 3x3 grid centred on it,
`liquidAdaptiveRadius` apart. It takes the maximum, not the mean, so a bright
patch under a glyph always raises the tint there. The tint alpha then moves
from the base (dark content) to the maximum (bright content) with a smoothstep between
`liquidAdaptiveLumaLow` and `liquidAdaptiveLumaHigh`. A surface that passes
`adaptiveTintMax` null keeps a fixed tint.

| Role | Base | Adaptive max |
| --- | --- | --- |
| Chrome | `liquidChromeTintOpacity` 0.5 | `liquidChromeAdaptiveMax` 0.85 |
| Modal | `liquidModalTintOpacity` 0.55 | `liquidModalAdaptiveMax` 0.85 |
| Control | `liquidControlTintOpacity` 0.3 | `liquidControlAdaptiveMax` 0.65 |
| Accent | `liquidAccentTintOpacity` 0.55 | `liquidAccentAdaptiveMax` 0.9 |

The tint is lowest at mid luma, so white is not the worst backdrop: the
contrast bottoms out where the ramp has only just started. `liquidAdaptiveAlpha`
in `liquid_glass_adaptive.dart` reproduces the shader's curve, and
`liquid_glass_legibility_test.dart` uses it to sweep grey backdrops from 0 to 1
in steps of 0.05 for every preset and role (text 4.5:1, secondary text and
control icons 3:1, the Play label 4.5:1). A grey's shader luma equals its
value, and the brightest nearby luma is what the curve takes, so the sweep is
the worst case under a glyph. `liquidAdaptiveLumaLow` is 0.35 because the
sweep failed at 0.55 (secondary text 2.6 to 2.9:1 and the Play label 4.1 to
4.3:1 near luma 0.6 to 0.7). Change the curve in the shader and in
`liquidAdaptiveAlpha` together.

The frosted fallback of the accent control cannot adapt, so it fills at
`liquidAccentAdaptiveMax`, the alpha the white label is rated at.

The accent tint comes from `accentGlassTint(color)`, which darkens the accent
until a white label keeps 4.5:1 at `liquidAccentAdaptiveMax` over white; an
accent that already clears it is returned unchanged.

## Running the lab

On a Mac, from `player/`:

    flutter run -d macos -t tool/liquid_glass_lab/main.dart

`MYDIA_LIQUID_GLASS=true` (`--dart-define`) makes any platform eligible, for
the lab only.

The player app does not build for Linux desktop without libsecret
(`flutter_secure_storage`), so on Linux run the lab from a plugin-free
scratch Flutter project. Copy the lab in as the scratch project's
`lib/main.dart` (so plain `flutter run` picks it), plus `depth_tokens.dart`,
`liquid_glass_support.dart`, `liquid_glass_uniforms.dart`,
`liquid_glass_adaptive.dart`, `contrast.dart`,
`liquid_glass_filter.dart` and `glass_pointer.dart`, rewrite their imports,
and register the shader under `flutter: shaders:`. Headless, from the
scratch project:

    xvfb-run -a -s "-screen 0 2560x1800x24" env GDK_SCALE=2 \
      flutter run -d linux --dart-define=MYDIA_LIQUID_GLASS=true \
      --dart-define=LAB_SNAPSHOT=/tmp/lab.png

The lab also needs `liquid_glass_adaptive.dart` and `contrast.dart`, now that
it uses `accentGlassTint`. `GDK_SCALE=2` gives a 2x device pixel ratio. Add `LAB_GRID=true` for the
grid and `LAB_SCROLL=<px>` to scroll the backdrop first.

## Tests

`flutter test` has no Impeller, so tests drive the structure, not the
pixels: set `LiquidGlassSupport.debugOverride = true` to select the recipe
(the render object then pushes the blur alone) and
`LiquidGlassSupport.debugPlatformOverride` to choose glass or Material
controls. Reset both in `tearDown`. `liquid_glass_legibility_test.dart`
computes text and icon contrast from the tokens.

## Controls

The control layer is a small set of helpers under
`lib/presentation/widgets/glass/` (plus `PrimaryPlayButton`). Each one
renders glass on iOS and macOS, gated on `LiquidGlassSupport.platformEligible`,
and falls back to the widget the call site used before everywhere else.

| Control | Use | Off iOS and macOS |
| --- | --- | --- |
| `GlassIconButton` | Floating back and cast buttons over the detail hero | `IconButton` |
| `PrimaryPlayButton` | Play and Resume: an accent glass capsule (`accentGlassTint`, accent tint pair) with a white label | Solid white pill |
| `GlassChip` | Sort and filter chips; `chipKey` keys the inner chip so tests can read it | `ChoiceChip`, or `FilterChip` with `multiSelect` |
| `GlassDialog` | Every in-app dialog | `AlertDialog` |
| `showGlassSheet` | Every in-app bottom sheet | `showModalBottomSheet` with the caller's arguments |
| `GlassPopoverSurface` | The source picker popover | Elevated Material card |

Control-role glass (`GlassSurface.control`) casts a soft drop shadow,
`liquidControlShadow`, so it lifts off the content behind it.
`GlassSurface.control(accentColor:)` tints with the accent instead of the
ground colour.

Glass controls wrap `GlassInteraction`, which supplies the press swell and
the macOS hover highlight. Sheets and the source picker popover use
`glassEmergence`: a scale from 0.9 plus a fade, or the fade alone when Reduce
Motion is on. A sheet grows from its opener only when `origin` is passed.
Dialogs go through plain `showDialog` and do not. `GlassIconButton` adapts
its diameter to short rows (the 40 point macOS title row), keeping 4 points
of clearance above and below.

Content buttons (`FilledButton`, `OutlinedButton` and the like) are capsules
with no ripple on Apple platforms. `AppTheme.build` sets that, so call sites
do nothing.

A widget shown inside a sheet must not paint its own opaque root surface on
Apple, or it hides the glass behind it. `FilterEditorSheet` and
`LibrarySortSheet` switch on `LiquidGlassSupport.platformEligible` and drop
their background there.

Two guard tests keep new code on the helpers.
`glass_dialog_call_sites_test.dart` fails on any `AlertDialog(` outside
`GlassDialog`, and `glass_sheet_call_sites_test.dart` fails on any
`showModalBottomSheet<` outside `showGlassSheet`. Each has an allowlist for
the exceptions: the player-screen dialog (`resume_dialog.dart`), and the OSD
and player-opened sheets (`osd_sheet.dart`, `quality_selector.dart`).
