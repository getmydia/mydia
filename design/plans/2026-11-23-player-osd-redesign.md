# Playback OSD Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating `ChromePanel` card with a scrim-backed,
full-width bottom bar, a left-aligned top bar and a touch-only centre
transport, with identical controls, behaviour and TV focus.

**Architecture:** Rework `PlaybackChrome` in place. New leaf widgets
(`ChromeScrim`, `ChromeBottomBar` + `ChromeMetrics`, `TouchTransport`,
`GlassSurface.osdPill`) are built and tested first, then swapped in by one
wiring task that deletes `chrome_panel.dart` and `center_play_button.dart`.
Focus wiring (`FocusMemoryRegion`s, `_osdPolicy`, `TvScrubber`) is moved, never
rewritten.

**Tech Stack:** Flutter (`material_ui`), `media_kit`, flutter_test.

**Spec:** `design/specs/2026-11-23-player-osd-redesign-design.md`

## Global Constraints

- Every path below is relative to `player/` unless it starts with `design/`.
- Single test file: `direnv exec . bash -c 'cd player && flutter test <path>'`.
  TV files add `--dart-define=MYDIA_FORCE_TV=true`.
- Whole suite: `./dev player test`. Analyzer: `./dev flutter analyze`.
- Commit from the worktree with plain `git commit -F <msgfile>` (direnv
  loaded), never `--no-verify`. Check `git show --stat HEAD` after each.
- Same controls per tier as `master`; skips stay ±10 s; title stays one string.
- No `BackdropFilter` in the top bar, bottom bar or touch cluster.
- `GlassSurface.osd` is unchanged (dialogs, sheets, stats panel, Up Next use it).
- Scrim plateau colour: `DepthTokens.osdTint` at `DepthTokens.osdFillOpacity`.
- Breakpoints: `Breakpoints.mobile` 600, `Breakpoints.tablet` 900.
- No em dashes in comments or docs. No real movie or TV titles in tests.
- Any widget test whose golden is `@TestOn('mac-os')` is regenerated on the
  Mac (`cd player && flutter test --update-goldens <path>`), see
  `player/docs/workflow.md`.

## Review Focus

1. **Touch tablet, ≥600 px, episode with neighbours:** previous and next
   episode remain reachable (today they are in the in-bar transport). Pinned
   in Task 4.
2. **TV, OSD revealed by a scrub from hidden, then UP:** lands on play/pause in
   the bottom row, not on a top-bar control or nothing. Pinned by the existing
   `playback_chrome_scrub_tv_test`, run unchanged in Task 6.
3. **Long title on a 320 px phone with cast and scaling:** the top bar
   ellipsizes without overflow and keeps back tappable. Pinned in Task 5.
4. **Subtitles while the OSD is up:** captions sit above the new, taller bar,
   not under it. Pinned in Task 6.
5. **Skip Intro / Up Next while the OSD is up on a 600 px window:** the corner
   widget does not overlap the bar. Pinned in Task 3.

---

### Task 1: OSD pill material and scrim

**Files:**
- Modify: `lib/presentation/widgets/glass_surface.dart` (new constructor after `GlassSurface.osd`)
- Create: `lib/presentation/widgets/video_controls/chrome_scrim.dart`
- Test: `test/presentation/widgets/video_controls/chrome_scrim_test.dart`
- Modify: `test/presentation/widgets/video_controls/video_controls_glass_test.dart` (add an `osdPill` group; leave the `ChromePanel` group for Task 6)

**Interfaces:**
- Produces: `GlassSurface.osdPill({Key? key, BorderRadius? borderRadius, Widget? child})`: `blurSigma: DepthTokens.blurNone`, `live: false`, fill `osdTint` at `osdFillOpacity`, `Border.all(color: DepthTokens.osdHairline, width: DepthTokens.rimWidth)`, radius default `BorderRadius.all(Radius.circular(DepthTokens.radiusOsdPill))`, `shadows: OsdElevation.pill.shadows`.
- Produces: `class ChromeScrim extends StatelessWidget { const ChromeScrim({super.key, required double topHeight, required double bottomHeight}); static const double fadeExtent = 96; static const Key topKey; static const Key bottomKey; }`. Paints two `Positioned` bands with `IgnorePointer`: both gradients run `Alignment.topCenter` → `Alignment.bottomCenter`. Top band: height `topHeight + fadeExtent`, colours `[plateau, plateau, transparent]`, stops `[0, topHeight / (topHeight + fadeExtent), 1]`. Bottom band: height `bottomHeight + fadeExtent`, colours `[transparent, plateau, plateau]`, stops `[0, fadeExtent / (bottomHeight + fadeExtent), 1]`. `plateau = DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity)`.

