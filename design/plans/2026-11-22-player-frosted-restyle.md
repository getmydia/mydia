# Player Frosted Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stock Material 3 look of the player's Frosted mode with the quiet, hairline, transform-feedback design in the spec, without changing Liquid Glass or any TV navigation.

**Architecture:** A new `SurfaceRoles` theme extension carries the tokens. `AppTheme.build(liquid: false)` restyles every themeable Material widget at once. The existing seams (`GlassDialog`, `showGlassSheet`, `GlassButton`, `GlassChip`, `ToastPill`, `FocusEmphasis`) get designed Frosted branches. Three small house widgets (`PressScale`, `AppSegmented`, `AppSelect`) cover what the theme cannot.

**Tech Stack:** Flutter 3.50, `material_ui` (decoupled Material), Riverpod, flutter_test.

**Spec:** `design/specs/2026-11-22-player-frosted-restyle-design.md` (read it first; values below are copied from it). Background: `design/research/2026-11-22-modern-media-app-ui.md`.

## Global Constraints

- Every change is gated on Frosted: `GlassStyle.of(context) == false` in widgets, `liquid: false` in `AppTheme.build`. The Liquid path, `LiquidGeometry`, the shader and the lab are untouched.
- No new `BackdropFilter` anywhere.
- Focus stops, traversal order and press counts on TV stay exactly as on `master`.
- Tokens: `hairline` white 8%, `hairlineStrong` white 14%, `rim` white 6%, `hoverOverlay` white 4%, `pressOverlay` black 12%, `scrim` `#060607` at 62%, `radiusControl` 10, `radiusMenu` 14, `radiusModal` 20, checkbox radius 5.
- Motion: press 0.97 scale, 120 ms ease-out in / 160 ms out; focus scale 120 ms ease-out; sheet `Cubic(0.32, 0.72, 0, 1)` 450 ms; segmented thumb 160 ms; none of these animate under reduced motion (`ReducedMotion.of(context)` / `MediaQuery.disableAnimations`).
- No real movie or TV titles in tests or fixtures; invent them.
- No em dashes in code comments or docs.
- Run tests from the repo root: `./dev flutter test --concurrency=1 <paths>` (paths relative to `player/`, e.g. `test/core/theme/surface_roles_test.dart`).
- Commit with plain `git commit -F <msgfile>` from the worktree (hooks run). Stage every file of the task first (`git add <paths>`); after committing, `git status --porcelain` must be empty for the task's files, else `git add` + `git commit --amend --no-edit`. Verify with `git show --stat HEAD`.

## Review Focus

1. **Posters scaled 1.1× inside a horizontal rail get clipped** by the rail's `ListView` top/bottom. Expected: the whole focused poster and ring are visible. Test in Task 7.
2. **A destructive dialog opened from a remote must not put first focus on the destructive button**, even though Frosted draws it on top. Test in Task 8.
3. **Text scale 1.3+ (accessibility font size):** stacked dialog actions and `AppSegmented` labels must not overflow. Tests in Tasks 8 and 11.
4. **Every theme preset** (oledBlack, slate, macos, linux) gets readable hairlines and tokens, not just Projection Booth. Test in Task 1.
5. **`AppSelect` with a value missing from its items** (stale stored setting) must render a fallback label, not throw. Test in Task 12.

---

### Task 1: `SurfaceRoles` tokens, warmer Projection Booth, `material_ui` pin

**Files:**
- Create: `player/lib/core/theme/surface_roles.dart`
- Modify: `player/lib/core/theme/palette.dart` (`Palettes.projectionBooth`, lines ~147-167)
- Modify: `player/lib/core/theme/app_theme.dart` (`extensions:` list in `build`)
- Modify: `player/pubspec.yaml:113` (`material_ui: ^1.11.1` → `material_ui: 1.11.1`), then `./dev flutter pub get`
- Test: `player/test/core/theme/surface_roles_test.dart`, `player/test/core/theme/palette_test.dart`

