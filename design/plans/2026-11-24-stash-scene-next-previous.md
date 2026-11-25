# Stash scene next/previous Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Stash scene in the player can step to the previous/next scene of the list it was opened from, and the Up Next countdown offers the next scene at the end.

**Architecture:** A `PlaybackSequence` descriptor rides the item and player routes as `seq*` query parameters. `StashMediaSource` implements a new `SceneSequence` capability that re-runs the origin's `findScenes` query around the position to find neighbours. `UpNextController` gains a sequence mode beside its season mode, so the existing buttons, keys, media-session actions and countdown drive scenes.

**Tech Stack:** Flutter/Dart, Riverpod, go_router, Stash GraphQL.

**Spec:** `design/specs/2026-11-24-stash-scene-next-previous-design.md`

All paths below are relative to `player/`.

## Global Constraints

- Only a source implementing `SceneSequence` gets a sequence; every other item and every deep link without `seq` parameters behaves exactly as today.
- Neighbour lookups never throw into the player: any failure means "no neighbours".
- Locations are built only in `lib/presentation/screens/detail/detail_links.dart`.
- No real movie/TV/scene titles in tests or fixtures; invent them.
- User-visible strings go through l10n ARB files (`player/docs/l10n.md`).
- Run `./dev flutter analyze` clean and the touched tests with `./dev flutter test --concurrency=1 <paths>` before each commit. Commit with plain `git commit` from the worktree (pre-commit hook runs dart format/analyze); verify with `git show --stat HEAD`.

**Deviation from spec, decided here:** the random seed is held by `StashMediaSource` (one seed per source instance, used for every `random` query) instead of being picked by the library screen. Same effect for paging and stepping within an app session; no `BrowseQuery`/cache-key change. A web reload reshuffles, and neighbour lookup then falls back to the id scan. Update the spec's "Random sort" paragraph to say this in Task 2.

## Review Focus

1. A scene that is the first or last of its list: no previous (or next) button, no countdown at the end of the last.
2. A watched scene opened from Continue Watching drops out of that list on the server while playing: stepping must still work (id scan / position fallback).
3. A Stash request failing mid-playback (server down): playback continues, buttons simply absent.
4. A `seq` parameter set that is partial or garbage in a hand-edited URL: plays like a deep link, no crash.
5. Up Next prompt for a scene with no title: shows the basename-derived summary title (from `stashSummary`), never an "Episode N" fallback or `S0E0` code.

---

### Task 1: `PlaybackSequence`, capability types, route codec

**Files:**
- Create: `lib/domain/sources/playback_sequence.dart`
- Modify: `lib/core/sources/capabilities.dart` (add `SceneSequence`)
- Modify: `lib/presentation/screens/detail/detail_links.dart` (`sourceItemLocation`, `sourcePlayerLocation`)
- Test: `test/domain/sources/playback_sequence_test.dart`, existing detail_links test if present (`grep -rl sourcePlayerLocation test/`)

**Interfaces:**
- Produces:
  - `enum SequenceOrigin { library, search, continueWatching, recentlyAdded }`
  - `@immutable class PlaybackSequence { const PlaybackSequence({required SequenceOrigin origin, required int position, String? sortId, bool? descending, Set<String> filterIds = const {}, String? query}); PlaybackSequence at(int position); Map<String, String> toQuery(); static PlaybackSequence? fromQuery(Map<String, String> q); }` with value equality.
  - `@immutable class SequenceNeighbour { const SequenceNeighbour({required ItemSummary item, required int position}); }`
  - `@immutable class SequenceNeighbours { const SequenceNeighbours({this.previous, this.next}); static const none = SequenceNeighbours(); final SequenceNeighbour? previous, next; }`
  - In `capabilities.dart`: `abstract interface class SceneSequence { Future<SequenceNeighbours> neighbours(ItemRef ref, PlaybackSequence sequence); }`
  - `String sourceItemLocation(ItemRef ref, {PlaybackSequence? sequence})` and `sourcePlayerLocation(..., PlaybackSequence? sequence)`: both merge `sequence?.toQuery()` into the query. For a kind routed through `detailLocation` the sequence is ignored (only `ItemKind.video` uses `/item/`).