- [ ] **Step 1: Write failing tests**

`chrome_scrim_test.dart`:
- `'bands are plateau-coloured behind each bar and transparent beyond'`: pump `ChromeScrim(topHeight: 60, bottomHeight: 120)` in an 800×450 box; find the `DecoratedBox` under `ChromeScrim.bottomKey`; its `LinearGradient.colors` equal `[transparent, plateau, plateau]` and its rect height is `120 + ChromeScrim.fadeExtent`, bottom-anchored. Same for top.
- `'ignores pointers'`: a `GestureDetector` under the scrim still receives a tap at the centre and at (10, 440).

`video_controls_glass_test.dart`, group `'GlassSurface.osdPill'`:
- `'paints no BackdropFilter'`: `find.descendant(of: find.byType(GlassSurface), matching: find.byType(BackdropFilter))` finds nothing, under both `GlassStyle` values the file already pumps.
- `'uses the OSD fill and hairline'`: decoration colour equals `DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity)`, border colour `DepthTokens.osdHairline`.

- [ ] **Step 2: Run both files, expect compile failure** (`osdPill`, `ChromeScrim` undefined).
- [ ] **Step 3: Implement `GlassSurface.osdPill` and `ChromeScrim` per Interfaces.**
- [ ] **Step 4: Run both files, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): add an unblurred OSD pill material and the chrome scrim`.

### Task 2: Scrubber styling

**Files:**
- Modify: `lib/presentation/widgets/video_controls/video_progress_bar.dart` (played colour, thumb constants, track/buffer alphas)
- Test: `test/presentation/widgets/video_controls/video_progress_bar_test.dart`

**Interfaces:**
- Produces: `VideoProgressBar.restingThumbSize = 14.0`, `VideoProgressBar.activeThumbSize = 18.0`. Played fill `context.palette.primary` (Projection Booth `#E9A23B`). Track white `0.22`, buffered white `0.42`. Track height 4 at rest (keep the existing emphasised height).