**Interfaces:**
- Produces: `class SurfaceRoles extends ThemeExtension<SurfaceRoles>` with `final Color hairline, hairlineStrong, rim, hoverOverlay, pressOverlay, scrim; final double radiusControl, radiusMenu, radiusModal;`, `factory SurfaceRoles.fromPalette(MydiaPalette p)`, `copyWith`, `lerp`; `extension SurfaceRolesContext on BuildContext { SurfaceRoles get surfaceRoles; }` falling back to `SurfaceRoles.fromPalette(Palettes.projectionBooth)` when absent. Added to `extensions` in both modes.

- [ ] **Step 1: Write the failing tests**

`surface_roles_test.dart`:
- `fromPalette matches the spec tokens`: `hairline == Color(0x14FFFFFF)`, `hairlineStrong == Color(0x24FFFFFF)`, `rim == Color(0x0FFFFFFF)`, `hoverOverlay == Color(0x0AFFFFFF)`, `pressOverlay == Color(0x1F000000)`, `scrim == Color(0x9E060607)`, radii `10, 14, 20`.
- `every preset theme carries SurfaceRoles`: for each `ThemePreset.values` (macos with a sample accent, linux via `Palettes.linux(LinuxDesktop.gnome, null)`), `AppTheme.build(p, liquid: false).extension<SurfaceRoles>()` is non-null and `liquid: true` too.

`palette_test.dart`, new group `warm Projection Booth`:
- exact hexes from the spec table (`background` `0xFF0C0B0A` … `border` `0xFF2F2E2D`, `shimmerBase` `0xFF1B1A19`, `surfaceBright`/`cardHover`/`shimmerHighlight` `0xFF282726`).
- `steps strictly increase`: `computeLuminance()` of `background < surfaceDim < surfaceLow < surface < surfaceHigh < surfaceVariant < surfaceBright`.

- [ ] **Step 2: Run to verify failure**

Run: `./dev flutter test --concurrency=1 test/core/theme/surface_roles_test.dart test/core/theme/palette_test.dart`
Expected: FAIL (`surface_roles.dart` missing; hex mismatches).

- [ ] **Step 3: Implement** `SurfaceRoles` (every value is a constant today; `fromPalette` takes the palette so a preset can override later), add `SurfaceRoles.fromPalette(p)` to `extensions` in `AppTheme.build`, update the ten Projection Booth hexes, pin `material_ui`.

- [ ] **Step 4: Run** the two files plus `test/core/theme/theme_contrast_test.dart test/core/theme/app_theme_palette_test.dart`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(player): SurfaceRoles tokens and warmer Projection Booth greys`.

---

### Task 2: Frosted theme pass in `AppTheme.build`

**Files:**
- Modify: `player/lib/core/theme/app_theme.dart` (`build`, Frosted branches only)
- Test: `player/test/core/theme/app_theme_frosted_test.dart`

**Interfaces:**
- Consumes: `SurfaceRoles.fromPalette` (Task 1).
- Produces: `static const double AppTheme.primaryButtonHeight = 44`, `static const double AppTheme.secondaryButtonHeight = 40`. Theme values later tasks rely on: `popupMenuTheme` shape radius 14 with `hairline` side.

- [ ] **Step 1: Write the failing tests** (all on `final t = AppTheme.build(Palettes.projectionBooth, liquid: false)`, plus one Liquid guard):
- `no splash in Frosted`: `t.splashFactory == NoSplash.splashFactory`; same for `filledButtonTheme`, `elevatedButtonTheme`, `outlinedButtonTheme`, `textButtonTheme` `style!.splashFactory`.
- `overlay resolves hover and press`: `filledButtonTheme.style!.overlayColor!.resolve({WidgetState.hovered}) == Color(0x0AFFFFFF)`, `{pressed}` → `Color(0x1F000000)`, `{focused}` → `Colors.transparent`.
- `buttons use radiusControl`: each button style's shape resolves to `RoundedRectangleBorder` with `BorderRadius.circular(10)`; filled `minimumSize` height 44, outlined 40; outlined `side` color `Color(0x24FFFFFF)`.
- `switch colors`: `switchTheme.thumbColor.resolve({selected}) == Colors.white`, `trackColor.resolve({selected}) == palette.primary`, `trackColor.resolve({}) == palette.border`, `trackOutlineColor.resolve({}) == Colors.transparent`. (The 40×24 size cannot be themed; Task 5 adds `AppSwitch`. These colors keep any stray `Switch` consistent.)
- `checkbox radius 5`: `checkboxTheme.shape == RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))`, side color `Color(0x24FFFFFF)`.
- `menus and inputs`: `popupMenuTheme.color == palette.surfaceHigh`, shape radius 14 with side `Color(0x14FFFFFF)`; `inputDecorationTheme.fillColor == palette.surfaceLow`, enabled border radius 10 side `Color(0x14FFFFFF)`, focused side `palette.primary` width 1.5.
- `tooltip and card`: tooltip radius 8 with hairline; `cardTheme.shape` radius 14 with hairline side.
- `tabular figures`: `t.textTheme.bodyMedium!.fontFeatures` contains `FontFeature.tabularFigures()`; same for `labelLarge`.
- `Liquid unchanged`: `AppTheme.build(p, liquid: true).filledButtonTheme.style!.shape!.resolve({})` is `StadiumBorder` and its `splashFactory == NoSplash.splashFactory` (as today), `radiusButton` uses untouched.

- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/core/theme/app_theme_frosted_test.dart`. Expected: FAIL.