Query keys (exact): `seq` (origin name), `seqPos`, `seqSort`, `seqDesc` (`1`/`0`), `seqFilter` (comma-joined, sorted), `seqQ`.

- [ ] **Step 1: Write failing tests** in `playback_sequence_test.dart`:
  - `round-trips every origin`: for each origin build a sequence with all fields set, `PlaybackSequence.fromQuery(s.toQuery()) == s`.
  - `omits unset fields`: `PlaybackSequence(origin: SequenceOrigin.continueWatching, position: 3).toQuery()` equals `{'seq': 'continueWatching', 'seqPos': '3'}`.
  - `rejects malformed`: `fromQuery` returns null for `{}`, `{'seq': 'bogus', 'seqPos': '1'}`, `{'seq': 'library'}`, `{'seq': 'library', 'seqPos': '-1'}`, `{'seq': 'library', 'seqPos': 'x'}`.
  - `at() moves only the position`.
  - detail_links: `sourcePlayerLocation(videoRef, fileId: 'f', sequence: s)` contains `seq=library&seqPos=4`; `sourceItemLocation(videoRef, sequence: s)` likewise; without `sequence` the strings equal today's.
- [ ] **Step 2: Run, expect FAIL** (`./dev flutter test --concurrency=1 test/domain/sources/playback_sequence_test.dart`).
- [ ] **Step 3: Implement** the types and the two `detail_links` parameters.
- [ ] **Step 4: Run tests + analyze, expect PASS.**
- [ ] **Step 5: Commit** `feat(player): PlaybackSequence route descriptor and SceneSequence capability`.

### Task 2: Stash neighbours, shared query builder, seeded random

**Files:**
- Modify: `lib/core/sources/stash/stash_media_source.dart`
- Modify: `lib/core/sources/stash/stash_mapping.dart` (`stashSummary` sets `defaultVersionId`)
- Modify: `design/specs/2026-11-24-stash-scene-next-previous-design.md` (random-seed paragraph, per the deviation above)
- Test: `test/core/sources/stash/stash_media_source_test.dart` (use `fake_stash_server.dart`)

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `StashMediaSource implements SceneSequence`; `ItemSummary.defaultVersionId` is the first file's id (`'${file['id']}'`) for Stash scenes, so `SequenceNeighbour.item.defaultVersionId` is the neighbour's file id.

Behaviour:
- One private `Map<String, dynamic> _findScenesVariables(PlaybackSequence-like inputs, {required int page, required int perPage})` used by `browse`, `search`, `continueWatching`, `recentlyAdded` and `neighbours`, so each origin's filter/sort is defined once. Origins map: `library` → the `browse` variables from `sortId`/`descending`/`filterIds`; `search` → `q` = `query`, page 1, per_page 40; `continueWatching` and `recentlyAdded` → today's variables of those methods.
- `random` sort sends `random_<seed>`, `seed` a `final int` drawn once per `StashMediaSource` (`Random().nextInt(1 << 31)`, injectable via an optional constructor parameter for tests).
- `neighbours`: per_page 60 (search: its single page of 40; continueWatching/recentlyAdded: their 20). Fetch the page(s) covering `position-1 .. position+1`. Resolution order: (1) scene id at `position` → its neighbours; (2) id found elsewhere in the fetched window → neighbours of that index; (3) scan pages from 1, at most 5, for the id; (4) not found → `next` = item now at `position`, `previous` = item at `position-1`. Each neighbour's `position` is its absolute index. Any exception → `SequenceNeighbours.none`.

- [ ] **Step 1: Write failing tests** (scenes named "Scene Alpha".."Scene N", fictional):
  - `middle of library`: 5 scenes, position 2 → previous id at index 1 (position 1), next at index 3 (position 3).
  - `first and last`: position 0 → previous null; last → next null.
  - `crosses a page boundary`: 61+ scenes, position 59 → next has position 60 (two pages requested).
  - `list shifted by one`: scene expected at 2 is now at 3 → neighbours are indices 2 and 4.
  - `scene gone`: id absent everywhere → next = scene now at position, previous = scene at position-1.
  - `search origin` sends `q` and per_page 40; `continueWatching` origin sends the resume_time filter.
  - `graphql error returns none`.
  - `random sort is seeded`: with an injected seed 42, `browse` with sortId `random` sends `sort: 'random_42'` on pages 1 and 2.
  - `stashSummary sets defaultVersionId` to the first file's id.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; update the spec paragraph.
