# TV D-pad Focus Rule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the TV tier, every D-pad move that enters a row, grid, button bar or list lands on that region's remembered item (by item identity), else its first item, so DOWN-then-UP always round-trips.

**Architecture:** Flutter's directional mixin keeps choosing *which region* a press goes to (geometry is fine at that granularity), but every move it makes goes through the policy's `requestFocusCallback`. We install one callback, `FocusMemory.requestFocus`, that rewrites the target: if the chosen node sits in a `FocusMemoryRegion` other than the one focus is leaving, it focuses that region's remembered `FocusMemoryItem` instead. Regions and items are marker widgets that record focus as it happens. The callback is installed in two places only: the shell's content region policy (`app_shell.dart`) and the player OSD's traversal group. Shared widgets (`HorizontalRail`, `BrowseGrid`) carry regions and items, so most screens get the rule by passing an item id.

**Tech Stack:** Flutter (`focus_traversal.dart` directional mixin), flutter_test widget tests under `--dart-define=MYDIA_FORCE_TV=true`.

**Spec:** `design/specs/2026-11-05-tv-dpad-focus-rule-design.md`

## Global Constraints

- TV tier only: every new widget returns its child untouched when `InputCapabilities.directionalPrimary` is false; the non-TV widget tree and Tab order must be unchanged.
- Do not change `RegionTraversalPolicy`'s exit logic or the content/rail `FocusScopeNode` configuration (`directionalTraversalEdgeBehavior` stays `stop`; see the comment on `_region` in `app_shell.dart`).
- Memory is keyed by item identity (`Object id`), with nearest-surviving-index then first item as fallback.
- A node inside a `PopupRoute` is never redirected out of it.
- TV tests are files named `*_tv_test.dart` (CI's "Run television-tier tests" step globs `test/**/*_tv_test.dart` and runs them with `MYDIA_FORCE_TV=true`); each must skip itself when `directionalPrimary` is false, following `test/presentation/widgets/tv_sidebar_traversal_tv_test.dart`.
- Run Flutter through `./dev flutter ...` from the repo root. TV test command form: `./dev flutter test --dart-define=MYDIA_FORCE_TV=true <files>`.
- Never real movie/TV titles in tests or fixtures; invent them.
- No em dashes in comments or docs.

## Review Focus

1. **Remembered item scrolled out of the build cache** (a rail scrolled far right, then the list rebuilt): the remembered id is not registered. Expect fallback to the registered item with nearest index, scrolled into view, never a dead press. Test in Task 1.
2. **Flutter's own up/down history** (`_pushPolicyData`/`_popPolicyDataIfNeeded` in the directional mixin) replays a previous node through the same callback; the redirect must not fight it (UP-DOWN-UP across three rows ends where expected). Test in Task 1.
3. **Row emptied while remembered** (Continue Watching cleared, list reloads to zero items): entering must skip to the next region rather than crash or stick. Test in Task 1.
4. **Back from a detail page to Home**: home rows keep their memory because the shell page stays mounted. Test in Task 3.
5. **A sheet or menu opened from a row** (`showModalBottomSheet` on the shell navigator sits inside the content scope): moves inside it must not be redirected to a row behind it. Test in Task 1.

---

## File Structure

- Create `player/lib/core/focus/focus_memory.dart`: `FocusMemoryRegion`, `FocusMemoryItem`, `FocusMemoryEntry`, `FocusMemory.requestFocus`. One responsibility: remembering and redirecting.
- Modify `player/lib/presentation/widgets/app_shell.dart` (`_region`): pass the callback into `RegionTraversalPolicy`.
- Modify `player/lib/presentation/widgets/horizontal_rail.dart`, `browse_grid.dart`: optional `itemId`.
- Modify screens/widgets that build their own horizontal lists or bars (Tasks 3-6).
- Fix stale `ContentRail` mentions in `rail_focus_scroller.dart` and `horizontal_rail.dart` (Task 2).
- Doc: `player/docs/tv-focus.md` (Task 1), linked from `player/CLAUDE.md`'s docs list if one exists.

---

### Task 1: Focus memory core

**Files:**
- Create: `player/lib/core/focus/focus_memory.dart`
- Create: `player/docs/tv-focus.md`
- Test: `player/test/core/focus/focus_memory_tv_test.dart`, `player/test/core/focus/focus_memory_test.dart` (non-TV passthrough)

**Interfaces:**
- Produces:
  - `enum FocusMemoryEntry { first, firstVisible }`
  - `class FocusMemoryRegion extends StatefulWidget { const FocusMemoryRegion({Key? key, required Widget child, FocusMemoryEntry entry = FocusMemoryEntry.first, String? debugLabel}); }`
  - `class FocusMemoryItem extends StatefulWidget { const FocusMemoryItem({Key? key, required Object id, required int index, required Widget child}); }`
  - `abstract final class FocusMemory { static void requestFocus(FocusNode node, {ScrollPositionAlignmentPolicy? alignmentPolicy, double? alignment, Duration? duration, Curve? curve}); }` matching `TraversalRequestFocusCallback`.

Behavior to implement:
- `FocusMemoryItem` wraps its child in `Focus(canRequestFocus: false, skipTraversal: true)`; on gaining focus (descendant focused) it tells its nearest ancestor region `remember(id, index)`. It registers with that region in `initState`/`didUpdateWidget` and unregisters in `dispose`. Its focus target is the first of its `Focus` node's `traversalDescendants`.
- `FocusMemoryRegion` keeps `Object? rememberedId`, `int? rememberedIndex`, and a registry `id -> item state`. `resolveTarget()` returns: the remembered item's target if registered; else the registered item whose index is nearest `rememberedIndex`; else per `entry`: `first` = lowest registered index, `firstVisible` = lowest index whose target `rect` overlaps the view's bounds (fall back to `first`). Returns null when nothing is registered.
- `FocusMemory.requestFocus(node, ...)`: let `from = FocusManager.instance.primaryFocus`. Find `node`'s nearest region and `from`'s nearest region (via `context.findAncestorStateOfType`). If `node`'s region is null, or is the same as `from`'s, or `node` is inside a `PopupRoute` (same check as `RegionTraversalPolicy._isInsidePopupRoute`; extract it to a shared top-level `bool isInsidePopupRoute(FocusNode)` in `focus_memory.dart` and have `RegionTraversalPolicy` call it), focus `node`. Otherwise focus `region.resolveTarget() ?? node`. Either way, delegate to `FocusTraversalPolicy.defaultTraversalRequestFocusCallback` with the same alignment arguments so scrolling behavior is unchanged.
- Both widgets return `child` unchanged when `!InputCapabilities.directionalPrimary`; `FocusMemory.requestFocus` then just delegates.

- [ ] **Step 1: Write the failing TV tests** in `focus_memory_tv_test.dart`. Harness: a `FocusTraversalGroup(policy: ReadingOrderTraversalPolicy(requestFocusCallback: FocusMemory.requestFocus))` around a `Column` of three `FocusMemoryRegion`s, each a horizontal `ListView` of 12 fixed-width focusable cards wrapped in `FocusMemoryItem(id: 'r$row-c$i', index: i)`, at 1920x1080. Helper `String focused()` returns `primaryFocus.debugLabel`. Tests:
  - `down then up returns to the starting card when rows are scrolled differently`: focus `r0-c4`, jump row 1's controller to 900, DOWN, UP → `focused() == 'r0-c4'`.
  - `entering a never-visited row lands on its first item`: focus `r0-c4`, DOWN → `'r1-c0'`.
  - `entering a visited row lands on its remembered item`: focus `r1-c6`, UP, RIGHT, DOWN → `'r1-c6'`.
  - `remembered item that moved is followed by id`: focus `r1-c6`, UP; rebuild row 1 with `r1-c6` moved to index 0; DOWN → `'r1-c6'`.
  - `removed item falls back to the nearest surviving index`: focus `r1-c6`, UP; rebuild row 1 without `r1-c6`; DOWN → `'r1-c7'` (now at index 6).
  - `remembered item outside the build cache falls back by index` (Review Focus 1): rows with `cacheExtent: 0`, focus `r1-c10`, UP, jump row 1 to 0 so c10 is unbuilt, DOWN → a `r1-c*` card is focused and visible on screen.
  - `up down up across three rows` (Review Focus 2): focus `r2-c3` after visiting `r1-c5`; UP → `'r1-c5'`, UP → `'r0-c0'`, DOWN → `'r1-c5'`, DOWN → `'r2-c3'`.
  - `an emptied row is skipped` (Review Focus 3): remember `r1-c2`, rebuild row 1 with zero items, focus `r0-c0`, DOWN → `focused()` starts with `'r2-'`.
  - `moves inside a bottom sheet are not redirected` (Review Focus 5): open `showModalBottomSheet` from a card with two focusable rows wrapped in no regions; UP/DOWN inside stay inside the sheet.
  - `firstVisible entry picks the first on-screen item`: a vertical list region with `entry: FocusMemoryEntry.firstVisible`, scrolled so items 0-3 are off-screen; entering lands on item 4.
- [ ] **Step 2: Write the non-TV passthrough test** in `focus_memory_test.dart`: with the default (non-forced) build, `FocusMemoryRegion` and `FocusMemoryItem` add no `Focus` widgets (`find.byType(Focus)` count equals a tree built without them).
- [ ] **Step 3: Run to verify failure**: `./dev flutter test --dart-define=MYDIA_FORCE_TV=true test/core/focus/focus_memory_tv_test.dart`. Expected: compile failure (`focus_memory.dart` missing).
- [ ] **Step 4: Implement `focus_memory.dart`** as specified above, and move the popup check to `isInsidePopupRoute`, used by `RegionTraversalPolicy`.
- [ ] **Step 5: Run** the TV file, `test/core/focus/focus_memory_test.dart`, and `test/core/focus/region_traversal_policy_test.dart` (both plain and with the define). Expected: all PASS.
- [ ] **Step 6: Write `player/docs/tv-focus.md`**: the rule in five lines (from the spec), how to opt a widget in (`FocusMemoryRegion` + `FocusMemoryItem` with a stable id, or `itemId:` on `HorizontalRail`/`BrowseGrid`), where the callback is installed, and how to run TV tests.
- [ ] **Step 7: Commit** `feat(player): remember each TV row's focused item and redirect entry to it`.

### Task 2: Install the rule in the shell and the shared widgets

**Files:**
- Modify: `player/lib/presentation/widgets/app_shell.dart` (`_region`, ~line 707)
- Modify: `player/lib/presentation/widgets/horizontal_rail.dart`, `player/lib/presentation/widgets/browse_grid.dart`, `player/lib/presentation/widgets/rail_focus_scroller.dart` (stale `ContentRail` comment)
- Test: `player/test/presentation/widgets/horizontal_rail_focus_tv_test.dart`, `player/test/presentation/widgets/browse_grid_focus_tv_test.dart`; extend `player/test/presentation/widgets/tv_sidebar_traversal_tv_test.dart`

**Interfaces:**
- Consumes: Task 1's `FocusMemoryRegion`, `FocusMemoryItem`, `FocusMemory.requestFocus`.
- Produces:
  - `HorizontalRail({..., Object Function(int index)? itemId})`: wraps the list in `FocusMemoryRegion` and each built item in `FocusMemoryItem(id: itemId?.call(index) ?? index, index: index)`.
  - `BrowseGrid({..., Object Function(int index)? itemId})`: same, with the region around the whole grid.
  - `_region` builds `RegionTraversalPolicy(onExit: onExit, requestFocusCallback: FocusMemory.requestFocus)`.

- [ ] **Step 1: Write failing tests.**
  - `horizontal_rail_focus_tv_test.dart`: two `HorizontalRail`s inside a `FocusTraversalGroup(policy: RegionTraversalPolicy(requestFocusCallback: FocusMemory.requestFocus))` + `FocusScope`; focus rail A index 5, scroll rail B to its end, DOWN, UP → rail A index 5. Also: `itemId` supplied, reorder rail A so the remembered id moves, re-enter → same id.
  - `browse_grid_focus_tv_test.dart`: a filter-chip row region above a `BrowseGrid` of 30 items (6 columns at 1920 width). DOWN from chip 0 → grid item 0; RIGHT x2, DOWN → item 8 (column straight); UP x2 → chip row (its remembered chip 0); DOWN → item 2.
  - `tv_sidebar_traversal_tv_test.dart`: add `RIGHT from the sidebar returns to the remembered card after rows were re-scrolled`, using the real `SidebarFocusBoundary` and the content region built with the new callback.
- [ ] **Step 2: Run**: `./dev flutter test --dart-define=MYDIA_FORCE_TV=true` on the three files. Expected: the new tests FAIL (no `itemId` param, no memory).
- [ ] **Step 3: Implement** the `itemId` params, the wrapping, and the `_region` callback. If the sidebar RIGHT test fails beyond the callback change, fix it at the `onExit`/`SidebarFocusBoundary` seam only (spec: no restructuring of `RegionTraversalPolicy`). Replace the `ContentRail` mentions with the rails that exist.
- [ ] **Step 4: Run** the three files plus every existing `*_tv_test.dart` (`git ls-files 'test/**/*_tv_test.dart'`) with the define, and `./dev flutter test test/presentation/widgets` plain. Expected: all PASS.
- [ ] **Step 5: Commit** `feat(player): apply TV row memory to the shell, rails and browse grid`.

### Task 3: Home and browse screens

**Files:**
- Modify: `player/lib/presentation/screens/sources/source_poster_row.dart` (pass `itemId: (i) => items[i].ref`), every `BrowseGrid(` caller (pass `itemId` from the item's `ref`), `player/lib/presentation/screens/collections/collection_detail_screen.dart` (`_buildGridView`: wrap in region/items by hand, it does not use `BrowseGrid`), and the horizontal `ListView`s in `all_servers_grid_screen.dart`, `all_servers_listing_screen.dart`, `source_library_screen.dart`, `source_search_screen.dart` (wrap each in `FocusMemoryRegion`, items in `FocusMemoryItem` keyed by the item's `ref`; chip/filter bars keyed by their value).
- Test: `player/test/presentation/screens/home/home_screen_focus_tv_test.dart`, `player/test/presentation/screens/sources/source_library_focus_tv_test.dart`, `player/test/presentation/screens/all_servers/all_servers_focus_tv_test.dart`, `player/test/presentation/screens/collections/collection_detail_focus_tv_test.dart`

**Interfaces:**
- Consumes: Task 2's `itemId` params; Task 1's widgets. `ItemSummary.ref` is the item identity (check it implements `==`/`hashCode`; if not, use its string form).

- [ ] **Step 1: Write failing screen tests**, reusing each screen's existing test harness/fakes (`home_screen_test.dart`, `source_library_screen_test.dart`, `all_servers_*_test.dart`, `collection_detail_screen_layout_test.dart`) at 1920x1080. Full set per screen with rows or grids:
  - first entry into a row/grid lands on its first item;
  - DOWN then UP round-trips with the destination row scrolled to a different offset;
  - re-entering a visited row lands on its remembered item;
  - LEFT from a row's first item reaches the rail, RIGHT returns (home only; others rely on Task 2's shell test);
  - home: Continue Watching reorders (remembered title moved to front), re-entry lands on the same title;
  - home (Review Focus 4): remember a card, push a detail route over the shell, pop, DOWN/UP → still remembered.