- [ ] **Step 3: Implement** in `build`: keep `liquid ? <today> : <frosted>` per property so the Liquid side is byte-identical. `withTvFocus` stays as is.

- [ ] **Step 4: Run** the new file plus `test/core/theme/` and `test/presentation/widgets/focus_emphasis_tv_test.dart test/presentation/widgets/focus_highlight_test.dart`. Expected: PASS. Fix only tests that pin a visual value the spec changes; list each in the commit body.

- [ ] **Step 5: Commit** `feat(player): Frosted theme pass (no ripple, hairlines, radius ladder)`.

---

### Task 3: Settings section eyebrow

**Files:**
- Modify: `player/lib/presentation/screens/settings/widgets/settings_section.dart` (the eyebrow `TextStyle`)
- Test: `player/test/presentation/screens/settings/settings_section_test.dart` (create if absent)

- [ ] **Step 1: Failing test** `eyebrow is 13/600 textSecondary without tracking`: pump `SettingsSection(label: 'Playback', children: [...])` under the Frosted theme; the `Text('Playback')` style has `fontSize 13`, `fontWeight w600`, `letterSpacing` null or 0, color `palette.textSecondary`; the string is rendered as given (no upper-casing).
- [ ] **Step 2: Run, expect FAIL. Step 3: Change the style. Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): quieter settings section labels`.

---

### Task 4: `PressScale`

**Files:**
- Create: `player/lib/presentation/widgets/controls/press_scale.dart`
- Test: `player/test/presentation/widgets/controls/press_scale_test.dart`

**Interfaces:**
- Produces: `class PressScale extends StatefulWidget { const PressScale({super.key, required Widget child, bool enabled = true}); static const double pressedScale = 0.97; static const scaleKey = ValueKey('press-scale'); }`. Listens with a `Listener` (pointer down/up/cancel) and a `Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent:)` that watches Select/Enter/Space/gameButtonA down and up without handling them (returns `KeyEventResult.ignored`). Adds no focus stop, no semantics.

- [ ] **Step 1: Failing tests**:
- `scales to 0.97 while a pointer is down`: `startGesture` on the child, `pump(200ms)`, the `Transform` under `scaleKey` has scale 0.97; `up()`, `pumpAndSettle`, scale 1.0.
- `scales while Select is held`: focus a `FocusableActionDetector` child, `sendKeyDownEvent(LogicalKeyboardKey.select)`, pump, scale 0.97; key up, settle, 1.0; and the child's `ActivateIntent` still fired once.
- `no animation under reduced motion`: with `MediaQuery(disableAnimations: true)`, scale stays 1.0 on press.
- `adds no focus stop`: a row of two buttons with one wrapped in `PressScale` has the same `FocusTraversalGroup` order and count as without.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement** with an `AnimationController` (120 ms forward `Curves.easeOut`, 160 ms reverse). **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): PressScale press feedback`.

---

### Task 5: `AppSwitch`

The spec's 40×24 switch with a sliding, non-resizing thumb is not expressible through `SwitchThemeData` (Material's track is fixed at 52×32). A small house control replaces `Switch` in Frosted mode; on Liquid it renders the existing `Switch` unchanged.