- [ ] **Step 4: Run tests + analyze, expect PASS** (whole `test/core/sources/stash/`).
- [ ] **Step 5: Commit** `feat(player): Stash resolves previous/next scenes of a list`.

### Task 3: Entry points attach and forward the sequence

**Files:**
- Create: `lib/presentation/screens/sources/scene_sequence_links.dart`
- Modify: `lib/presentation/screens/sources/source_library_screen.dart` (grid ~line 385, list ~line 572)
- Modify: `lib/presentation/screens/sources/source_search_screen.dart` (~line 226)
- Modify: `lib/presentation/screens/sources/source_poster_row.dart` (optional `sequenceFor`)
- Modify: the home rows that show a single Stash library preview (`home_screen.dart` `rows.libraries` loop) and the continue-watching row (`home_continue_watching_row.dart`)
- Modify: `lib/presentation/screens/sources/source_item_screen.dart` and its route (in `app_router.dart` / `sourceItemRoute()`), so the item screen receives the `PlaybackSequence?` from its URI and the Play button forwards it to `sourcePlayerLocation`.
- Test: `test/presentation/screens/sources/scene_sequence_links_test.dart` plus additions to the existing library/search/item screen tests.

**Interfaces:**
- Consumes: Task 1.
- Produces: `PlaybackSequence? sceneSequenceFor(MediaSource? source, ItemSummary item, PlaybackSequence Function() build)`: returns `build()` only when `item.ref.kind == ItemKind.video` and `source?.as<SceneSequence>() != null`, else null. Every call site goes through it.
- `SourcePosterRow({..., PlaybackSequence? Function(int index, ItemSummary item)? sequenceFor})`; the default poster tap uses `sourceItemLocation(item.ref, sequence: sequenceFor?.call(index, item))`.