- [ ] **Step 1: Update/add tests**: `'played fill uses the palette primary'` (colour of the played layer's `DecoratedBox` equals `Palettes.projectionBooth.primary` under the test theme); `'thumb is 14 at rest and 18 when focused'` via `tester.getSize(find.byKey(ProgressBarSurface.thumbKey))`; `'buffered layer is white at 0.42'`. Update any existing assertion pinning 12/16 or white played.
- [ ] **Step 2: Run, expect FAIL** on colour and size.
- [ ] **Step 3: Change the constants and colours.** Keep `bufferedKey`, `thumbKey`, gestures and the scrub cursor untouched.
- [ ] **Step 4: Run `video_progress_bar_test.dart`, `video_progress_bar_seek_real_test.dart`, `scrub_bubble_test.dart`, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): gold played track and larger scrubber thumb`.

### Task 3: `ChromeMetrics` and `ChromeBottomBar`

**Files:**
- Create: `lib/presentation/widgets/video_controls/chrome_bottom_bar.dart`
- Test: `test/presentation/widgets/video_controls/chrome_bottom_bar_test.dart`, `chrome_bottom_bar_overflow_test.dart`

`ChromePanel`/`PanelMetrics` stay in place until Task 6; the two coexist for
three commits.

**Interfaces:**
- Produces:
  ```dart
  @immutable
  class ChromeMetrics {
    final bool showVolume, touchTargets, compactTransport, showQuality, showAlwaysOnTop;
    final double secondaryGap, horizontalPadding;
    double get barHeight;          // = ChromeBottomBar.heightFor(touchTargets: touchTargets)
    double get cornerInsetBottom;  // = barHeight + cornerGap
    static const double cornerInsetRight = 24.0;
    static const double cornerGap = 12.0;
    factory ChromeMetrics.resolve({required double width, required bool touchPrimary});
    @visibleForTesting factory ChromeMetrics.forWidth(double width);
  }
  ```
  Tier flags copy `PanelMetrics.resolve` exactly (same `width` thresholds and
  values for `showVolume`, `touchTargets`, `compactTransport`, `showQuality`,
  `showAlwaysOnTop`, `secondaryGap`), except `horizontalPadding`: 24 from
  `Breakpoints.mobile` up, 16 below.
- Produces:
  ```dart
  class ChromeBottomBar extends StatelessWidget {
    const ChromeBottomBar({super.key, required ChromeMetrics metrics,
      required Widget timecodes, required Widget scrubber,
      required Widget secondary, Widget? transport, Widget? volume});
    static const double verticalPadding = 12, timecodeHeight = 24,
      timecodeGap = 4, rowGap = 8, controlRowHeight = 44;
    static double heightFor({required bool touchTargets});
    static const Key secondaryPillKey = Key('osd-secondary-pill');
  }
  ```
  Layout: `Padding(h: metrics.horizontalPadding, v: verticalPadding)` →
  `Column(min)`: `SizedBox(height: timecodeHeight, child: timecodes)`,
  `timecodeGap`, scrubber in `SizedBox(height: touchTargets ? 44 : 32)` (the
  heights `ProgressBarSurface` uses), `rowGap`, `SizedBox(height:
  controlRowHeight, child: Row(Expanded(left: volume slot), transport ??
  SizedBox.shrink(), Expanded(right: GlassSurface.osdPill(key:
  secondaryPillKey, child: secondary))))`. The volume slot keeps
  `ChromePanel._volumeSlot`'s `Visibility(visible: metrics.showVolume,
  maintainState: true)`. `heightFor` is the sum of those constants, so it
  cannot drift from the layout. Remote timecodes (18 px) fit in 24.

- [ ] **Step 1: Write failing tests**
  - `chrome_bottom_bar_test.dart`:
    - `'rendered height equals ChromeMetrics.barHeight'` at widths 320, 600,
      1280 for `touchTargets` true and false.
    - `'transport is centred on the bar'`: `getRect(transport).center.dx`
      equals `getRect(bar).center.dx` within 0.5, with volume present and
      absent.
    - `'secondary sits in an osdPill'`: `find.descendant(of:
      find.byKey(ChromeBottomBar.secondaryPillKey), matching:
      find.byWidget(secondary))` finds one.
    - `'volume state survives a showVolume flip'`: port the existing
      `ChromePanel` test of `_lastVolume` (from `chrome_panel_test.dart`).
    - `'corner widget clears the bar at 600 px'` (Review Focus 5): in a
      600×400 `Stack`, place the bar bottom-anchored and a 48 px-tall box at
      `bottom: metrics.cornerInsetBottom, right: ChromeMetrics.cornerInsetRight`;
      the rects do not intersect.
    - `ChromeMetrics.resolve` table test: at 320/599/600/899/900/1600 the tier
      flags equal `PanelMetrics.resolve` at the same width, and
      `horizontalPadding` is 16/16/24/24/24/24.
  - `chrome_bottom_bar_overflow_test.dart`: port `chrome_panel_overflow_test.dart`
    to the bar using the real `TransportCluster`/`VolumeCluster`/`SecondaryCluster`
    it uses, at 320, 599, 600, 899, 900, 1280, 1920; `tester.takeException()`
    is null at each.
- [ ] **Step 2: Run both, expect compile failure.**
- [ ] **Step 3: Implement `ChromeMetrics` and `ChromeBottomBar` per Interfaces.**
- [ ] **Step 4: Run both, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): add the full-width OSD bottom bar`.

### Task 4: `TouchTransport` and the touch-tier test seam