**Files:**
- Create: `player/lib/presentation/widgets/controls/app_switch.dart`
- Modify: every `Switch(` call site under `player/lib/` (6 files today; `grep -rln "Switch(" lib`), starting with `settings_row.dart`
- Test: `player/test/presentation/widgets/controls/app_switch_test.dart`, `player/test/presentation/widgets/controls/switch_call_sites_test.dart`

**Interfaces:**
- Consumes: `PressScale` (Task 4).
- Produces: `class AppSwitch extends StatelessWidget { const AppSwitch({super.key, required bool value, required ValueChanged<bool>? onChanged, FocusNode? focusNode, bool autofocus = false}); }`. Same constructor shape as `Switch` for the used parameters, so call sites change only the class name.

- [ ] **Step 1: Failing tests**:
- `Frosted draws a 40x24 track and 20 white thumb`: track `Container`/`DecoratedBox` size `Size(40, 24)` radius 12; on → track `palette.primary`, thumb at the right edge (`dx` offset 18); off → track `palette.border`, thumb at the left; thumb size `Size(20, 20)` in both.
- `hit target 48 high`: `tester.getSize(find.byType(AppSwitch)).height >= 48`.
- `tap and Select toggle`: tap → `onChanged(!value)`; focused + `LogicalKeyboardKey.select` → `onChanged(!value)` once.
- `disabled`: `onChanged: null` → no focus, dimmed (opacity 0.38), no callback.
- `semantics`: `toggled: value`, `enabled` mirrors `onChanged != null`.
- `reduced motion`: thumb moves without animation.
- `Liquid renders Switch`: under `liquid: true`, `find.byType(Switch)` finds one.
- Guard `no Switch( outside AppSwitch`: shape of `glass_dialog_call_sites_test.dart`, regex `\bSwitch\(`, allowlist `lib/presentation/widgets/controls/app_switch.dart`.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement** with `FocusableActionDetector` + `AnimatedAlign` (160 ms ease-out), then replace each call site.
- [ ] **Step 4: Run** the two new tests and `test/presentation/screens/settings/`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): compact AppSwitch for Frosted mode`.

---

### Task 6: Toast pill, Frosted fill

**Files:**
- Modify: `player/lib/presentation/widgets/toast/toast_pill.dart` (`fill` and the decoration on the non-Liquid path)
- Test: `player/test/presentation/widgets/toast/toast_pill_test.dart` (extend the existing file in that folder, or create)

- [ ] **Step 1: Failing test** `Frosted pill is opaque with a hairline and no blur`: under the Frosted theme, no `BackdropFilter` below `ToastPill`; its decorated container color is `palette.surfaceHigh` with alpha 1.0 and border `Color(0x14FFFFFF)`; `Semantics(liveRegion: true)` still present. Liquid case: tree unchanged from today (still uses its `GlassSurface` path).
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Run** the test plus `test/presentation/widgets/toast/` and `test/app_toast_layer_mounting_test.dart`, expect PASS.
- [ ] **Step 5: Commit** `feat(player): opaque hairline toast in Frosted mode`.

---

### Task 7: Focus size classes

**Files:**
- Modify: `player/lib/presentation/widgets/focus_emphasis.dart`
- Modify: `player/lib/presentation/widgets/focus_highlight.dart` (pass-through params)
- Modify: `player/lib/presentation/widgets/media_card.dart:141`, `player/lib/presentation/widgets/episode_rail_card.dart:75` (opt in)
- Modify: the rail(s) hosting `MediaCard`/`EpisodeRailCard` if Step 1's clipping test fails (add vertical padding equal to `height × 0.05` plus ring width plus gap, or `clipBehavior: Clip.none`)
- Test: `player/test/presentation/widgets/focus_emphasis_tv_test.dart` (extend), `player/test/presentation/widgets/media_card_focus_test.dart` (create)

**Interfaces:**
- Produces: `enum FocusSize { poster(1.1), tile(1.05), control(1.025); const FocusSize(this.scale); final double scale; }` in `focus_emphasis.dart`. `FocusEmphasis({..., FocusSize size = FocusSize.control, Color? glowColor})`; `FocusEmphasis.ringWidth` becomes 3; `FocusEmphasis.scale` is removed (callers use `size.scale`). `FocusHighlight({..., bool emphasis = false, FocusSize emphasisSize = FocusSize.control, Color? emphasisGlow})`.

- [ ] **Step 1: Failing tests** (TV tier forced the way `focus_emphasis_tv_test.dart` does today):
- `scale per size class`: focused `FocusEmphasis` with each `FocusSize` → `Transform` under `scaleKey` scale equals 1.1 / 1.05 / 1.025.
- `ring is 3 wide`; `no glow unless glowColor given`.
- `no scale when animations are disabled`: `MediaQuery(disableAnimations: true)` → scale 1.0, ring still painted.
- `MediaCard focused in a rail is not clipped` (Review Focus 1): pump a horizontal `ListView` of three `MediaCard`s with invented titles inside the real rail widget used on the home screen, focus the middle one, assert the ring's painted rect (`tester.getRect` of `FocusEmphasis.ringKey`) lies inside the rail's visible rect.
- `traversal unchanged`: D-pad right/left across the rail visits the same cards in the same order as before (compare to a list of keys).
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement**; `MediaCard` passes `emphasis: true, emphasisSize: FocusSize.poster, emphasisGlow: <its ambient tint if available, else null>`; `EpisodeRailCard` passes `FocusSize.tile`. Fix rail clipping only if the test shows it.
- [ ] **Step 4: Run** both test files plus `test/presentation/widgets/focus_highlight_test.dart` and `test/presentation/widgets/glass/glass_button_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): size-classed TV focus (1.1 poster, 1.05 tile, 1.025 control)`.

---

### Task 8: `GlassDialog` Frosted layout

**Files:**
- Modify: `player/lib/presentation/widgets/glass/glass_dialog.dart` (replace the `AlertDialog` branch; keep `_GlassDialogState`'s focus logic)
- Test: `player/test/presentation/widgets/glass/glass_dialog_test.dart` (extend)

**Interfaces:**
- Consumes: `SurfaceRoles` (Task 1), `PressScale` (Task 4), `AppTheme.primaryButtonHeight` (Task 2).
- Produces: unchanged public API. Internal: `static const double frostedMaxWidth = 340`, `frostedWideMaxWidth = 560`.

- [ ] **Step 1: Failing tests** (Frosted theme; actions passed as `[TextButton(key: cancelKey, ...), FilledButton(key: okKey, ...)]`):
- `centered card over the scrim`: a `ModalBarrier`/route barrier color `Color(0x9E060607)`; the dialog surface has radius 20, color `surfaceHigh`, hairline side; width ≤ 340 for short content.
- `actions stacked, primary on top`: `tester.getTopLeft(find.byKey(okKey)).dy < tester.getTopLeft(find.byKey(cancelKey)).dy`; both 44 high and the same width as the content.
- `default focus is the primary`: after first frame, `okKey`'s focus node has focus.
- `destructive keeps focus on cancel` (Review Focus 2): with `destructive: true`, the destructive action is on top and error-tinted (fill `AppColors.error` at 16%), but `cancelKey` has focus.
- `D-pad order follows the visual stack`: from the top action, arrow down reaches the bottom action; arrow up from the top action reaches the content (if focusable).
- `no overflow at text scale 1.3` (Review Focus 3): `MediaQuery(textScaler: TextScaler.linear(1.3))`, no exceptions, actions still stacked.
- `wide dialog with two short actions lays them in a row`: content forcing width > 420 → both actions share the same `dy`, end-aligned.
- `no AlertDialog and no splash in Frosted`: `find.byType(AlertDialog)` finds nothing; no `InkSplash`/`InkRipple` after tapping.
- `Liquid path unchanged`: under `liquid: true`, the existing glass-path expectations in this file still pass untouched.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement.** Reverse the caller's list for layout only; pick the default focus target by identity (caller's last, or first when `destructive`) instead of traversal position. Wrap each action in `PressScale`.
- [ ] **Step 4: Run** `test/presentation/widgets/glass/` and every test that opens a dialog (`grep -rl GlassDialog test`). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): Frosted dialog with stacked actions`.