- [ ] **Step 2: Run** with the define. Expected: FAIL.
- [ ] **Step 3: Implement** the wiring listed under Files.
- [ ] **Step 4: Run** the new files and the existing tests in those screen folders (plain and with the define). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): remember focus across Home and browse screens on TV`.

### Task 4: Detail pages

**Files:**
- Modify: the movie/show/episode detail hero button bar (find via `detail_hero`; wrap in `FocusMemoryRegion`, each button in `FocusMemoryItem(id: '<action name>')`), `player/lib/presentation/screens/show/show_season_section.dart` (season selector and episode list), `player/lib/presentation/widgets/episode_rail.dart` (pass `itemId`), `player/lib/presentation/widgets/cast_rail.dart`, `player/lib/presentation/screens/detail/detail_similar_rail.dart`.
- Test: `player/test/presentation/screens/detail/detail_focus_tv_test.dart` (use `detail_harness.dart`), `player/test/presentation/screens/show/show_focus_tv_test.dart`

**Interfaces:**
- Consumes: Tasks 1-2.

- [ ] **Step 1: Write failing tests**:
  - vertical order: from the Play button, DOWN steps hero buttons → seasons → episodes → cast → similar (each landing on that region's first item on first entry);
  - hero bar memory: focus the second hero button, DOWN, UP → second hero button;
  - season → episodes → back up to the same season; switching season then entering episodes lands on the first episode of the new season (the episode region's items changed ids);
  - similar rail round-trip with cast rail scrolled.
- [ ] **Step 2: Run** with the define. Expected: FAIL.
- [ ] **Step 3: Implement** the wiring.
- [ ] **Step 4: Run** the new files and existing `test/presentation/screens/detail` and `show` tests (plain and with the define). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): remember focus across detail page sections on TV`.

