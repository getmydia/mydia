# Apple-style OSD Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the playback title into a two-line block above the scrubber, turn back into a disc, replace the scrim band with one eased curve, and hide the scrubber thumb at rest.

**Architecture:** A new `ChromeTitleBlock` becomes the first row of both bottom bars, with a fixed per-tier height that `ChromeMetrics.barHeight` includes. The player screen resolves a `PlaybackTitle` from the route string and, once loaded, from `PlaybackDetail`. `ChromeScrim` computes its gradient from one pure function so tests can read alpha at any height.

**Tech Stack:** Flutter (player app), Riverpod, flutter_test, ARB localization.

**Spec:** `design/specs/2026-11-26-player-osd-apple-polish-design.md`. Reference: `design/research/2026-11-26-apple-player-osd-layout.md`.

## Global Constraints

- Work in `player/`. Run tests from the repo root: `./dev flutter test --concurrency=1 <paths>` (paths relative to `player/`). TV tests add `--dart-define=MYDIA_FORCE_TV=true`.
- New worktree: run `./dev player setup` once before anything else.
- Every `*_tv_test.dart` passes **unmodified**. Do not edit one to make it pass.
- No control is added, removed or reordered; focus regions and their order do not change.
- `ChromeTitleBlock` holds no `Focus`, no gesture handler, no `BackdropFilter`, no glass, no text shadow.
- Legibility thresholds are fixed: 4.5:1 for the small line, 3:1 for the title, over a pure-white frame. A failure is fixed in `DepthTokens.osdTitleScrimOpacity`, never in a threshold.
- Titles in tests and the lab are invented ("The Lantern Coast", "Low Tide"). Never a real film or show.
- All user-visible text goes through ARB messages (`player/docs/l10n.md`); add each new message to every `app_*.arb`.
- No em dashes in comments, docs or commit messages. No AI attribution in commits.
- Stage every intended path before `git commit`, run one commit per shell command, and check `git show --stat HEAD` after each (root `CLAUDE.md`, Git Guidelines).
- Glass files (`chrome_scrim.dart`, `depth_tokens.dart`, the lab) need `./dev player glass-diff` before their commit; the pre-commit hook enforces it.

## Review Focus

1. **A title far wider than the bar** (a 120-character filename at 320 px): it ellipsizes on one line and the bar's height is unchanged. Task 2 and Task 3.
2. **Detail arrives late, partially, or never** (offline download, source that knows no show title): the route string stays as a single-line title and nothing shifts when the small line appears. Task 1 and Task 3.
3. **An episode with numbers but no name, or a name but no numbers** (specials, files matched by path): the small line shows what it has and never renders "S, E" with a blank. Task 1.
4. **A 350 px tall landscape phone over a white frame:** the title still clears 3:1 and the small line 4.5:1 with the short fade. Task 4.
5. **Reduce Motion and a read-only progress bar** (no `onSeekTo`): the thumb never appears on the read-only bar, and the rest/active change is instant under Reduce Motion. Task 5.

---

### Task 1: `PlaybackTitle` and the detail fields behind it

**Files:**
- Create: `player/lib/presentation/widgets/video_controls/playback_title.dart`
- Modify: `player/lib/presentation/screens/player/session/playback_session_types.dart` (`PlaybackDetail`)
- Modify: `player/lib/presentation/screens/player/session/mydia_playback_session.dart` (`detail()`, ~line 346)
- Modify: `player/lib/presentation/screens/player/session/source_playback_session.dart` (`detail()`, ~line 175)
- Modify: `player/lib/l10n/app_*.arb` (all six)
- Test: `player/test/presentation/widgets/video_controls/playback_title_test.dart`, plus the existing session tests for each `detail()`

**Interfaces:**
- Produces:
  - `PlaybackDetail` gains `final String? showTitle; final int? episodeNumber; final String? episodeTitle; final int? year;` (named, optional, default null).
  - `@immutable class PlaybackTitle { const PlaybackTitle({required this.title, this.kicker}); final String title; final String? kicker; }` with `==`/`hashCode`.
  - `PlaybackTitle.resolve({required String routeTitle, required bool isEpisode, PlaybackDetail? detail, required AppLocalizations l10n})`.
  - ARB message `playerEpisodeCode`: `"S{season}, E{episode}"`, int placeholders.