---

### Task 9: `showGlassSheet` Frosted branch

**Files:**
- Modify: `player/lib/presentation/widgets/glass/glass_sheet.dart` (the `!liquid` branch)
- Test: `player/test/presentation/widgets/glass/glass_sheet_test.dart` (extend)

- [ ] **Step 1: Failing tests**: Frosted sheet has `surfaceHigh` fill, top radius 20, hairline top edge, a 36×4 handle colored `palette.border`; route `transitionDuration` 450 ms and its curve is `Cubic(0.32, 0.72, 0, 1)` (use `AnimationStyle(duration:, curve:)` on `showModalBottomSheet`, available in `material_ui` 1.11); with `MediaQuery(disableAnimations: true)` the sheet is fully visible after one `pump()`. Callers' `backgroundColor`/`shape` are ignored in Frosted (document in the dartdoc) so all sheets match.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Run** `test/presentation/widgets/glass/` and every test that opens a sheet (`grep -rl showGlassSheet test`). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): Frosted sheet styling and iOS-like motion`.

---

### Task 10: `GlassButton` and `GlassChip` Frosted branches

**Files:**
- Modify: `player/lib/presentation/widgets/glass/glass_button.dart` (Frosted branch), `player/lib/presentation/widgets/glass/glass_chip.dart` (Frosted branch)
- Test: `player/test/presentation/widgets/glass/glass_button_test.dart`, `glass_chip_test.dart` (extend)

