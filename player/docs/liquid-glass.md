# Liquid Glass

Liquid Glass is a device setting, Settings > Appearance > Liquid Glass
(`GlassMaterialSetting`). It is on by default on native iOS and macOS, off
elsewhere, and not offered on Android TV. Native chrome drawn by the iOS and
macOS Runners (the tab bar and the sidebars) is outside the setting.

With it on, the floating control layer uses a Liquid Glass material
drawn by our own shader, `shaders/liquid_glass.frag`. Its numbers come from
`LiquidGlassProfile` (see "Kit mapping"): the shader frosts and saturates the
backdrop, bends it in an edge band that scales with the corner radius, tints
it adaptively (lighter over dark content, stronger over bright content), adds
a specular rim on every edge with a little light across the top and bottom
and volume shading inside, and blooms a press glow under the pointer. Glass
casts the profile's drop shadow for depth.
It is tuned to the iOS 27 look. With the setting off, the app keeps the
frosted `GlassSurface` recipes and Material controls, and the playback OSD
(`GlassSurface.osd`) never uses Liquid Glass.

| Piece | File |
| --- | --- |
| Shader | `shaders/liquid_glass.frag` |
| Tokens | `DepthTokens.liquid*` in `lib/core/theme/depth_tokens.dart` |
| Shader loader | `lib/core/theme/liquid_glass/liquid_glass_support.dart` |
| Design-language flag | `lib/core/theme/liquid_glass/glass_style.dart` |
| Uniforms | `lib/core/theme/liquid_glass/liquid_glass_uniforms.dart` |
| Adaptive tint maths | `lib/core/theme/liquid_glass/liquid_glass_adaptive.dart` |
| Render object | `lib/presentation/widgets/glass/liquid_glass_filter.dart` |
| Press and hover | `lib/presentation/widgets/glass/glass_interaction.dart`, `glass_pointer.dart` |
| Accessibility flags | `lib/core/theme/liquid_glass/glass_accessibility.dart` |
| Lab | `tool/liquid_glass_lab/main.dart` |

## Where glass goes

Glass belongs to the control layer that floats over content: app and title
bars, the dock, rail, drawer and cast pill, floating buttons over heroes,
sheets, dialogs and popovers, the primary Play button, the home hero's
buttons and episode badge, the detail action row, the "Next Up" badge over
artwork, and the capsule behind the selected season. Content stays solid:
settings rows, inline buttons, switches, sliders, and anything repeated per
item in a scrolling list. Per-card overlays and metadata chips stay solid
because they repeat in scrolling lists and each glass surface costs two
backdrop passes. The detail action row and the home hero sit in a
`BackdropGroup`, but only the frosted fallback shares its blur there (see
below). `GlassSurface.faux` and
`.hoverOverlay` never take the Liquid Glass path.

The phone drawer follows the floating rail on Liquid Glass: it sits
`Breakpoints.railInset` in from the leading, top and bottom edges (plus the
safe area), rounds all four corners at `AppTheme.radiusRail`, and carries the
rail's rim, shadow and scrim (`FloatingRail.scrimColor`). Without the shader
it stays a Material drawer flush to the edge.

## Panels

Three profiles (`LiquidGlassProfile`) share the one shader. The **lens** is
the floating control layer: buttons, chips, badges, the dock pill and the cast
pill. It bends the backdrop at the rim, lights every edge and shades the
interior a little. The **panel** is for large surfaces: `GlassSurface.modal`
(dialogs, sheets, popovers, the login cards) and `GlassSurface.sidebar` (the
floating rail and the drawer). It blurs harder, washes the backdrop toward a
dark luminance, and keeps a discreet rim. Hover and press do not light it.
The **clear** profile is for slider and segmented thumbs: no blur, a faint
bend.