### Task 5: Lists (settings, calendar, downloads)

**Files:**
- Modify: settings list body, calendar timeline, `player/lib/presentation/screens/downloads/downloads_screen.dart` and `downloads/widgets/downloaded_episode_rail.dart` (`itemId`). Lists use `FocusMemoryRegion(entry: FocusMemoryEntry.firstVisible)`.
- Test: `player/test/presentation/screens/settings/settings_focus_tv_test.dart`, `player/test/presentation/screens/calendar/calendar_focus_tv_test.dart`, `player/test/presentation/screens/downloads/downloads_focus_tv_test.dart`

- [ ] **Step 1: Write failing tests** (lighter set): first entry lands on the first visible item; leaving the list and returning lands on the remembered item; LEFT reaches the rail and RIGHT returns. Do not change `settings_initial_focus_test.dart`'s expectations; run it to confirm.
- [ ] **Step 2: Run** with the define. Expected: FAIL.
- [ ] **Step 3: Implement** the wiring.
- [ ] **Step 4: Run** new files plus existing tests in those folders (plain and with the define). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): remember focus in TV settings, calendar and downloads lists`.

### Task 6: Player OSD

**Files:**
- Modify: the OSD control bar and track/queue strips under `player/lib/presentation/widgets/video_controls/` and `player/lib/presentation/screens/player/` (wrap the OSD in `FocusTraversalGroup(policy: ReadingOrderTraversalPolicy(requestFocusCallback: FocusMemory.requestFocus))` on TV; control bar and each strip become regions; the scrubber is its own region with one item).
- Test: extend `player/test/presentation/screens/player/player_osd_focus_tv_test.dart`

- [ ] **Step 1: Write failing tests**: focus the third control, UP to the scrubber, DOWN → third control; from a track strip item, UP to controls, DOWN → same strip item. Existing scrubber LEFT/RIGHT scrub and Back-to-cancel tests stay green unchanged.
- [ ] **Step 2: Run** with the define. Expected: new tests FAIL.
- [ ] **Step 3: Implement.** Do not touch `tv_scrubber.dart` key handling or `player_key_bindings.dart`.
- [ ] **Step 4: Run** the OSD file plus `test/presentation/widgets/video_controls` (plain and with the define). Expected: PASS.
- [ ] **Step 5: Commit** `feat(player): remember focus between OSD controls and strips on TV`.

### Task 7: Full verification

- [ ] **Step 1:** `./dev flutter analyze`. Expected: no issues.
- [ ] **Step 2:** `./dev flutter test`. Expected: all pass.
- [ ] **Step 3:** Every TV file: from the repo root, `./dev flutter test --concurrency=1 --dart-define=MYDIA_FORCE_TV=true $(git -C player ls-files 'test/**/*_tv_test.dart')`. Expected: all pass, and the new files from Tasks 1-6 are in the list.
- [ ] **Step 4:** `git diff --stat origin/master...` lists only files named in this plan (plus the plan/spec). Commit any fixups.