- [ ] **Step 1: Failing tests**: `GlassButton` Frosted is 40 high by default (explicit `height` still wins), radius 10, fill white 7%, side `Color(0x24FFFFFF)`, wrapped in `PressScale` inside `FocusEmphasis(size: FocusSize.control)`. `GlassChip` Frosted is 30 high, radius 8, side `Color(0x24FFFFFF)`, label 12.5/500 `textPrimary`; selected → white fill, dark (`palette.background`) label; no gold anywhere in either.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Run** `test/presentation/widgets/glass/`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): hairline secondary button and outlined chip in Frosted mode`.

---

### Task 11: `AppSegmented` and the subtitle size row

**Files:**
- Create: `player/lib/presentation/widgets/controls/app_segmented.dart`
- Modify: `player/lib/presentation/screens/settings/widgets/subtitle_size_row.dart` (inline control instead of `showSubtitleSizePicker`)
- Modify: `player/lib/presentation/screens/filter/filter_editor_sheet.dart:210,260` (`SegmentedButton` → `AppSegmented`)
- Delete `showSubtitleSizePicker` (`player/lib/presentation/widgets/subtitle_size_picker.dart`) only if no other caller remains (`grep` it)
- Test: `player/test/presentation/widgets/controls/app_segmented_test.dart`, update `player/test/presentation/screens/settings/` tests that tap `subtitle-size-row`

**Interfaces:**
- Produces: `class AppSegmented<T> extends StatefulWidget { const AppSegmented({super.key, required List<AppSegment<T>> segments, required T selected, required ValueChanged<T> onChanged, String? semanticLabel}); }` and `class AppSegment<T> { const AppSegment({required this.value, required this.label}); final T value; final String label; }`. Asserts `2 <= segments.length <= 4`.

- [ ] **Step 1: Failing tests**:
- `renders track and selected thumb`: track fill `surfaceLow`, radius 11, padding 3, inset side `Color(0x24FFFFFF)`; selected segment fill `surfaceBright`; each segment hit area ≥ 44 high.
- `one focus stop; Left/Right change the selection`: focus it, `sendKeyEvent(arrowRight)` → `onChanged` with the next value; at the last segment arrowRight does nothing (no wrap) and focus does not leave the control; arrowDown leaves the control (normal traversal).
- `tap selects`; `Select key does nothing extra`.
- `semantics`: one `Semantics` group with `semanticLabel`, each segment `button: true`, the selected one `selected: true`.
- `reduced motion`: thumb jumps without animation.
- `text scale 1.3 does not overflow` (Review Focus 3) with labels `S`, `M`, `L`, `XL` and with two long localized-style labels.
- Settings: `subtitle size row shows S M L XL and saves on change`: tapping `L` writes `SubtitleSize.large` to `subtitleSizeSettingProvider`; no dialog opens.
- Filter sheet: existing filter editor tests pass with `AppSegmented` (update finders from `SegmentedButton` to `AppSegmented` only).
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement**; labels come from l10n (add ARB keys `subtitleSizeShortSmall` … `subtitleSizeShortExtraLarge` = `S`, `M`, `L`, `XL` in `app_en.arb` only; the other locales come through Weblate, per `player/docs/l10n.md`). The row becomes a `SettingsRow.action` with the control as `trailing`.
- [ ] **Step 4: Run** the new test, `test/presentation/screens/settings/`, `test/presentation/screens/filter/`, and the l10n checks from `player/docs/l10n.md`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): AppSegmented for short fixed choices`.

