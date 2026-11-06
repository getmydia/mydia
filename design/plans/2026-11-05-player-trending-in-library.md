# Player: Trending in Your Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two player Home rows, "Trending movies" and "Trending shows", listing owned, not-fully-watched titles ranked by TMDB trending then popular, supplied by each Mydia server.

**Architecture:** A new Mydia context module pages through the cached relay lists (`Metadata.fetch_curated_list/2`), matches TMDB ids against the scope's media items, drops watched ones, and tags each with a global rank. A GraphQL query exposes it as `[RecentlyAddedItem]` with a new nullable `trendingRank`. The player adds an optional `Trending` source capability, caches each server's ranked list like Recently Added, and merges servers by rank on Home.

**Tech Stack:** Elixir/Phoenix + Absinthe, Rust `async-graphql` (SDL parity stubs only), Flutter + Riverpod + graphql codegen.

**Spec:** `design/specs/2026-11-05-player-trending-in-library-design.md`

## Global Constraints

- Metadata only through metadata-relay via `Mydia.Metadata`; no TMDB keys anywhere.
- Matching by TMDB id only; no TVDB/IMDb matching, no `metadata-relay/` changes.
- No migration.
- Row target 20 items per type; a Home row with fewer than 5 cards after merging is hidden.
- Page caps per type: 3 pages of `:trending`, then 5 pages of `:popular`.
- In-progress titles stay; fully watched titles are dropped.
- Row titles: "Trending movies", "Trending shows" (translated in all four ARB files).
- Placement on Home: after Recently Added (movies, shows), before Favorites.
- Plex, Jellyfin, Stash: no implementation.
- Never use real movie/TV titles in tests or fixtures; invent them.
- Commit with plain `git commit -F <msgfile>` from the worktree (the worktree guard refuses `devenv shell -- git`); stage every path first and check `git show --stat` after each commit.

## Review Focus

1. A restricted account (category or age limit) must not see an owned title outside its scope in the trending rows. Test: Task 1, `respects scope restrictions`.
2. Relay down or erroring: the resolver returns a GraphQL error, and Home still renders every other row with no trending rows and no "server unavailable" banner. Tests: Task 2 `relay failure is a field error`; Task 4 `trending failure hides only the trending rows`.
3. A Mydia server older than this change ("Cannot query field"): the player shows no trending rows and raises nothing. Test: Task 3 `old server answers an empty list`.
4. Shows: a partly watched show stays, a fully watched show goes, a show with no files never appears. Test: Task 1, `show watch rules`.
5. The same title owned on two servers is one card with `extraCopies`, and cards from two servers interleave by rank, not by server. Test: Task 4 `mergeRanked orders globally and dedupes`.

---

### Task 1: `Mydia.Media.TrendingInLibrary`

**Files:**
- Create: `lib/mydia/media/trending_in_library.ex`
- Test: `test/mydia/media/trending_in_library_test.exs`
- Commit alongside: `design/specs/2026-11-05-player-trending-in-library-design.md`, this plan

**Interfaces:**
- Produces: `Mydia.Media.TrendingInLibrary.list(scope :: Scope.t(), user_id :: term(), media_type :: :movie | :tv_show, opts :: keyword()) :: {:ok, [{MediaItem.t(), pos_integer()}]} | {:error, term()}`. Options: `:limit` (default 20), `:fetch` (default `&Mydia.Metadata.fetch_curated_list/2`, called as `fetch.(list_type, media_type: t, page: p)` and returning `{:ok, %{results: [%SearchResult{provider_id: String.t()}], total_pages: integer}}`). The integer is the rank.