- [ ] **Step 1: Write the failing tests** in `playback_title_test.dart` (use `lookupAppLocalizations(const Locale('en'))`):

| Case | Input | Expected |
| --- | --- | --- |
| no detail | `routeTitle: 'The Lantern Coast S2E4'` | `title` = route string, `kicker` null |
| episode, all parts | showTitle 'The Lantern Coast', season 2, episode 4, episodeTitle 'Low Tide' | title 'The Lantern Coast', kicker 'S2, E4 · Low Tide' |
| episode, no name | same without `episodeTitle` (null or blank) | kicker 'S2, E4' |
| episode, name but a number missing | `episodeNumber: null` | kicker 'Low Tide' |
| episode, no show title | `showTitle: null` | title = route string, kicker null |
| movie with year | `isEpisode: false, year: 2024` | title = route string, kicker '2024' |
| movie, no year | | kicker null |
| blank show title | `showTitle: '  '` | treated as null |

- [ ] **Step 2: Run** `./dev flutter test --concurrency=1 test/presentation/widgets/video_controls/playback_title_test.dart`. Expected: FAIL, `PlaybackTitle` undefined.

- [ ] **Step 3: Add the ARB message** to every `app_*.arb` (English text in all; translators follow up), with an `@playerEpisodeCode` description and two `int` placeholders. Regenerate with the command `player/docs/l10n.md` gives.

- [ ] **Step 4: Add the four fields to `PlaybackDetail`** and implement `PlaybackTitle.resolve`. The separator is `' · '`. `seasonNumber` comes from the detail's existing field.

- [ ] **Step 5: Fill the fields in both sessions.** Mydia: `episode.$show?.title`, `episode.episodeNumber`, `episode.title`, `movie.year` (all already selected by `episode_detail.graphql` and `movie_detail.graphql`). Source: `detail.summary.showTitle`, `.index`, `.title`, `.year`; set the episode fields only when `item.kind == ItemKind.episode`. Add one assertion per new field to each session's existing `detail()` test.

- [ ] **Step 6: Run** the new test and the two session test files. Expected: PASS.

- [ ] **Step 7: Commit** `feat(player): resolve a two-line playback title from the detail`.

---

### Task 2: `ChromeTitleBlock`

**Files:**
- Create: `player/lib/presentation/widgets/video_controls/chrome_title_block.dart`
- Test: `player/test/presentation/widgets/video_controls/chrome_title_block_test.dart`

**Interfaces:**
- Produces:
  - `enum ChromeTitleTier { pointer, compact, remote }`
  - `class ChromeTitleBlock extends StatelessWidget { const ChromeTitleBlock({super.key, required this.title, this.kicker, required this.tier}); }`
  - `static double heightFor(ChromeTitleTier tier)`: pointer 46, compact 34, remote 62.
  - `static double gapFor(ChromeTitleTier tier)`: 6, compact 4. (The gap below the block; the bar adds it.)
  - `static const Key kickerKey = Key('chrome-title-kicker');` The title `Text` is keyed `ChromeTopBar.titleKey`.
  - `static const double kickerOpacity = 0.78;` and `static double kickerFontSize(tier)` / `titleFontSize(tier)` returning the spec's table (13/22, 11/15, 18/30), for the legibility test.