Origins per call site: library grid/list → `library` with the screen's effective `BrowseQuery` (`sortId`, `descending`, `filterIds`) and the tapped index; search → `search`, `query` = current text, index; home library preview row → `library` with the preview's query (recently-added sort id, `descending: null`), index; home continue-watching row → `continueWatching`, index (merged order differs; Task 2's id scan covers it). Merged All servers rows and similar-item rails pass nothing.

- [ ] **Step 1: Write failing tests:**
  - `sceneSequenceFor`: returns the sequence for a Stash video; null for a non-`SceneSequence` source; null for a movie.
  - Library screen widget test with a fake Stash-like source implementing `SceneSequence`: tapping the third grid poster pushes a location containing `seq=library&seqPos=2` and the active sort id; the same screen over a plain fake source pushes today's location.
  - Item screen: opened at `/s/x/item/video/7?seq=library&seqPos=2`, tapping `source-item-play` pushes a player location containing `seq=library&seqPos=2`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run tests + analyze, expect PASS** (also the existing `test/presentation/screens/sources/` and home tests).
- [ ] **Step 5: Commit** `feat(player): carry the scene list from library, search and home into the player`.

### Task 4: Player: session, controller sequence mode, scene Up Next

**Files:**
- Modify: `lib/presentation/screens/sources/source_player_route.dart` (`SourcePlayerParams.sequence`, pass to `playbackSessionFor`)
- Modify: `lib/presentation/screens/player/session/playback_session.dart`, `source_playback_session.dart`, `source_playback_sessions.dart`, `mydia_playback_session.dart`, and every other `PlaybackSession` implementer including test fakes (`grep -rn "implements PlaybackSession\|extends SourcePlaybackSession" lib test`)
- Modify: `lib/presentation/widgets/video_controls/up_next_policy.dart` (`UpNextTarget` scene variant)
- Modify: `lib/presentation/widgets/video_controls/up_next_prompt.dart` (scene rendering)
- Modify: `lib/presentation/screens/player/up_next_controller.dart`
- Modify: `lib/presentation/screens/player/player_screen.dart` (fetch neighbours in `_fetchProgressAndEpisodes`, navigation)
- Modify: `lib/core/sources/README.md` (paragraph after "Source episodes get Up Next")
- Test: `test/presentation/screens/player/up_next_controller_test.dart`, `test/presentation/widgets/video_controls/up_next_prompt_test.dart`, new `test/presentation/screens/player/player_screen_scene_sequence_test.dart` (use `player_screen_test_harness.dart`)

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces:
  - `PlaybackSession.sequenceNeighbours()` → `Future<SequenceNeighbours?>`, never throws; and `String sequenceLocation(SequenceNeighbour neighbour)`. `SourcePlaybackSession` gets an optional `PlaybackSequence? sequence` constructor field; it answers from `source.as<SceneSequence>()` when both are present, else null. `sequenceLocation` = `sourcePlayerLocation(neighbour.item.ref, fileId: neighbour.item.defaultVersionId, title: neighbour.item.title, sequence: sequence!.at(neighbour.position))`. Mydia and other sessions: `sequenceNeighbours` returns null; `sequenceLocation` throws `UnsupportedError`.
  - `UpNextTarget`: add `final SequenceNeighbour? scene;` and a named constructor `UpNextTarget.scene(SequenceNeighbour n)` (episode fields zeroed, `title` = `n.item.title`, `fileId` = `n.item.defaultVersionId ?? ''`). For a scene, `pillLabel` uses the title instead of `episodeCode`, the prompt shows `n.item.subtitle` (studio) where the episode code sits, never the "Episode N" fallback, and the still is `SourceArtworkImage` for `n.item.poster` (check its constructor in `lib/presentation/widgets/source_artwork.dart`) instead of `thumbnailUrl`.
  - `UpNextController`: new constructor param `required Future<void> Function(SequenceNeighbour n) navigateSequence`; `void setSequence(SequenceNeighbours n)` and `void clearSequence()` (pure, screen wraps in `setState`). When a sequence is set: `hasPrevious`/`hasNext` read it; `onPositionTick` offers `UpNextTarget.scene(next)` (skip `isEpisode()` and season logic; the downloaded-source gate does not apply because downloads have no sequence); `playNext`/`playPrevious` call `navigateSequence`. Season mode unchanged when no sequence is set.
  - `PlayerScreen`: `_fetchProgressAndEpisodes` adds a `'scene sequence'` isolated task that awaits `_session.sequenceNeighbours()` and, if current, `setState(() => _upNext.setSequence(n))` then `_publishNowPlaying()`. `navigateSequence` = save progress, then `context.go(_session.sequenceLocation(n))` (same shape as `_navigateToEpisode`). Every place gated on `widget.mediaType == 'episode'` for Up Next/transport (`isEpisode:` callback at ~line 1223 and the gates at ~5923/6354) must also pass when a sequence is set: change the `isEpisode` callback to `() => widget.mediaType == 'episode' || _upNext.hasSequence`, adding `bool get hasSequence`.
  - README: two or three sentences on `SceneSequence` and the `seq*` parameters.

- [ ] **Step 1: Write failing tests:**
  - controller: `setSequence` with previous and next → `hasPrevious`, `hasNext` true; `playNext()` calls `navigateSequence` with next; `playPrevious()` with previous; with `next: null` → `hasNext` false and `onPositionTick` shows nothing; `onPositionTick` with next shows a target whose `scene` is next; countdown elapse navigates to next; after `cancel()` the countdown elapse does not navigate but a manual `playNext()` does.
  - prompt: a scene target titled "Scene Beta" with subtitle "Studio Gamma" renders both texts and no `S0E0`.
  - route: `SourcePlayerParams.fromUri` parses `seq*`; malformed gives null sequence.
  - player screen (harness, fake session returning neighbours): transport shows previous/next buttons for a `movie`-typed video when the session has neighbours; tapping next routes to `sequenceLocation(next)`; with `sequenceNeighbours()` → null no buttons show.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the touched tests, then `./dev player test` (whole suite) and `./dev flutter analyze`; expect PASS.
- [ ] **Step 5: Commit** `feat(player): previous/next and Up Next for Stash scenes`.