Panels refract. The edge band is the depth times the corner radius, so a
panel with a 28pt radius has a wide band, and the distortion (0.3, gentler than
the lens's 0.4) spreads over it: the bend is soft and wide where the lens's is
tight. Panels do not fringe colour (dispersion is 0 everywhere, as in the kit)
and have no inner glow.

Tint and adaptive tint are per surface role, not per profile, so the
legibility contract holds for all three.

The native macOS and iPadOS sidebars are AppKit and UIKit views and never use
any profile.

## Kit mapping

The profiles follow Apple's iOS 27 UI Kit, read from its glass layers over
dark backgrounds. The kit has three glass materials plus a clear one:

| Kit layer | Blur | Saturation | Distortion | Depth | Wash | Shadow | Profile |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Small UI (80x48 capsule) | 6 | 1 | 0.4 | 0.8 | grey 153 at 17%, normal | 0 8 15, black 4% | `lens` |
| Medium UI (r20) | 30 | 1.2 | 0.3 | 0.9 | grey 25 at 30% normal plus 30% luminosity | 0 18 48, black 45% | none yet |
| Large UI (r20) | 30 | 1.2 | 0.3 | 0.9 | grey 25 at 50% normal plus 90% luminosity | 0 18 48, black 45% | `panel` |
| Clear (knob 37x24, segmented thumb) | 0 | 1 | 0.08 | 0.4 | none | none | `clear` |

Small UI is used by buttons, tab bars, toolbars and the edit menu. Large UI is
used by alerts (r34), sheets (r34), menus (r32) and pickers. The kit sets
chromatic aberration to 0 on every layer.

Our values:

| Profile | `blurSigma` | `depth` | `distortion` | `saturation` | `brightness` | `lumaTarget` / `lumaMix` | `shadow` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lens` | 3 | 0.8 | 0.4 | 1.0 | 0.1 | 0 / 0 | 0 8 15, black 4% |
| `panel` | 15 | 0.9 | 0.3 | 1.2 | 0 | 0.1 / 0.3 | 0 18 48, black 45% |
| `clear` | 0 | 0.4 | 0.08 | 1.0 | 0.02 | 0 / 0 | 0 2 8, black 15% (ours) |

`blurSigma` is the kit's blur radius halved: a Gaussian sigma is about half
the radius a design tool shows. The edge band is `depth` times the corner
radius, capped at half the short side (`LiquidGlassUniforms.edgeBandFor`).

The lens's `brightness` lift stands in for the small grey wash. The panel's
`lumaTarget` and `lumaMix` stand in for the luminosity wash: a luminosity
blend keeps the backdrop's hue and takes the fill's luminance, so the shader
pulls the backdrop's luminance toward `lumaTarget` by `lumaMix` and leaves the
hue alone. The kit's normal-blend part of the wash is the surface tint, which
stays per role. The panel takes the kit's Medium UI luminosity share, since the
Large share plus our role tint read as an opaque slab.

The kit's lighting is off. Its rim is drawn with stacked shadows that show
through the translucent fill, and the shader's rim terms decode them:

- The hairline ring (spread 0.5, grey 190 on small, spread 0.3, grey 166 on
  large) is `rimHairline`, a light line on every edge.
- The side slivers (x of plus and minus 1.25, spread -0.75) are `sideLight`,
  rim light on the left and right edges relative to the top.
- The small layer's volume shadows are `volumeSide` and `volumeEnds`. The
  x of plus and minus 20 shadow (blur 20, spread -30, grey 178) lightens the
  interior toward the sides; the y of plus and minus 40 shadow (blur 10, spread
  -40, grey 25) darkens it toward the top and bottom.
- The large layer's ends band (y of plus and minus 4, blur 8, spread -4,
  grey 33) is `volumeEnds` on the panel.
- The large layer's bottom catch-light (white at 20%, y of plus 2, spread
  -1.2) is `bottomLight`.

## When it runs

`LiquidGlassSupport.initialize()` runs once at startup. It loads the shader
on every platform where `ImageFilter.isShaderFilterSupported` (Impeller),
whatever the setting, so switching to Liquid Glass needs no restart. A
failure logs `[LiquidGlass] ... using frosted glass` and every surface keeps
its frosted recipe.

`GlassStyle.of(context)`, carried on the app theme and set from the
setting, gates the design language: glass controls instead of Material ones.
`GlassSurface` takes the Liquid Glass recipe only when
`GlassStyle.of(context)` and `LiquidGlassSupport.available` are both true.
Without the shader, Liquid Glass means the design language on the frosted
recipe. `GlassSurface.appBar`, `.chrome`, `.sidebar`, `.modal` and
`.control` then pick the recipe:

- Reduce Transparency on: an opaque fill, no backdrop pass. On Liquid Glass
  the opaque fill keeps the profile's shadow.
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
blurs; the inner one runs `ImageFilter.shader` on the blurred result.
Composing the two with `ImageFilter.compose` shifted the shader's
coordinates (the rim landed inset on the right and bottom only), so they stay
separate. Each surface costs two backdrop passes.

The blur never takes the `BackdropGroup` key while the shader is loaded. A
grouped blur reads the group's shared backdrop, and the lens nested in it
then no longer finds the surface centred in its input. On an iPhone this
washed grouped controls out to a flat light grey, drew a white half disc in
one action circle, and left the highlights in place while the content
scrolled. Ungrouped surfaces in the same scroll view rendered correctly.
`flutter test` cannot render the lens, so `liquid_glass_filter_test.dart`
checks the layer's key instead. The frosted fallback has no lens and still
shares the group's pass.

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
from the base (dark content) to the maximum (bright content) with a
smoothstep between `liquidAdaptiveLumaLow` (0.15) and
`liquidAdaptiveLumaHigh` (0.9). A surface that passes
`adaptiveTintMax` null keeps a fixed tint.

| Role | Base | Adaptive max |
| --- | --- | --- |
| Chrome | `liquidChromeTintOpacity` 0.35 | `liquidChromeAdaptiveMax` 0.9 |
| Modal | `liquidModalTintOpacity` 0.35 | `liquidModalAdaptiveMax` 0.85 |
| Control | `liquidControlTintOpacity` 0.2 | `liquidControlAdaptiveMax` 0.65 |

The frosted fallback of `GlassSurface.control` cannot adapt, so it fills at
`liquidControlAdaptiveMax`, the alpha white control labels are rated at over
pure white.

Contrast is lowest at mid-luma, so white is not the worst backdrop: the
contrast bottoms out where the ramp has only just started. `liquidAdaptiveAlpha`
in `liquid_glass_adaptive.dart` reproduces the shader's curve, and
`liquid_glass_legibility_test.dart` uses it to sweep grey backdrops from 0 to 1
in steps of 0.05 for every preset and role (text 4.5:1, secondary text and
control icons 3:1, white control labels such as Play and the glass buttons
4.5:1). A grey's shader luma equals its value, and the brightest nearby luma
is what the curve takes, so the sweep is the worst case under a glyph. The
shader lifts the backdrop by the profile's `brightness` before tinting while
the tint alpha still reads the unlifted luma, so the test lifts each grey the
same way.
Change the curve in the shader and in `liquidAdaptiveAlpha` together.

## Running the lab

On a Mac, from `player/`:

    flutter run -d macos -t tool/liquid_glass_lab/main.dart

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
      flutter run -d linux --dart-define=LAB_SNAPSHOT=/tmp/lab.png

`GDK_SCALE=2` gives a 2x device pixel ratio. Add `LAB_GRID=true` for the
grid and `LAB_SCROLL=<px>` to scroll the backdrop first.

## Tests

`flutter test` has no Impeller, so tests drive the structure, not the
pixels: set `LiquidGlassSupport.debugOverride = true` to select the recipe
(the render object then pushes the blur alone). Pump under
`AppTheme.build(palette, liquid: true)` (or `false`) to choose glass or
Material controls. Reset `debugOverride` in `tearDown`. `liquid_glass_legibility_test.dart`
computes text and icon contrast from the tokens.

## Controls

The control layer is a small set of helpers under
`lib/presentation/widgets/glass/` (plus `PrimaryPlayButton`). Each one
renders glass when `GlassStyle.of(context)` is true, and falls back to the
widget the call site used before otherwise.

| Control | Use | With Liquid Glass off |
| --- | --- | --- |
| `GlassIconButton` | Floating back and cast buttons over the detail hero | `IconButton` |
| `PrimaryPlayButton` | Play and Resume: a neutral glass capsule with a white label | Solid white pill (`FilledButton` on the home hero) |
| `GlassButton` | The home hero's secondary action | `OutlinedButton` |
| `GlassBadge` | The home hero's episode chip and the show detail "Next Up" pill | The call site's previous decoration |
| `GlassChip` | Sort and filter chips; `chipKey` keys the inner chip so tests can read it | `ChoiceChip`, or `FilterChip` with `multiSelect` |
| `GlassDialog` | Every in-app dialog | `AlertDialog` |
| `showGlassSheet` | Every in-app bottom sheet | `showModalBottomSheet` with the caller's arguments |
| `GlassPopoverSurface` | The source picker popover | Elevated Material card |

Control-role glass (`GlassSurface.control`) casts the lens profile's shadow
(`LiquidGlassProfile.lens.shadow`), so it lifts off the content behind it. The detail
action row and the season selector use `GlassSurface.control` directly: the
action row draws circles with `grouped: true` inside one `BackdropGroup`, and
the season selector draws one capsule behind the selected season while
unselected seasons stay plain labels.

Glass controls wrap `GlassInteraction`, which supplies the press swell and
the macOS hover highlight. Sheets and the source picker popover use
`glassEmergence`: a scale from 0.9 plus a fade, or the fade alone when Reduce
Motion is on. A sheet grows from its opener only when `origin` is passed.
Dialogs go through plain `showDialog` and do not. `GlassIconButton` adapts
its diameter to short rows (the 40 point macOS title row), keeping 4 points
of clearance above and below.

Content buttons (`FilledButton`, `OutlinedButton` and the like) are capsules
with no ripple under Liquid Glass. `AppTheme.build(p, liquid: true)` sets
that, so call sites do nothing.

A widget shown inside a sheet must not paint its own opaque root surface on
Liquid Glass, or it hides the glass behind it. `FilterEditorSheet` and
`LibrarySortSheet` switch on `GlassStyle.of(context)` and drop their
background there.

Two guard tests keep new code on the helpers.
`glass_dialog_call_sites_test.dart` fails on any `AlertDialog(` outside
`GlassDialog`, and `glass_sheet_call_sites_test.dart` fails on any
`showModalBottomSheet<` outside `showGlassSheet`. Each has an allowlist for
the exceptions: the player-screen dialog (`resume_dialog.dart`), and the OSD
and player-opened sheets (`osd_sheet.dart`, `quality_selector.dart`).

## Clear and Tinted

iOS 26.1 added a Clear/Tinted Liquid Glass setting (Settings, Display &
Brightness). Apple applies it automatically to system glass, but no public
UIKit or AppKit API reports the user's choice: none was found in Apple's
documentation or in the UIAccessibility bindings as of iOS 26.2. Our shader
cannot follow it, so it ships one look tuned to the default. If Apple exposes
the value, add it to the `glassAccessibility` payload on
`mydia/native-tab-bar` and select a higher base-tint token set for Tinted.