- [ ] **Step 1: Write the failing tests:**
  - renders title and kicker text with the two keys;
  - with `kicker: null`, `kickerKey` finds nothing and `tester.getSize(find.byType(ChromeTitleBlock)).height` equals `heightFor(tier)` (run for all three tiers, with and without a kicker);
  - title bottom edge equals the block's bottom edge;
  - at 320 px wide with a 120-character title and kicker: no overflow exception, each `Text` has `maxLines: 1` and `TextOverflow.ellipsis`, height still `heightFor(tier)`;
  - text scale 2.0: height is still `heightFor(tier)` and nothing overflows (wrap the block's text in `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3)` and size the lines with `FittedBox(fit: BoxFit.scaleDown, alignment: bottomLeft)` inside fixed-height boxes);
  - `find.descendant(of: block, matching: find.byType(Focus))` and `GestureDetector` find nothing; the block is wrapped in `IgnorePointer`.

- [ ] **Step 2: Run** the test file. Expected: FAIL, `ChromeTitleBlock` undefined.

- [ ] **Step 3: Implement.** A `SizedBox(height: heightFor(tier))` holding a start-aligned column: a fixed-height kicker box (18 / 14 / 24 px) that is empty when there is no kicker, then the title box (28 / 20 / 38). Styles: kicker w500, `Colors.white` at `kickerOpacity`; title w700, white at 0.95, `letterSpacing: -0.01 * fontSize`. No shadows.

- [ ] **Step 4: Run** the test file. Expected: PASS.

- [ ] **Step 5: Commit** `feat(player): add the OSD title block`.

---

### Task 3: Bottom bars carry the title block

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/chrome_bottom_bar.dart`
- Modify: `player/lib/presentation/widgets/video_controls/playback_chrome.dart` (bar construction ~1120-1170; constructor ~728-836)
- Modify: `player/lib/presentation/widgets/video_controls/custom_video_controls.dart` (`playbackChromeBuilder`)
- Test: `chrome_bottom_bar_test.dart`, `chrome_bottom_bar_overflow_test.dart`, `playback_chrome_test.dart`, `playback_chrome_inset_test.dart`, `chrome_subtitle_lift_test.dart` (all under `player/test/presentation/widgets/video_controls/`)

**Interfaces:**
- Consumes: `ChromeTitleBlock`, `ChromeTitleTier`, `heightFor`, `gapFor` (Task 2).
- Produces:
  - `ChromeMetrics` gains `final bool remote` (default false) and `ChromeMetrics.resolve` gains `bool remote = false`; getter `ChromeTitleTier get titleTier` (`compactTouch` → compact, `remote` → remote, else pointer).
  - `ChromeBottomBar` and `CompactChromeBottomBar` gain `final Widget? title`, drawn first, followed by `ChromeTitleBlock.gapFor(metrics.titleTier)`.
  - `ChromeBottomBar.heightFor({required bool touchTargets, bool compactTouch = false, ChromeTitleTier titleTier = ChromeTitleTier.pointer})` always includes the block and its gap, whether or not `title` is passed. `CompactChromeBottomBar.height` becomes 94 (6 + 34 + 4 + 44 + 6).
  - `ChromeMetrics.titleBlockExtent`: block height plus gap, for the scrim (Task 4).
  - `PlaybackChrome` and `playbackChromeBuilder` gain `String? kicker`. `title` stays `String?`.

- [ ] **Step 1: Write the failing tests:**
  - `chrome_bottom_bar_test`: for pointer, touch tablet, remote (`controlsFirst`) and compact, the rendered bar height equals `metrics.barHeight`, with and without a `title` widget; the title block's left edge equals the elapsed timecode's left edge; on the remote tier the vertical order is title, control row, timeline; on pointer it is title, timeline, control row.
  - `chrome_bottom_bar_overflow_test`: add a 120-character title at each existing width (320, 599, 600, 899, 900, 1280, 1920); no overflow.
  - `playback_chrome_test`: `PlaybackChrome(title: 'The Lantern Coast', kicker: 'S2, E4 · Low Tide')` renders one `ChromeTopBar.titleKey` inside the bottom bar's `FocusMemoryRegion`; changing `kicker` from null to a value leaves the bar's rect unchanged.
  - `playback_chrome_inset_test`: Skip Intro and Up Next rects sit above the taller bar on every tier.
  - `chrome_subtitle_lift_test`: the lift reference is still the bar's box, so the lift grows by exactly `titleBlockExtent`.

- [ ] **Step 2: Run** those five files. Expected: FAIL on the new cases.

- [ ] **Step 3: Implement** the bar changes, then in `PlaybackChrome` resolve metrics with `remote:` and pass `title: widget.title == null ? null : ChromeTitleBlock(title: …, kicker: widget.kicker, tier: metrics.titleTier)` to both bars. Leave `ChromeTopBar(title: widget.title, …)` as it is for now (Task 6 removes it); expect two title keys until then and scope the `playback_chrome_test` finder to the bottom bar.

- [ ] **Step 4: Run** the five files, then every TV test: `./dev flutter test --concurrency=1 --dart-define=MYDIA_FORCE_TV=true $(cd player && git ls-files 'test/**/*_tv_test.dart')`. `playback_chrome_tv_test` line 105 (`findsOneWidget` on `titleKey`) fails here because two exist; that is expected until Task 6. Every other TV test: PASS.

- [ ] **Step 5: Commit** `feat(player): put the title block at the top of the OSD bottom bar`.

---

### Task 4: One-curve scrim and title legibility

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/chrome_scrim.dart`
- Modify: `player/lib/core/theme/depth_tokens.dart`
- Modify: `player/lib/presentation/widgets/video_controls/playback_chrome.dart` (~1047)
- Test: `chrome_scrim_test.dart`, `osd_legibility_test.dart` (video_controls), `player/test/presentation/widgets/glass/liquid_glass_legibility_test.dart`

**Interfaces:**
- Consumes: `ChromeMetrics.titleBlockExtent`, `ChromeTitleBlock.kickerOpacity` and font sizes.
- Produces:
  - `DepthTokens.osdTitleScrimOpacity = 0.60`.
  - `const ChromeScrim({super.key, required this.bottomHeight, this.titleHeight = 0})`. `bottomHeight` is now the plateau: the bar height **minus** `titleBlockExtent`, plus the bottom safe inset.
  - `ChromeScrim.maxFadeExtent = 160`.
  - `static double extentAbovePlateau({required double height, required double titleHeight})` = `max(titleHeight + fadeExtentFor(height), titleHeight / titleEaseFraction)`, and just `fadeExtentFor(height)` when `titleHeight == 0`.
  - `static double get titleEaseFraction`: the `t` at which `1 - Curves.easeInOut.transform(t)` equals `osdTitleScrimOpacity / osdFillOpacity`, found by bisection (40 iterations).
  - `static double alphaAt(double fromBottom, {required double plateau, required double titleHeight, required double height})`: `osdFillOpacity` up to `plateau`, then `osdFillOpacity * (1 - easeInOut(t))` with `t = (fromBottom - plateau) / extentAbovePlateau`, 0 beyond. The gradient's stops are sampled from this function (keep `fadeSteps`, raise it to 16).

- [ ] **Step 1: Write the failing tests:**
  - `chrome_scrim_test`: `alphaAt` is non-increasing sampled every 2 px from 0 to the full height; equals `osdFillOpacity` at 0 and at `plateau`; is `>= osdTitleScrimOpacity` at `plateau + titleHeight` for (height 1080, title 52), (height 800, title 52), (height 350, title 38) and (height 2160, title 68); is 0 at the top of the extent; with `titleHeight: 0` reproduces today's band (plateau, then `fadeExtentFor`). The painted gradient's colours match `alphaAt` at each stop.
  - `osd_legibility_test`: over a white frame composited with `osdTint` at `alphaAt(plateau + titleHeight)`, white at 0.95 clears 3:1 and white at `kickerOpacity` clears 4.5:1 at the kicker's own top edge (it sits at the block's top). Run for the pointer, compact (height 350) and remote tiers.
  - `liquid_glass_legibility_test`: the same two ratios in the `sampled` and `dry` modes across the grey sweep 0 to 1 in steps of 0.05. The title is bare text on the scrim in every mode, so the cases reuse the scrim alpha, not a glass profile.

