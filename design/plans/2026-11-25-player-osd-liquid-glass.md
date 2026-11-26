# Liquid Glass playback OSD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the playback OSD on Liquid Glass on iOS and macOS: shader glass where the video is a Flutter texture, dry glass over the macOS HDR surface, today's OSD everywhere else.

**Architecture:** An `OsdGlassMode` (`off` / `sampled` / `dry`) is resolved from the glass style, platform, Reduce Transparency, shader availability and whether the macOS surface holds the video. An app-level host carries it, like `GlassAccessibilityHost`, so OSD sheets and dialogs (separate routes) see it too. `GlassSurface.osd` / `.osdPill` branch on it; `ChromeScrim` drops its plateau in the glass modes (superseded by the spec's "Revision after #1525": the plateau stays).

**Tech Stack:** Flutter (Impeller fragment shader `shaders/liquid_glass.frag`), Riverpod, `flutter test`.

**Spec:** `design/specs/2026-11-25-player-osd-liquid-glass-design.md`. Background: `design/research/2026-11-25-liquid-glass-player-controls.md`. Read `player/docs/liquid-glass.md` before Task 3.

## Global Constraints

- Glass OSD only on iOS and macOS (never web), only with `GlassStyle.of(context)` true, never under Reduce Transparency.
- Every other case renders the OSD exactly as `master` does; existing OSD tests and every `*_tv_test.dart` pass unchanged.
- No layout, behaviour, focus-order or press-count changes.
- White labels and glyphs 4.5:1, icons 3:1, over greys 0 to 1 in steps of 0.05, in every glass mode. Fix tokens, never thresholds.
- Scrubber track, timecodes and subtitles never take glass.
- Tokens live in `DepthTokens`; no per-call literals.
- Any commit staging a glass file (`scripts/glass-paths.sh`: the shader, `lib/core/theme/liquid_glass/`, `depth_tokens.dart`, `lib/presentation/widgets/glass/`, `glass_surface.dart`, the lab) needs `./dev player glass-diff` first; the hook refuses otherwise.
- Commit from the worktree root with `direnv exec . git commit -F <msgfile>`; stage every path first, then `git show --stat HEAD`.
- Tests: `./dev flutter test --concurrency=1 <paths>` from the repo root. Set `LiquidGlassSupport.debugOverride`, `GlassAccessibilityNotifier.debugIsApple` and `debugDefaultTargetPlatformOverride` only inside tests, and reset them in `tearDown`.
- Never write provider state from `dispose` (`player/docs/riverpod.md`).
- No em dashes in docs or comments.

## Review Focus

1. **Surface falls back to the texture mid-session.** The OSD must switch `dry` → `sampled` for that playback, and back to `dry` when the next playback takes the surface. Task 2 pins it.
2. **Leaving the player while the surface is active.** The surface flag must clear, or every later sheet on macOS renders `dry` over non-video screens. (OSD sheets only open from the player, but the flag must not leak.) Task 2 pins it.
3. **Toggling Liquid Glass or Reduce Transparency during playback.** The OSD must switch recipe on the next frame, with no restart. Task 4 pins it with a rebuild test.
4. **Increase Contrast in dry mode.** The rim and tint boost apply just as on the sampled path. Task 3 pins it.
5. **An OSD sheet or dialog opened from the player.** It must use the same mode as the bars, because it is a separate route. Task 4 pins it with `showOsdBottomSheet` and `OsdDialog` under the host.

---

### Task 1: `OsdGlassMode`, its resolver and the app host

**Files:**
- Create: `player/lib/presentation/widgets/glass/osd_glass.dart`
- Modify: `player/lib/app.dart` (around line 691, inside `GlassAccessibilityHost`)
- Test: `player/test/presentation/widgets/glass/osd_glass_test.dart`

**Interfaces:**
- Produces:
  - `enum OsdGlassMode { off, sampled, dry }`
  - `OsdGlassMode resolveOsdGlassMode({required bool liquidStyle, required bool isWeb, required TargetPlatform platform, required bool reduceTransparency, required bool shaderAvailable, required bool surfaceOutput})`
  - `final videoSurfaceOutputProvider = NotifierProvider<VideoSurfaceOutputNotifier, bool>(...)` with `void set(bool active)`; initial `false`.
  - `class OsdGlassScope extends InheritedWidget { final bool surfaceOutput; }`
  - `class OsdGlassHost extends ConsumerWidget` that watches the provider and builds `OsdGlassScope`.
  - `abstract final class OsdGlass { static OsdGlassMode of(BuildContext context); }` calls the resolver with `GlassStyle.of`, `kIsWeb`, `defaultTargetPlatform`, `GlassAccessibilityScope.of(context).reduceTransparency`, `LiquidGlassSupport.available`, and the scope's `surfaceOutput` (false with no scope).

- [ ] **Step 1: Write the failing resolver tests**

Table-driven `test`s on `resolveOsdGlassMode`:
- iOS, liquid on, shader on → `sampled`.
- macOS, surface output false → `sampled`.
- macOS, surface output true → `dry`.
- iOS with `surfaceOutput: true` → `sampled` (only macOS has the surface).
- iOS or macOS, shader off → `dry`.
- `liquidStyle: false` → `off`.
- `reduceTransparency: true` → `off`.
- `isWeb: true` on any platform → `off`.
- android, windows, linux, fuchsia with liquid on → `off`.

One `testWidgets`: under `OsdGlassScope(surfaceOutput: true)` with a liquid `AppTheme.build(palette, liquid: true)`, `debugDefaultTargetPlatformOverride = TargetPlatform.macOS` and `LiquidGlassSupport.debugOverride = true`, `OsdGlass.of` returns `dry`; with no scope it returns `sampled`.

- [ ] **Step 2: Run and confirm it fails**

Run: `./dev flutter test --concurrency=1 test/presentation/widgets/glass/osd_glass_test.dart`
Expected: compile failure, because `osd_glass.dart` does not exist.

- [ ] **Step 3: Implement `osd_glass.dart`**

The resolver is a plain `switch`. `OsdGlassScope.updateShouldNotify` compares `surfaceOutput`.

- [ ] **Step 4: Mount `OsdGlassHost` in `app.dart`**

Mount it directly inside `GlassAccessibilityHost`, so dialogs and sheets on the root navigator see it.

- [ ] **Step 5: Run the tests and confirm they pass**

Same command. Expected: PASS.

- [ ] **Step 6: Glass-diff, then commit**

`./dev player glass-diff`. Expected: 0 changed pixels in every scene. Commit `feat(player): resolve the OSD glass mode`.

### Task 2: The player screen publishes the surface output

**Files:**
- Modify: `player/lib/presentation/screens/player/player_screen.dart` at the `_surfaceBinding` assignments (lines ~3053, 3171, 5744, 6168) and `initState`/`dispose`
- Test: `player/test/presentation/screens/player/player_screen_osd_glass_test.dart`

**Interfaces:**
- Consumes: `videoSurfaceOutputProvider.notifier.set(bool)` from Task 1.
- Produces: the provider is `true` exactly while `_surfaceBinding != null`.

- [ ] **Step 1: Write the failing tests**

Drive `PlayerScreen` with the existing `outputPath:` test seam (`VideoOutputPath Function()?`, line 202), following the nearest existing player screen test for the fakes.
- `outputPath` surface: after load, `container.read(videoSurfaceOutputProvider)` is `true`.
- Surface failure fallback (use whatever seam the existing surface-fallback tests use): it becomes `false`.
- Popping the screen leaves it `false`.

- [ ] **Step 2: Run and confirm they fail**

Expected: the provider is `false` throughout.

- [ ] **Step 3: Publish the flag**

Add a private `_setSurfaceBinding(MpvSurfaceBinding? b)` that assigns the field and calls `set(b != null)`, and route every assignment through it. Capture the notifier eagerly in `initState`. In `dispose`, schedule the `false` write with `Future.microtask` on the captured notifier, never `ref` (`player/docs/riverpod.md`, first section).

- [ ] **Step 4: Run and confirm they pass**

- [ ] **Step 5: Commit**

`feat(player): tell the OSD when the macOS surface holds the video`

### Task 3: Dry glass and its tint token

**Files:**
- Create: `player/lib/presentation/widgets/glass/dry_liquid_glass.dart`
- Modify: `player/lib/core/theme/depth_tokens.dart` (OSD block near line 167)
- Test: `player/test/presentation/widgets/glass/dry_liquid_glass_test.dart`, `player/test/presentation/widgets/glass/liquid_glass_legibility_test.dart`

**Interfaces:**
- Produces:
  - `class DryLiquidGlass extends StatelessWidget { const DryLiquidGlass({super.key, required BorderRadius borderRadius, required Color tint, required LiquidGlassProfile profile, bool increaseContrast = false, Widget? child}); }`
  - `DepthTokens.osdDryTintOpacity` (double)

- [ ] **Step 1: Write the failing legibility test**

In `liquid_glass_legibility_test.dart`, add `group('OSD dry')`. For each grey `v` in 0..1 step 0.05: `_over(_grey(v, 0), osdTint, osdDryTintOpacity)`. Assert that white text is at least 4.5:1 and white icons at least 3:1. Reuse the file's `_over` / `_grey` helpers and its contrast function.

- [ ] **Step 2: Run, confirm it fails (no token), then set the token**

Set `osdDryTintOpacity` to the smallest multiple of 0.05 that passes. Document the derivation in the token's comment.

- [ ] **Step 3: Write the failing widget tests**

In `dry_liquid_glass_test.dart`:
- The widget pushes no `BackdropFilter`: `find.byType(BackdropFilter)` finds nothing.
- It paints a `CustomPaint` whose painter reports the passed `tint`.
- It clips to `borderRadius`.
- With `increaseContrast: true`, the tint alpha is `osdDryTintOpacity + liquidHighContrastTintBoost` (clamped) and a rim border at `liquidHighContrastRimAlpha` is present.
- Under a `GlassPointer` with `pressed: true` and the lens profile, the painter's glow is `DepthTokens.liquidPressGlow`. With the panel profile (`interactive: false`) it is 0.

Expose the painter's inputs as `@visibleForTesting` getters.

- [ ] **Step 4: Implement**

A `ClipRRect` holding a `CustomPaint`, with the child on top. The painter fills the rounded rect with `tint`, then draws:
- a rim stroke of white at `profile.rimHairline`, `profile.rimWidth` wide;
- a top and bottom catch light: a vertical white gradient at `profile.specular` alpha, fading over 30% of the height from each end;
- when pressed and `profile.interactive`, a radial white glow at `DepthTokens.liquidPressGlow`, centred on `GlassPointer.light`.

There is no backdrop layer. Tune by eye in Task 7.

- [ ] **Step 5: Run both test files and confirm they pass**

- [ ] **Step 6: Glass-diff, then commit**

Expected: 0 changed pixels, since nothing uses the widget yet. Commit `feat(player): add dry Liquid Glass for unsampled backdrops`.

### Task 4: `GlassSurface.osd` and `.osdPill` take the mode

**Files:**
- Modify: `player/lib/presentation/widgets/glass_surface.dart:320-383` and `build` (line 386)
- Test: `player/test/presentation/widgets/glass/glass_surface_osd_liquid_test.dart`; add a pill case to `player/test/presentation/widgets/glass/liquid_glass_legibility_test.dart`

**Interfaces:**
- Consumes: `OsdGlass.of` (Task 1), `DryLiquidGlass` and `osdDryTintOpacity` (Task 3).
- Produces: a new field `final OsdRole? osdRole;` with `enum OsdRole { pill, panel }`. `osd` sets `panel`; `osdPill` sets `pill`.

- [ ] **Step 1: Write the failing tests**

Pump each constructor under a liquid theme, `OsdGlassScope` and `LiquidGlassSupport.debugOverride = true`:
- `sampled`: finds `LiquidGlassFilter`. Its `profile` is `lens` for `osdPill` and `panel` for `osd`. Its `tint` is `osdTint` at `liquidControlTintOpacity` (pill) or `liquidModalTintOpacity` (panel). Its `adaptiveTintMax` is `liquidControlAdaptiveMax` or `liquidModalAdaptiveMax`.
- `dry` (macOS override plus `surfaceOutput: true`): finds `DryLiquidGlass` with the same profile, and no `LiquidGlassFilter`.
- `off` (non-liquid theme; Android override; or `GlassAccessibilityScope` with `reduceTransparency: true`): the widget tree matches today's. Assert no `LiquidGlassFilter` or `DryLiquidGlass`, and the `DecoratedBox` fill is `osdTint` at `osdFillOpacity`.
- Shadows: `osd(elevation: OsdElevation.panel)` keeps `osdShadowPanel` in every mode, and `osdPill` keeps `osdShadowPill`.
- Rebuild: flipping the theme's `liquid` between pumps switches between the `LiquidGlassFilter` and `off` trees (Review Focus 3).
- Route: under `OsdGlassHost` with the provider at `true` on macOS, `showOsdBottomSheet` and an `OsdDialog` in `showDialog` both build `DryLiquidGlass` (Review Focus 5).

Legibility: add OSD pill and OSD panel cases to the adaptive sweep, using base `osdTint` and the control and modal tokens. The scrim gets no credit; this is the conservative case.

- [ ] **Step 2: Run and confirm they fail**

- [ ] **Step 3: Implement**

At the top of `build`, when `osdRole != null`, switch on `OsdGlass.of(context)`:
- `off`: today's code path.
- `sampled`: reuse `_liquid` with base `osdTint` and the role's tokens and profile.
- `dry`: `DryLiquidGlass`, passing `increaseContrast` from `GlassAccessibilityScope`.

Wrap the result in `_withShadow(..., shadows)`. Replace the doc comments on both constructors and on the class (which say the OSD never takes Liquid Glass).

- [ ] **Step 4: Run the new tests plus every existing OSD test and confirm they pass**

Run: `./dev flutter test --concurrency=1 test/presentation/widgets/glass test/presentation/widgets/video_controls test/presentation/widgets/osd_sheet_test.dart test/presentation/widgets/osd_dialog_test.dart`

- [ ] **Step 5: Glass-diff, then commit**

The lab has no OSD scene yet, so expect 0 changed pixels. Commit `feat(player): put the OSD surfaces on Liquid Glass on iOS and macOS`.

### Task 5: Gradient-only scrim in the glass modes

> **Superseded:** see the spec's "Revision after #1525". The scrim plateau stays in the glass modes; this task's gradient-only scrim was not kept.

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/chrome_scrim.dart`, `player/lib/core/theme/depth_tokens.dart`
- Test: `player/test/presentation/widgets/video_controls/chrome_scrim_test.dart` (create it if absent; otherwise extend the existing scrim test)

**Interfaces:**
- Consumes: `OsdGlass.of`.
- Produces: `DepthTokens.osdLiquidScrimOpacity = 0.35`.

- [ ] **Step 1: Write the failing tests**

- In `sampled` and `dry`, the `topKey` band's gradient is `[osdTint @0.35, transparent]` with stops `[0, 1]` and height `topHeight + fadeExtent`. The bottom band mirrors it.
- In `off`, the colours and stops are exactly today's: three stops with the plateau.

- [ ] **Step 2: Run and confirm they fail**

- [ ] **Step 3: Implement**

Branch in `build`. Keep `_bands` for `off`.

- [ ] **Step 4: Run the tests plus `osd_legibility_test.dart` and confirm they pass**

`off` must be unchanged, so the legibility test passes untouched.

- [ ] **Step 5: Glass-diff, then commit**

`depth_tokens.dart` is staged, so glass-diff is required. Commit `feat(player): let glass OSD pills see the video through the scrim`.

### Task 6: Glass play disc and clear scrubber knob

> **Superseded in part:** see the spec's "Revision after #1525". The scrubber thumb stays white, not a clear knob; the glass play disc from this task stands.

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/touch_transport.dart` (play disc, lines ~75-90 and its build), `player/lib/presentation/widgets/video_controls/video_progress_bar.dart` (thumb at line ~246, `ProgressBarSurface.thumbKey`)
- Test: the existing `touch_transport` and `video_progress_bar` tests under `player/test/presentation/widgets/video_controls/`

**Interfaces:**
- Consumes: `OsdGlass.of`, `GlassSurface.osdPill` (Task 4), `LiquidGlassFilter` with `LiquidGlassProfile.clear`, `DryLiquidGlass`.

- [ ] **Step 1: Write the failing tests**

- Touch transport in `sampled`: the play disc is a circular `GlassSurface.osdPill` whose glyph and buffering spinner are white (`palette.textPrimary`). In `off` it is today's opaque disc with a dark glyph. Its size, key, semantics and hit area are unchanged.
- Progress bar in `sampled`: the widget at `thumbKey` contains a `LiquidGlassFilter` with `profile == LiquidGlassProfile.clear`. In `dry` it contains a `DryLiquidGlass` with the clear profile. In `off` it is today's thumb. In every mode the diameter animates between `restingThumbSize` (14) and `activeThumbSize` (18). This is a deliberate deviation from the spec's "GlassSlider-style" knob: the scrubber's geometry and hit areas stay put. Under Reduce Transparency it is today's thumb.

- [ ] **Step 2: Run and confirm they fail**

- [ ] **Step 3: Implement both, branching on `OsdGlass.of`**

- [ ] **Step 4: Run every test under `player/test/presentation/widgets/video_controls/` and confirm they pass**

- [ ] **Step 5: Commit**

`feat(player): glass play disc and scrubber knob on the Liquid Glass OSD`

### Task 7: Lab scene, docs, on-device check

**Files:**
- Create: `player/tool/liquid_glass_lab/osd_scene.dart`
- Modify: `player/tool/liquid_glass_lab/main.dart` (scene switch near line 14 and 53), `player/scripts/glass-diff.sh` (its scene list), `player/docs/liquid-glass.md`, `player/scripts/glass-paths.sh` (add `osd_glass.dart` and `dry_liquid_glass.dart` if the directory glob does not already cover them)

- [ ] **Step 1: Add `LAB_SCENE=osd`**

The scene shows the top bar, the bottom bar with the scrubber, the touch transport and up next over two painted frames, one bright (near white) and one dark. Each appears twice, once in `OsdGlassScope(surfaceOutput: false)` (sampled) and once with `surfaceOutput: true` under a macOS platform override (dry).

- [ ] **Step 2: Run `./dev player glass-diff` and look at the `osd` side-by-side**

Tune `DryLiquidGlass`'s light and rim by eye until it reads as the same system as the sampled pills. Rerun the legibility tests after any token change.

- [ ] **Step 3: Update `docs/liquid-glass.md`**

- Replace the sentence at line 17 (the OSD never uses Liquid Glass).
- Add an "OSD" section: the three modes and their gate, the app-level host and why (sheets and dialogs are separate routes), the gradient-only scrim at 0.35, dry glass, and the clear scrubber knob kept at the thumb's size.
- Add the two new files to the piece table.

- [ ] **Step 4: Check on devices (manual; record results in the PR)**

- The spec's "one capsule per group" already holds: each bar's adjacent buttons already share one `osdPill` around a `Row` (`chrome_top_bar.dart`, `chrome_bottom_bar.dart`), and up next, skip segment (`GlassPill`) and the stats panel reach glass through Task 4 with no call-site change. Count the visible glass surfaces on a phone and record the number.
- iOS: play 4K HEVC on the oldest test iPhone with the OSD up, and check in DevTools that raster time stays under 16 ms. If it doesn't, return the touch transport's skip pills to `off` styling, per the spec.
- macOS: play on the HDR surface and confirm `dry`. Force the texture fallback and confirm `sampled`.
- On both: toggle Reduce Transparency and Increase Contrast mid-playback.
- Take screenshots of each.

- [ ] **Step 5: Glass-diff, then commit**

`docs(player): document the Liquid Glass OSD and add its lab scene`
