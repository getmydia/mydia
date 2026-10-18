# Liquid Glass on iOS and macOS

The floating control layer on iOS and macOS uses a Liquid Glass material
drawn by our own shader, `shaders/liquid_glass.frag`. It bends the backdrop
along the edge, frosts and saturates it, darkens the outer edge and lights a
specular rim, tuned to the iOS 27 look. Other platforms keep the frosted
`GlassSurface` recipes, and the playback OSD (`GlassSurface.osd`) never uses
it.

| Piece | File |
| --- | --- |
| Shader | `shaders/liquid_glass.frag` |
| Tokens | `DepthTokens.liquid*` in `lib/core/theme/depth_tokens.dart` |
| Startup gate | `lib/core/theme/liquid_glass/liquid_glass_support.dart` |
| Uniforms | `lib/core/theme/liquid_glass/liquid_glass_uniforms.dart` |
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

The chrome and modal tints are `DepthTokens.liquidChromeTintOpacity` and
`liquidModalTintOpacity`, both 0.80. They are bounded below by
`liquid_glass_legibility_test.dart` (secondary text must keep 3:1 over
white), so a clearer look has to come from somewhere other than a lower
tint.

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
`liquid_glass_filter.dart` and `glass_pointer.dart`, rewrite their imports,
and register the shader under `flutter: shaders:`. Headless, from the
scratch project:

    xvfb-run -a -s "-screen 0 2560x1800x24" env GDK_SCALE=2 \
      flutter run -d linux --dart-define=MYDIA_LIQUID_GLASS=true \
      --dart-define=LAB_SNAPSHOT=/tmp/lab.png

`GDK_SCALE=2` gives a 2x device pixel ratio. Add `LAB_GRID=true` for the
grid and `LAB_SCROLL=<px>` to scroll the backdrop first.

## Tests

`flutter test` has no Impeller, so tests drive the structure, not the
pixels: set `LiquidGlassSupport.debugOverride = true` to select the recipe
(the render object then pushes the blur alone) and
`LiquidGlassSupport.debugPlatformOverride` to choose glass or Material
controls. Reset both in `tearDown`. `liquid_glass_legibility_test.dart`
computes text and icon contrast from the tokens.