---

### Task 12: `AppSelect` and the `DropdownButton` guard

**Files:**
- Create: `player/lib/presentation/widgets/controls/app_select.dart`
- Modify (replace `DropdownButton`): `player/lib/presentation/screens/downloads/downloads_screen.dart`, `player/lib/presentation/screens/filter/filter_editor_sheet.dart`, `player/lib/presentation/screens/sources/files_library_kind_picker.dart`, `player/lib/presentation/screens/sources/add_s3_screen.dart`, `player/lib/presentation/widgets/smart_play_button.dart`
- Test: `player/test/presentation/widgets/controls/app_select_test.dart`, `player/test/presentation/widgets/controls/dropdown_call_sites_test.dart`

**Interfaces:**
- Produces: `class AppSelect<T> extends StatefulWidget { const AppSelect({super.key, required List<AppSelectItem<T>> items, required T? value, required ValueChanged<T> onChanged, String? placeholder, String? semanticLabel, bool enabled = true}); }`, `class AppSelectItem<T> { const AppSelectItem({required this.value, required this.label, this.icon}); final T value; final String label; final IconData? icon; }`. Opens `showMenu` anchored below the field (`popupPositionBelow` from `media_context_menu.dart`), current value checked.

- [ ] **Step 1: Failing tests**:
- `field look`: 40 high, fill `surfaceLow`, radius 10, side `Color(0x24FFFFFF)`, shows the current label and an up/down chevron.
- `opens the menu under the field with the value checked`; picking an item calls `onChanged` once and closes the menu.
- `D-pad`: one focus stop; Select opens; arrow keys move in the menu; Back (`LogicalKeyboardKey.goBack` and `escape`) closes it and focus returns to the field.
- `value missing from items` (Review Focus 5): renders `placeholder` (or empty) without throwing, and the menu opens with nothing checked.
- `disabled`: no focus, no menu, dimmed label.
- Guard `no DropdownButton outside AppSelect`: same shape as `glass_dialog_call_sites_test.dart`, regex `\bDropdownButton(\b|<|\()`, allowlist `lib/presentation/widgets/controls/app_select.dart`.
- Each replaced screen's existing tests pass after updating finders from `DropdownButton` to `AppSelect` (behaviour assertions unchanged).
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement** `AppSelect`, then replace the five call sites one at a time, keeping each site's values, labels and callbacks.
- [ ] **Step 4: Run** the two new tests and each replaced screen's test folder (`test/presentation/screens/downloads/`, `filter/`, `sources/`, and `test/presentation/widgets/smart_play_button*`). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): AppSelect replaces Material dropdowns`.

---

### Task 13: Whole-branch verification

**Files:** none new.

- [ ] **Step 1:** `./dev player test` (whole suite). Expected: all pass. If the harness kills a long run, run it in chunks per `test/README.md` notes and report each chunk.
- [ ] **Step 2:** `./dev flutter analyze`. Expected: no issues.
- [ ] **Step 3:** `./dev player glass-diff`. Expected: no Liquid Glass difference (the hook only requires it when Liquid files are staged; run it anyway once).
- [ ] **Step 4:** Manual TV walk on `./dev player android tv-run`, against the same walk on `master`: settings (change subtitle size), a show detail page (rail focus, poster scale not clipped), delete a download (destructive dialog: first focus on Cancel), a sheet, a select. Record the press count for each task; they must match `master`.
- [ ] **Step 5:** `git log --oneline origin/master..HEAD` shows the spec commit plus one commit per task; `git status --porcelain` is empty. Push with `git push -u origin HEAD:player/frosted-restyle`.