- [ ] **Step 2: Run** the three files. Expected: FAIL (`alphaAt` undefined).

- [ ] **Step 3: Implement** the token, the functions and the gradient; pass `bottomHeight: metrics.barHeight - metrics.titleBlockExtent + safeBottom` and `titleHeight: metrics.titleBlockExtent` from `PlaybackChrome` (0 when `widget.title == null`).

- [ ] **Step 4: Run** the three files. If a legibility case fails, raise `osdTitleScrimOpacity` in steps of 0.02 until it passes and record the final value in the token's doc comment with the ratio it yields. Expected: PASS.

- [ ] **Step 5: Run** `./dev player glass-diff` and keep its output for the PR.

- [ ] **Step 6: Commit** `feat(player): ease the OSD scrim through the title block`.

---

### Task 5: Scrubber thumb on interaction

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/video_progress_bar.dart` (`_trackHeight`, `_thumbSize` ~85-92; fills ~160-215; thumb ~245-270)
- Test: `player/test/presentation/widgets/video_controls/video_progress_bar_test.dart`

**Interfaces:**
- Produces: `VideoProgressBar.restingTrackHeight = 4.0`, `activeTrackHeight = 6.0`; `restingThumbSize` becomes `0.0`; `activeThumbSize` stays 18 on focus and becomes 14 on hover or drag via a new `static const double pointerThumbSize = 14.0`. `thumbKey` stays mounted.

- [ ] **Step 1: Write the failing tests:**
  - at rest (seekable, not hovered, not focused) the thumb's size is `Size.zero` and the track is 4 px;
  - hover (mouse pointer enters): after `pumpAndSettle` the thumb is 14 px and the track 6 px;
  - during a horizontal drag: 14 px and 6 px; back to rest after the drag ends and the pointer leaves;
  - `focused: true`: thumb 18 px, track 6 px (`tv_scrubber_test` and `playback_chrome_scrub_tv_test` must pass unmodified; if one asserts an 8 px track, keep 8 px for `focused` only and note it in the spec);
  - read-only bar (no `onSeekTo`): thumb stays zero under hover;
  - `MediaQuery(disableAnimations: true)`: one `pump()` after hover already shows 14 px;
  - at rest the played fill's right corners are square (`BorderRadius.horizontal(left: …)`); when emphasized they are round;
  - the played fill's colour is still `palette.primary`.

- [ ] **Step 2: Run** the test file. Expected: FAIL on the rest-state cases.

- [ ] **Step 3: Implement.** Thumb size and track height animate with `DepthTokens.motionFast` (`Duration.zero` when `MediaQuery.disableAnimationsOf(context)`); fade the thumb's opacity with its size so it does not pop. Keep the existing "derive `left` from the tweened size" structure, which is what prevents the lateral wobble its comment describes.

- [ ] **Step 4: Run** the file plus `tv_scrubber_test.dart`, `playback_chrome_scrub_tv_test.dart` (with the TV define), `scrub_bubble_test.dart`, `video_progress_bar_seek_real_test.dart`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(player): show the scrubber thumb only on interaction`.