**Files:**
- Modify: `lib/core/player/input_capabilities.dart`
- Create: `lib/presentation/widgets/video_controls/touch_transport.dart`
- Test: `test/presentation/widgets/video_controls/touch_transport_test.dart`, `test/core/player/input_capabilities_test.dart`
- Modify: `test/presentation/widgets/video_controls/osd_legibility_test.dart` (replace the `CenterPlayButton` case)

**Interfaces:**
- Produces: `@visibleForTesting static bool? debugTouchPrimaryOverride;` on `InputCapabilities`; `touchPrimary` returns it when non-null. Tests reset it in `tearDown`.
- Produces:
  ```dart
  class TouchTransport extends StatelessWidget {
    const TouchTransport({super.key, required Player player,
      required VoidCallback onBack10, required VoidCallback onForward10,
      VoidCallback? onPreviousEpisode, VoidCallback? onNextEpisode,
      bool showEpisodeNav = false, FocusNode? playPauseFocusNode});
    static const double playSize = 68, seekSize = 48, episodeSize = 40, gap = 28;
    static const Color playFill = Color(0xF2F0EFED); // white-ish @ 0.95
    static const Color playGlyph = Color(0xFF0B0B0C);
  }
  ```
  Row: [previous] −10 play +10 [next]; episode buttons only when
  `showEpisodeNav` and their callback is non-null. Reuses the
  `TransportSurface` keys (`playPauseKey`, `back10Key`, `forward10Key`,
  `previousEpisodeKey`, `nextEpisodeKey`) so existing key lookups work on every
  tier. Seek and episode discs are `GlassSurface.osdPill` with full radius;
  the play disc is a filled circle with a `BoxShadow(color: 0x73000000,
  blurRadius: 30, offset: Offset(0, 10))`. Seek and episode buttons are a `ControlButton` (size = disc size, icon 24)
  inside their disc; the play disc is its own `Semantics(button: true)` +
  `Tooltip` + `GestureDetector`. All of them wrap `PressScale`, with the same tooltips as
  `TransportSurface` (`commonPlay`/`commonPause`, `videoRewind10`,
  `videoForward10`, `videoPreviousEpisode`, `videoNextEpisode`). Play/pause
  listens to `player.stream.playing` like `TransportCluster`.

- [ ] **Step 1: Write failing tests**
  - `input_capabilities_test.dart`: `'debugTouchPrimaryOverride wins'`.
  - `touch_transport_test.dart`:
    - `'shows −10, play, +10 and no episode buttons by default'`.
    - `'shows previous and next when showEpisodeNav and callbacks are set'`
      (Review Focus 1), and taps each to call its callback.
    - `'play toggles the player'` with the file's fake player.
    - `'contains no BackdropFilter'`.
  - `osd_legibility_test.dart`: delete the `CenterPlayButton glyph` test; add
    `'touch play glyph clears 4.5:1 on its disc'`:
    `contrastRatio(TouchTransport.playGlyph, compositeOver(TouchTransport.playFill, Colors.white)) >= 4.5`.
    Keep the import of `center_play_button.dart` until Task 6 deletes it only
    if other cases use it; otherwise drop it here.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement the override and `TouchTransport`.**
- [ ] **Step 4: Run the three files, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): add the touch centre transport`.

### Task 5: Top bar layout

**Files:**
- Modify: `lib/presentation/widgets/video_controls/chrome_top_bar.dart`
- Test: `test/presentation/widgets/video_controls/chrome_top_bar_test.dart`

**Interfaces:**
- Consumes: `GlassSurface.osdPill` (Task 1).
- Produces: unchanged `ChromeTopBar` constructor and keys (`backKey`,
  `titleKey`, `castKey`, `scalingKey`). New `static const Key actionsPillKey =
  Key('osd-top-actions')`. `GlassPill` now builds on `GlassSurface.osdPill`
  instead of `GlassSurface.osd`. Layout: `Row`: back (`GlassPill`, icon only:
  `chevron_left_rounded`, tooltip and semantics `context.l10n.commonBack`;
  the visible "Back" text goes), 12 px gap, `Expanded` title `Text` (15/w600,
  `Color(0xD9FFFFFF)`, one line, ellipsis, left-aligned, keyed `titleKey`, no
  pill), 12 px gap, then one `GlassSurface.osdPill` keyed `actionsPillKey`
  holding scaling and cast `ControlButton`s (44 px, icon 19) when either is
  present. Drop `wideBreakpoint`, `narrowSideFlex`, `narrowTitleFlex`.

- [ ] **Step 1: Rewrite the centring tests** (the title is no longer centred)
  to: `'title starts right after back'` (`getRect(titleKey).left -
  getRect(backKey).right == 12`); `'title starts at the left edge on TV'`
  (`showBack: false`); `'cast and scaling share one pill'` (both descend from
  `actionsPillKey`); `'long title ellipsizes at 320 px with cast and
  scaling'` (Review Focus 3: no exception, back still hit-testable,
  `Text.overflow == TextOverflow.ellipsis`); `'top bar contains no
  BackdropFilter'`. Keep the existing tap and key tests.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement the layout.**