- [ ] **Step 1: Write the failing tests** (`use Mydia.DataCase`, `Mydia.MediaFixtures`, a `fetch` stub built from a map `%{{:trending, 1} => [ids], {:popular, 1} => [ids]}`):
  - `returns owned matches in TMDB order with ranks`: trending page 1 = `["11", "12", "13"]`, owned with files: 13 and 11. Assert `[{%{tmdb_id: 11}, 1}, {%{tmdb_id: 13}, 3}]`.
  - `rank counts every fetched id, deduped across lists`: trending `["1","2"]`, popular `["2","3"]`; owned 3 → rank 3 (2 is not counted twice).
  - `digs into popular when trending is short`: trending has 0 owned, popular page 1 has an owned id → returned.
  - `stops at limit and does not fetch further pages`: `limit: 1`, owned id on trending page 1; assert the stub was never called for `{:popular, _}` (send a message from the stub, `refute_received`).
  - `respects page caps and total_pages`: stub records calls; with `total_pages: 10` and nothing owned, calls are trending 1..3 then popular 1..5, exactly.
  - `drops items without files and fully watched movies`; in-progress movie (progress, `watched: false`) stays.
  - `show watch rules`: show with 2 episodes with files, one watched → kept; both watched → dropped; show with no files → absent.
  - `respects scope restrictions`: user scope with `allowed_categories` excluding the item's category → absent.
  - `skips non-integer provider ids`.
  - `error before any page succeeds` → `{:error, _}`; `error on a later page` → `{:ok, matches_so_far}`.
  - `filters by media_type`: an owned show with a trending movie id does not match when `media_type: :movie`.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia/media/trending_in_library_test.exs`
Expected: FAIL, `TrendingInLibrary` undefined.

- [ ] **Step 3: Implement `list/4`**

Walk the lists in order `[{:trending, 1..3}, {:popular, 1..5}]`, stopping a list at its `total_pages`. Keep a running `seen` set of TMDB ids and a rank counter (next rank = `MapSet.size(seen) + 1` for each new id). For each page, look up the new ids with `Mydia.Media.list_media_items(scope, base_query: from(m in MediaItem, where: m.tmdb_id in ^ids), type: type_string, has_files: true)`, drop watched (movies: `Playback.list_user_progress(user_id, watched: true)` ids, loaded once; shows: `WatchStatus.load_shows(user_id, show_ids)` then `WatchStatus.for_show(bundle).watched`), append in rank order, and halt once `limit` is reached. A fetch error before any page succeeded returns `{:error, reason}`; after that it ends the walk.

- [ ] **Step 4: Run to verify they pass** (same command; expected PASS)

- [ ] **Step 5: Commit** (`feat(media): rank owned titles by TMDB trending and popular`), including the spec and this plan.

### Task 2: GraphQL `trendingInLibrary` and parity

**Files:**
- Modify: `lib/mydia_web/schema/query_types.ex` (discovery queries, after `recently_added`; `trending_rank` field on `:recently_added_item`)
- Modify: `lib/mydia_web/schema/resolvers/discovery_resolver.ex` (new `trending_in_library/3`)
- Modify: `lib/mydia_web/schema/resolvers/item_builder.ex` (`recently_added_item/2` accepts `trending_rank:`)
- Modify: `priv/graphql/schema.graphql` (via `./dev mix schema.export`)
- Modify: `server/crates/api/src/query.rs`, `server/crates/api/src/types/media.rs`
- Create: `test/mydia_web/schema/trending_in_library_test.exs`
- Modify: `test/support/metadata_cache_helpers.ex` (new `stub_curated_lists/2`)

**Interfaces:**
- Consumes: `TrendingInLibrary.list/4`.
- Produces (GraphQL): `trendingInLibrary(type: MediaType!, first: Int = 20): [RecentlyAddedItem]`, and `RecentlyAddedItem.trendingRank: Int` (null on every other query). Rust: `RecentlyAddedItem.trending_rank: Option<i32>`; stub `trending_in_library(&self, _ctx, #[graphql(name = "type")] _media_type: MediaType, #[graphql(default = 20)] _first: Option<i32>) -> Result<Option<Vec<Option<RecentlyAddedItem>>>>` returning `Ok(None)`, with a doc comment citing `discovery_resolver.ex`.
- Produces (test helper): `stub_curated_lists(media_type, %{trending: [map], popular: [map]})`, a Bypass `stub` for `/tmdb/{movies|tv}/{trending|popular}` answering `total_pages: 1`, swapping `metadata_relay_url` the way `warm_trending_cache/2` does and deleting every `curated:*:#{media_type}:*` key it could have filled `on_exit`.

- [ ] **Step 1: Write the failing tests** (`MydiaWeb.ConnCase, async: false`, `run_query/3` as in `discovery_filters_test.exs`):
  - `returns owned trending items with trendingRank` for `type: MOVIE`; assert ids, titles and `trendingRank` values.
  - `anonymous context answers []`.
  - `relay failure is a field error`: Bypass answering 500 → `errors` present, `data.trendingInLibrary` nil.
  - `other queries return null trendingRank` (`recentlyAdded { trendingRank }`).

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia_web/schema/trending_in_library_test.exs`
Expected: FAIL, unknown field.

- [ ] **Step 3: Implement the field and resolver.** The resolver maps `{item, rank}` through `ItemBuilder.recently_added_item(item, trending_rank: rank)` with `added_at` from `RecentlyAdded.added_at_map/1`, takes `first`, returns `{:ok, []}` without `current_user`, and `{:error, "Trending is unavailable right now"}` on `{:error, _}`. `watchStatus` already resolves through `resolve_recently_added_watch_status/3`.

- [ ] **Step 4: Export the schema and add the Rust stubs**

Run: `./dev mix schema.export` then `devenv shell -- bash -c "cd server && cargo test -p mydia-api --test sdl_parity"`
Expected: parity test PASS.

- [ ] **Step 5: Run the Elixir tests**

Run: `./dev mix test test/mydia_web/schema/trending_in_library_test.exs test/mydia_web/schema_sdl_test.exs test/mydia/access_restrictions/remote_filter_guard_test.exs`
Expected: PASS. (The guard scans `lib/mydia_web`; the resolver must not call `Metadata.*` directly, since all catalog access lives in `TrendingInLibrary`, and the results are owned items already filtered by scope.)

- [ ] **Step 6: Commit** (`feat(graphql): trendingInLibrary query`).

### Task 3: Player `Trending` capability on Mydia

**Files:**
- Create: `player/lib/domain/sources/ranked_item.dart`
- Modify: `player/lib/core/sources/media_source.dart` (`SourceCapability.trending`)
- Modify: `player/lib/core/sources/capabilities.dart` (`Trending` interface)
- Modify: `player/lib/core/sources/cache/source_codecs.dart`, `player/lib/core/sources/cache/source_keys.dart` (+ `source_rules.dart` if it lists every op)
- Create: `player/lib/graphql/queries/trending_in_library.graphql`
- Modify: `player/lib/core/sources/mydia/mydia_source.dart`
- Test: `player/test/core/sources/mydia/mydia_source_test.dart`, `player/test/core/sources/mydia/mydia_capabilities_test.dart`, a codec round-trip test beside existing codec tests

**Interfaces:**
- Produces:
  - `@immutable class RankedItem { const RankedItem({required ItemSummary item, required int rank}); Map<String, Object?> toJson(); factory RankedItem.fromJson(Map<String, Object?>); }`
  - `abstract interface class Trending { /// Rank order, at most 20. Empty when the server has no list. Future<List<RankedItem>> trending(ItemKind kind); }`, where `kind` is `ItemKind.movie` or `ItemKind.show`.
  - `encodeRanked(List<RankedItem>)`, `decodeRanked(Object?)` in `source_codecs.dart`.
  - `SourceKeys.trending(SourceId id, ItemKind kind)`.

- [ ] **Step 1: Write the failing tests**
  - `trending maps rows with trendingRank` (FakeMydiaTransport answering `trendingInLibrary` with two rows; assert kinds, titles, ranks, and that the variable `type` is `MOVIE` for `ItemKind.movie`, `TV_SHOW` for `ItemKind.show`).
  - `rows without trendingRank are dropped`.
  - `old server answers an empty list` (transport throws a "Cannot query field \"trendingInLibrary\"" GraphQL error → `[]`).
  - Other GraphQL errors still throw `SourceException`.
  - Capabilities test: Mydia lists `SourceCapability.trending` and `as<Trending>()` is non-null; Plex/Jellyfin/Stash do not.
  - `RankedItem` JSON round trip.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev flutter test test/core/sources/mydia/`
Expected: FAIL to compile (`Trending` undefined).

- [ ] **Step 3: Implement.** The document requests the same fields as `RecentlyAddedFull` plus `trendingRank`; map rows with `listingSummary(id, r)`. Catch `isUnknownFieldError` → `const []`. Run `./dev flutter pub run build_runner build` for the document.

- [ ] **Step 4: Run to verify they pass** (same command, plus `./dev flutter analyze`)

- [ ] **Step 5: Commit** (`feat(player): Trending capability on Mydia sources`).

### Task 4: Home rows

**Files:**
- Modify: `player/lib/domain/merged/merge_rows.dart` (`mergeRanked`)
- Modify: `player/lib/presentation/screens/sources/source_browse_providers.dart` (`sourceTrendingProvider`)
- Modify: `player/lib/presentation/screens/home/home_rows.dart`, `home_rows_provider.dart`, `home_screen.dart`
- Modify: `player/lib/l10n/app_en.arb`, `app_es.arb`, `app_pt.arb`, `app_pt_BR.arb`
- Test: `player/test/presentation/screens/home/home_rows_test.dart`, `home_rows_provider_test.dart`, `home_screen_test.dart`, merge-rows tests beside existing ones

**Interfaces:**
- Consumes: `Trending`, `RankedItem`, `encodeRanked`/`decodeRanked`, `SourceKeys.trending`.
- Produces:
  - `Deduped mergeRanked(List<List<RankedItem>> perSource, List<SourceId> order, {int limit = 20})`: sort by rank, ties by server order then position, then `dedupe`, then take `limit`.
  - `sourceTrendingProvider`: `StreamProvider.autoDispose.family<List<RankedItem>, (SourceId, ItemKind)>`, `Stream.value(const [])` when `as<Trending>()` is null, else `createSourceWatcher` like `sourceRecentlyAddedProvider`, same `retry: (_, __) => null`.
  - `HomeFeeds.trendingMovies`, `HomeFeeds.trendingShows`: `AsyncValue<List<RankedItem>>`, default `AsyncValue.data(const [])`.
  - `HomeRows.trendingMovies`, `HomeRows.trendingShows`: `List<ItemSummary>`; `const homeTrendingLimit = 20; const homeTrendingMinimum = 5;`
  - ARB keys `homeTrendingMovies` ("Trending movies"), `homeTrendingShows` ("Trending shows").

- [ ] **Step 1: Write the failing tests**
  - `mergeRanked orders globally and dedupes`: server A ranks [1, 4], server B ranks [2, 4-same-title]; result order 1, 2, 4 with `extraCopies` 1 for the shared title.
  - `buildHomeRows trending rows`: 5+ ranked items per kind → rows populated; 4 items → row empty.
  - `trending failure hides only the trending rows`: trending `AsyncError`, everything else data → other rows present, `unavailable` empty, `loading` false.
  - `trending still loading does not hold Home loading`.
  - `refreshHome` invalidates the trending providers; `homeQueryKeys` includes both trending keys.
  - Home screen: rails keyed `home-trending-movies` / `home-trending-shows` appear after `home-recent-shows` and before `home-favorites`, with no chevron (no `onTitleTap`); absent when empty.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev flutter test test/presentation/screens/home/ test/domain/merged/`
Expected: FAIL to compile.

- [ ] **Step 3: Implement.** `_rail` takes an optional `location`; pass `onTitleTap: null` when it is absent. `isEmpty` counts the trending rows. Add the ARB strings (with `@` descriptions in `app_en.arb`) and translations; regenerate l10n.

- [ ] **Step 4: Run to verify they pass** (same command, plus `./dev flutter analyze` and `./dev flutter test test/l10n/` if present)

- [ ] **Step 5: Commit** (`feat(player): trending rows on Home`).

### Task 5: Final verification

- [ ] **Step 1:** `./dev mix precommit` (run chunked if it outruns the 600s cap) and `./dev flutter test`; both green.
- [ ] **Step 2:** `git diff --stat origin/master...` lists only files named in this plan plus generated files (`priv/graphql/schema.graphql`, player codegen and l10n outputs).
- [ ] **Step 3:** Manual check against a dev server: `./dev up -d`, own a movie whose TMDB id is on this week's trending list, open `http://localhost:4000/player`, confirm the row and that marking the movie watched removes it after refresh.