---

### Task 6: Top bar: back disc, no title

**Files:**
- Modify: `player/lib/presentation/widgets/video_controls/chrome_top_bar.dart`
- Modify: `player/lib/presentation/widgets/video_controls/playback_chrome.dart` (~1186)
- Test: `chrome_top_bar_test.dart`, `osd_pill_text_roles_test.dart`, `playback_chrome_test.dart`

**Interfaces:**
- Produces: `ChromeTopBar` loses `title`, `titlePillKey`, `titleInset`, `titleGap`, `_titlePill`. `titleKey` **stays** as a constant (the title block and `playback_chrome_tv_test` use it). New `static const Key backDiscKey = Key('osd-top-back')` on the disc's `GlassSurface.osdPill`; `backKey` stays on the tap target. New `static double sideFor({required bool compact}) => compact ? 36 : 40`. `GlassPill.defaultHeight` is unchanged (Up Next uses it).

- [ ] **Step 1: Rewrite `chrome_top_bar_test`:**
  - no `Text` descendant in the top bar;
  - the back disc is a square of `sideFor(compact)` (40 and 36) with a circular `GlassSurface.osdPill`; tapping it calls `onBack`; with `onBack: null` it renders and is inert; `showBack: false` renders no disc;
  - the actions capsule is `sideFor` tall with 20 px glyphs off the phone, 19 px on it;
  - `ChromeTopBar(showBack: false)` with no cast or scaling paints nothing (the remote tier);
  - at 280 px wide with the phone's trailing capsule: no overflow (the existing `FittedBox` path);
  - semantics: one button labelled Back.
  Update `osd_pill_text_roles_test` if it reads the title pill.

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement,** and drop `title:` from `PlaybackChrome`'s `ChromeTopBar(...)`. `player_screen.dart:6331` passes no title and needs no change.

- [ ] **Step 4: Run** the three files and every TV test (command in Task 3). `playback_chrome_tv_test` line 105 now passes. Expected: all PASS, no TV test edited.

- [ ] **Step 5: Commit** `feat(player): replace the OSD title pill with a back disc`.

---

### Task 7: Player screen resolves the title