- [ ] **Step 4: Run `chrome_top_bar_test.dart` and `cast_chrome_icon_test.dart`, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): left-align the OSD title and group its actions`.

### Task 6: Wire the new chrome into `PlaybackChrome` and remove the panel

**Files:**
- Modify: `lib/presentation/widgets/video_controls/playback_chrome.dart` (`build` at ~847-1110, `_ScrubberRow` at ~1118)
- Modify: `skip_segment_button.dart`, `up_next_prompt.dart`, `panel_controls.dart` (doc comments), `lib/presentation/screens/player/player_screen.dart:6388`, `player_screen_views.dart:153`, `player_key_bindings.dart:320` (comment), `lib/core/player/platform_features.dart:57` (comment), `lib/core/playback/stats/stats_metrics.dart`
- Delete: `chrome_panel.dart`, `center_play_button.dart`, `test/.../chrome_panel_test.dart`, `chrome_panel_overflow_test.dart`, `chrome_corner_inset_test.dart` (its cases move to `chrome_bottom_bar_test.dart`), `chrome_panel_golden_test.dart` and its goldens
- Create: `test/presentation/widgets/video_controls/chrome_bottom_bar_golden_test.dart` (`@TestOn('mac-os')`, same harness as the deleted panel golden)
- Modify tests: `video_controls_glass_test.dart`, `playback_chrome_test.dart`, `playback_chrome_inset_test.dart`, `playback_chrome_episode_nav_test.dart`, `skip_segment_button_test.dart`, `up_next_prompt_test.dart`, `stats_panel_test.dart`, `chrome_subtitle_lift_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: `_ScrubberRow` splits into `_Timecodes` (the two `Text`s with
  `PlaybackChrome.elapsedKey`/`remainingKey`, same styles, `spaceBetween`) and
  the scrubber (`_bar()` unchanged, including the `osd-scrubber`
  `FocusMemoryRegion` and `TvScrubber`). Both go into `ChromeBottomBar`.

Composition in `build` (replacing the `CenterPlayButton` `Center` and the
`Positioned` panel):
- `ChromeScrim(topHeight: <top bar slot height>, bottomHeight:
  metrics.barHeight + MediaQuery.paddingOf(context).bottom)` as the first child
  of the `ChromeVisibility` stack, wrapped in `ChromeSlide(hiddenOffsetY: 0)`
  so it fades with the chrome. Use the top bar's existing height constant
  from `PlayerTopBarSlot`; if none exists, add `PlayerTopBarSlot.height` and
  use it in both places.
- Touch tier: `Center(child: TouchTransport(..., showEpisodeNav:
  !metrics.compactTransport, playPauseFocusNode: widget.playPauseFocusNode))`
  and `ChromeBottomBar(transport: null, ...)`.
- Pointer and remote: `ChromeBottomBar(transport: TransportCluster(...same
  arguments as today...))`.
- The bar is `Positioned(left: 0, right: 0, bottom: 0)` inside the existing
  `SafeArea`, wrapped exactly as the panel is today:
  `ChromeSubtitleLift` → `ChromeSlide(hiddenOffsetY: 8)` →
  `ChromeToastObstruction` → `FocusMemoryRegion('osd-controls',
  initialId: TransportSurface.playPauseKey)`. The `_subtitleReference` box is
  the bar's.