**Files:**
- Modify: `player/lib/presentation/screens/player/player_screen.dart` (`_fetchDetail` ~3570; the `playbackChromeBuilder` call, which passes `title: widget.title`, ~6380)
- Test: the player screen widget test that already scripts a detail (find it with `grep -rln "seasonEpisodes\|PlaybackDetail(" player/test/presentation/screens/player`); add a case there

**Interfaces:**
- Consumes: `PlaybackTitle.resolve` (Task 1), `PlaybackChrome.kicker` (Task 3).
- Produces: state field `PlaybackTitle? _osdTitle`.

- [ ] **Step 1: Write the failing test:** play an episode whose route title is 'The Lantern Coast S2E4' and whose scripted detail has show title 'The Lantern Coast', season 2, episode 4, title 'Low Tide'. After the detail resolves, the chrome shows title 'The Lantern Coast' and `ChromeTitleBlock.kickerKey` text 'S2, E4 · Low Tide'. A second case with a detail of `null`: the route string, no kicker.

- [ ] **Step 2: Run.** Expected: FAIL.

- [ ] **Step 3: Implement.** In `_fetchDetail`, after the existing assignments and inside the same `_isCurrentLoad(gen)` guard, `setState` `_osdTitle = PlaybackTitle.resolve(routeTitle: widget.title ?? l10n.playerUntitled, isEpisode: widget.mediaType == 'episode', detail: detail, l10n: …)`. Pass `title: _osdTitle?.title ?? widget.title` and `kicker: _osdTitle?.kicker` to the chrome builder. Clear `_osdTitle` wherever the screen starts a new load for a different item. Leave the window title, media session and cast metadata on `widget.title`.

- [ ] **Step 4: Run** the test file. Expected: PASS.

- [ ] **Step 5: Commit** `feat(player): show the show name and episode line in the OSD`.

---

### Task 8: Lab scene, golden, docs, full verification

**Files:**
- Modify: `player/tool/liquid_glass_lab/osd_scene.dart` (top bar ~166, scrim ~121)
- Modify: `player/test/presentation/widgets/video_controls/chrome_bottom_bar_golden_test.dart` and its golden
- Modify: `player/docs/liquid-glass.md` (OSD section), `player/docs/playback.md` if it describes the title pill
- Modify: `design/specs/2026-11-26-player-osd-apple-polish-design.md` (status line; any value Task 4 or 5 changed)

- [ ] **Step 1:** Update the lab's `osd` scene to the new top bar (back disc, actions capsule), the title block ('The Lantern Coast', 'S2, E4 · Low Tide') and `ChromeScrim.alphaAt`. Build the scrim from `ChromeScrim` itself where the scene allows, so the lab cannot drift from the widget.
- [ ] **Step 2:** Add the title block to the golden test's bar and regenerate: `cd player && flutter test --update-goldens test/presentation/widgets/video_controls/chrome_bottom_bar_golden_test.dart` (inside the devenv shell). Open the PNG and check it against frame C of the mockup.
- [ ] **Step 3:** Update the docs: the top bar description, the scrim's one-curve profile and `osdTitleScrimOpacity`.
- [ ] **Step 4:** `./dev player glass-diff`. Save the `osd` side-by-side for the PR.
- [ ] **Step 5:** `./dev flutter analyze`. Expected: no issues.
- [ ] **Step 6:** `./dev player test`, then every TV test with the define. Expected: all PASS. `git diff origin/master --stat -- 'player/test/**/*_tv_test.dart'` prints nothing.
- [ ] **Step 7:** Set the spec's status to "implemented" and commit `docs(player): describe the OSD title block and eased scrim`.
- [ ] **Step 8: Manual checks** (report each as done or not done, never assumed): Android TV emulator (`./dev player android tv-run`), counting presses for reveal, play/pause, scrub, audio, subtitles and back against `master`; a phone in landscape with subtitles on; desktop windowed and fullscreen; iOS and the macOS HDR surface with Liquid Glass on.
- [ ] **Step 9:** Before the PR, check `origin/worktree-player-native-liquid-glass` for edits to `chrome_top_bar.dart`, and run Repowise `get_risk` with `changed_files` from `git diff --name-only origin/master...` if the server is authorized.