- `volume`, `secondary` arguments are unchanged from today's `ChromePanel`
  call.
- Rename every `PanelMetrics` to `ChromeMetrics` (`cornerInsetRight`,
  `cornerInsetBottom`, `resolve`, `forWidth` keep their names).

- [ ] **Step 1: Update tests first**
  - `playback_chrome_test.dart`: `'touch tier shows TouchTransport and no
    transport in the bar'` (set `InputCapabilities.debugTouchPrimaryOverride
    = true`; `find.byType(TouchTransport)` one; `find.descendant(of:
    find.byType(ChromeBottomBar), matching: find.byType(TransportCluster))`
    none); `'pointer tier has no TouchTransport'`; `'scrim fades with the
    chrome'` (hide via the visibility controller, pump past the fade, the
    scrim's `Opacity`/`FadeTransition` ancestor is 0); `'no BackdropFilter
    in the top bar, bottom bar or touch cluster'`.
  - `chrome_subtitle_lift_test.dart` (or `playback_chrome_inset_test.dart`,
    whichever builds a full `PlaybackChrome`): `'captions clear the bottom
    bar'` (Review Focus 4): the lifted subtitle box's bottom is at or above
    `getRect(find.byType(ChromeBottomBar)).top` while the chrome is shown.
  - `playback_chrome_inset_test.dart`: replace the panel's `bottomOffset`
    expectations with the bar sitting on the safe-area bottom
    (`getRect(bar).bottom == screenHeight - bottomPadding`).
  - `playback_chrome_episode_nav_test.dart`: build `ChromeBottomBar` instead
    of `ChromePanel`; same assertions.
  - `video_controls_glass_test.dart`: delete the `ChromePanel OSD material`
    group (the pill group from Task 1 replaces it).
  - Mechanical rename in `skip_segment_button_test.dart`,
    `up_next_prompt_test.dart`, `stats_panel_test.dart`.
- [ ] **Step 2: Run the touched files, expect FAIL** (types missing, layout old).
- [ ] **Step 3: Implement the wiring, the rename and the deletions.** `grep -rn "PanelMetrics\|ChromePanel\|CenterPlayButton" lib test` returns nothing afterwards.
- [ ] **Step 4: Run the touched files, expect PASS.**
- [ ] **Step 5: Run the unchanged TV contract with `--dart-define=MYDIA_FORCE_TV=true`:** `test/presentation/screens/player/player_osd_focus_tv_test.dart`, `test/presentation/widgets/video_controls/playback_chrome_tv_test.dart`, `playback_chrome_scrub_tv_test.dart` (Review Focus 2), `tv_scrubber_test.dart`. Expected: PASS with no edits to these files. A failure here is a wiring bug, not a test to update.
- [ ] **Step 6: Add the bar golden** (`chrome_bottom_bar_golden_test.dart`, 1280 and 390 widths) and generate its images on the Mac.
- [ ] **Step 7: Commit** `feat(player): float the OSD over a scrim with a full-width bottom bar`.

### Task 7: Verify and open the PR

**Files:** none new.

- [ ] **Step 1:** `./dev flutter analyze`: no issues.
- [ ] **Step 2:** `./dev player test`: all pass (re-run any known-flaky file alone per `player/docs/workflow.md`).
- [ ] **Step 3:** every `*_tv_test.dart` under `--dart-define=MYDIA_FORCE_TV=true`: all pass.
- [ ] **Step 4:** `./dev player glass-diff`: 0 px.
- [ ] **Step 5: Manual.** Android TV emulator (`./dev player android tv-run`): reveal, play/pause, scrub, audio, subtitles, back; count presses for each against `master` and record both in the PR. Phone landscape (touch cluster, episode nav on a tablet width). Desktop windowed and fullscreen (window drag and double-click still work).
- [ ] **Step 6:** Before-and-after screenshots for TV, phone and desktop.
- [ ] **Step 7:** Push with `git push -u origin HEAD:player/osd-redesign`, open the PR (not draft) with spec, plan, test counts, press-count table and screenshots.
