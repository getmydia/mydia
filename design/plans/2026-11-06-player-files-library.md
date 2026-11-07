# Files Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `files` source in the player that turns local folders and WebDAV shares into a TMDB-matched library, with filename parsing and match scoring shared with the Rust server.

**Architecture:** A new DB-free crate `native/mydia_media_names` takes the parser from `server/crates/library` and adds `score`; the server re-exports it and the player calls it over flutter_rust_bridge. Everything else is Dart under `player/lib/core/sources/files/`: a `FileSystemBackend` seam, a scanner, a relay-backed matcher, a Hive index, and `FilesMediaSource`, which the existing screens consume like any other source.

**Tech Stack:** Rust (regex, serde), flutter_rust_bridge 2.13.0, Dart/Flutter, Riverpod, hive_ce, `package:http`, `package:xml`, `file_selector`, media_kit.

**Spec:** `design/specs/2026-11-06-player-files-library-design.md`

## Global Constraints

- Two PRs. PR 1 is Tasks 1 to 11 (shared crate, core, WebDAV, desktop folders, UI). PR 2 is Tasks 12 to 14 (Android and iOS folders). PR 2 starts with the device check in Task 12.
- macOS needs no security-scoped bookmark: the app is not sandboxed (`macos/Runner/Release.entitlements`), so desktop folders are plain paths on Linux, Windows and macOS.
- Relay concurrency: at most 4 requests in flight per scan.
- Rescan on open when the last scan is older than 6 hours.
- Match threshold: confidence `>= 0.75`.
- Video extensions: `mkv mp4 m4v mov avi ts m2ts webm wmv mpg mpeg ogv`. Sidecar subtitles: `srt ass ssa vtt` sharing the video's stem (`Movie.mkv` + `Movie.srt`, `Movie.en.srt`, `Movie.en.forced.srt`).
- Artwork comes from `https://image.tmdb.org/t/p/<size><path>`; no API key is ever in the player.
- Never use real movie or show titles in code, tests or fixtures; invent them.
- No em dashes in comments, docs or UI copy. All UI text goes through ARB (`player/docs/l10n.md`).
- Rust crates copy the lint tables from `rust-lints.toml` (`native/README.md`, "Rust rules").
- New Hive boxes go in `kMydiaHiveBoxes` (`player/lib/core/storage/hive_box_migration.dart`) and open through `initAppHive()`.
- Commit inside the devenv environment (`direnv exec . git commit ...`), one commit per step, then `git show --stat`.

## Review Focus

1. **A WebDAV href with spaces, `%20`, `#`, non-ASCII or a trailing slash.** Users expect every file to list and play. Task 4 pins decoding and re-encoding in a test.
2. **The relay is down for the first scan, then comes back.** Users expect posters to appear on the next scan with watch history intact. Task 7 pins provisional ids migrating their progress to TMDB ids.
3. **The same movie as two files (1080p and 2160p) in different folders.** Users expect one item with two versions. Task 7 tests that grouping.
4. **A root removed, or a drive unplugged, while the index still lists it.** Users expect browsing to keep working and playback to say "Folder unavailable", not crash. Task 8 tests the unreachable status, Task 9 tests the playback error.
5. **A 20,000-episode library.** Users expect the second scan to finish in seconds. Task 6 tests that an unchanged file is never re-parsed (the fake `MediaNames` counts calls).

---

## Phase 1 (PR 1)

### Task 1: Extract the parser into `native/mydia_media_names`

**Files:**
- Create: `native/mydia_media_names/Cargo.toml`, `native/mydia_media_names/src/lib.rs`
- Move (git mv): `server/crates/library/src/parser.rs` → `native/mydia_media_names/src/parser.rs`; `server/crates/library/src/parser/episode.rs` → `native/mydia_media_names/src/parser/episode.rs`; `server/crates/library/src/names.rs` → `native/mydia_media_names/src/names.rs`; `server/crates/library/tests/parser_corpus.rs` → `native/mydia_media_names/tests/parser_corpus.rs` (and its fixture files, if any)
- Modify: `server/crates/library/Cargo.toml`, `server/crates/library/src/lib.rs`, `.github/workflows/ci.yml` (next to the `mydia_subsync` cargo test at ~line 596), `.github/workflows/ci-server.yml` (both `paths:` lists)

**Interfaces:**
- Produces: crate `mydia_media_names` with `pub mod parser` (`parse(path: &Path, root: &Path, kind: LibraryKind) -> Option<ParsedFile>`, `LibraryKind`, `ParsedKind`, `ParsedFile`) and `pub mod names` (`clean_title`, `identity_key`, `plausible_year`), unchanged.

- [ ] **Step 1:** Create the crate. Dependencies: `regex`, `serde` (derive), `thiserror` only. Copy `[lints.rust]` and `[lints.clippy]` from `rust-lints.toml`. Not a member of the server workspace.
- [ ] **Step 2:** `git mv` the files above; fix `use crate::...` paths so the crate builds alone.
- [ ] **Step 3:** In `server/crates/library`, depend on `mydia-media-names = { path = "../../../native/mydia_media_names" }` and replace the two modules with `pub use mydia_media_names::{names, parser};` in `lib.rs`. `scan.rs` keeps its `crate::parser` / `crate::names` imports.
- [ ] **Step 4:** Run `cargo test --manifest-path native/mydia_media_names/Cargo.toml` and `cargo test --manifest-path server/Cargo.toml -p mydia-library`. Expected: both pass with the same test count as before the move combined.
- [ ] **Step 5:** Run `scripts/check-rust.sh` and `scripts/check-rust-lints.sh`. Expected: clean.
- [ ] **Step 6:** Add `devenv shell -- cargo test --manifest-path native/mydia_media_names/Cargo.toml` to `ci.yml`; add `"native/mydia_media_names/**"` to both path lists in `ci-server.yml`.
- [ ] **Step 7:** Commit: `refactor(server): move the filename parser into a shared crate`.

### Task 2: `score` in the shared crate

**Files:**
- Create: `native/mydia_media_names/src/score.rs`
- Modify: `native/mydia_media_names/src/lib.rs`

**Interfaces:**
- Produces:
  ```rust
  pub struct Candidate { pub id: i64, pub title: String, pub original_title: Option<String>, pub year: Option<i32> }
  pub struct Wanted { pub title: String, pub year: Option<i32>, pub is_show: bool }
  pub struct Match { pub id: i64, pub confidence: f64 }
  pub const THRESHOLD: f64 = 0.75;
  pub fn score(wanted: &Wanted, candidates: &[Candidate]) -> Option<Match>;
  ```

Algorithm (not determined by the signature):

```
tokens(s)      = identity_key(s) split on whitespace, as a set
title_sim(a,b) = 1.0 if identity_key(a) == identity_key(b)
                 else 2*|A∩B| / (|A|+|B|)            (Dice on token sets; 0 when both empty)
sim            = max(title_sim(wanted, c.title), title_sim(wanted, c.original_title))
year_adj       = both years present: diff 0 → 0.0, diff 1 → -0.10,
                                     else → -0.40 (movie) / -0.20 (show)
                 either missing:     -0.05
confidence     = clamp(sim + year_adj, 0, 1)
winner         = highest confidence; ties keep the earlier candidate (TMDB's order)
return winner if confidence >= THRESHOLD else None
```

- [ ] **Step 1: Write table tests** in `score.rs` `#[cfg(test)]`:
  - `exact_title_and_year_wins`: wanted `("Quiet Harbor", 2014, movie)`, candidates `[{1,"Quiet Harbor Nights",2014},{2,"Quiet Harbor",2014}]` → `Some(Match{id:2, confidence:1.0})`.
  - `year_off_by_one_still_matches`: `("Copper Valley", 2019)` vs `{3,"Copper Valley",2018}` → id 3, confidence `0.90`.
  - `missing_year_matches`: `("Copper Valley", None)` vs `{3,"Copper Valley",2018}` → confidence `0.95`.
  - `wrong_year_movie_misses`: `("Copper Valley", 2001)` vs `{3,"Copper Valley",2018}` → `None`.
  - `show_year_drift_is_gentler`: `("Lantern Street", 2016, show)` vs `{4,"Lantern Street",2013}` → confidence `0.80`.
  - `original_title_counts`: `("La Casa Azul", 2010)` vs `{5,"The Blue House",Some("La Casa Azul"),2010}` → id 5.
  - `unrelated_titles_miss`: `("Iron Orchard", 2012)` vs `{6,"Glass Meadow",2012}` → `None`.
  - `ties_keep_tmdb_order`: two identical candidates ids 7 and 8 → id 7.
  - `empty_candidates_is_none`.
- [ ] **Step 2:** Run `cargo test --manifest-path native/mydia_media_names/Cargo.toml score`. Expected: FAIL (unresolved items).
- [ ] **Step 3:** Implement as above. Derive `Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize` on the three structs.
- [ ] **Step 4:** Run the tests again and `scripts/check-rust.sh`. Expected: PASS, clean.
- [ ] **Step 5:** Commit: `feat(media-names): score TMDB candidates for a parsed title`.

### Task 3: Bridge to Dart

**Files:**
- Create: `player/rust/mydia_player_p2p/src/media_names.rs`, `player/lib/core/sources/files/media_names.dart`, `player/test/core/sources/files/fake_media_names.dart`
- Modify: `player/rust/mydia_player_p2p/Cargo.toml`, `player/rust/mydia_player_p2p/src/lib.rs` (`mod media_names;` and `pub use`), regenerated `player/rust/mydia_player_p2p/src/frb_generated.rs` and `player/lib/native/*`

**Interfaces:**
- Consumes: Task 1 `parse`, `identity_key`; Task 2 `score`, `Candidate`, `Wanted`, `Match`.
- Produces (Rust, FRB-exported, sync):
  ```rust
  pub enum FfiKind { Movies, Series, Mixed }
  pub struct FfiParsed { pub path: String, pub is_episode: bool, pub title: String, pub year: Option<i32>,
                         pub season: Option<i32>, pub episode: Option<i32>, pub episode_end: Option<i32>,
                         pub group_key: String }
  pub struct FfiCandidate { pub id: i64, pub title: String, pub original_title: Option<String>, pub year: Option<i32> }
  pub struct FfiMatch { pub id: i64, pub confidence: f64 }
  #[frb(sync)] pub fn parse_batch(root: String, paths: Vec<String>, kind: FfiKind) -> Vec<FfiParsed>;
  #[frb(sync)] pub fn score_candidates(title: String, year: Option<i32>, is_show: bool, candidates: Vec<FfiCandidate>) -> Option<FfiMatch>;
  ```
  `parse_batch` omits paths that do not parse. `group_key` is `identity_key(title)` for episodes and `identity_key(title) + "|" + year` (or `"|"` with no year) for movies.
- Produces (Dart):
  ```dart
  abstract interface class MediaNames {
    List<ParsedName> parseBatch(String root, List<String> paths, FilesLibraryKind kind);
    TmdbMatch? score(String title, int? year, {required bool isShow, required List<TmdbCandidate> candidates});
  }
  enum FilesLibraryKind { movies, series, mixed }
  class ParsedName { path, isEpisode, title, year, season, episode, episodeEnd, groupKey }
  class TmdbCandidate { int id; String title; String? originalTitle; int? year; }
  class TmdbMatch { int id; double confidence; }
  class RustMediaNames implements MediaNames { ... }  // calls the generated bindings
  final mediaNamesProvider = Provider<MediaNames>((ref) => RustMediaNames());
  ```
  `FakeMediaNames` in the test file implements `MediaNames` with a simple `S01E02` regex and counts `parseBatch` paths in `parsedPaths`.

- [ ] **Step 1:** Add `mydia_media_names = { path = "../../../native/mydia_media_names" }` under the non-wasm target dependencies (web never uses it).
- [ ] **Step 2:** Write `media_names.rs` with a `#[cfg(test)]` test `parse_batch_keeps_parsable_paths`: root `/lib`, paths `["/lib/Copper Valley (2018)/Copper Valley (2018).mkv", "/lib/readme"]`, kind `Mixed` → one result, `title == "Copper Valley"`, `year == Some(2018)`, `group_key == "copper valley|2018"`. Run `cargo test --manifest-path player/rust/mydia_player_p2p/Cargo.toml media_names`; expect FAIL, implement, expect PASS.
- [ ] **Step 3:** Regenerate bindings with `flutter_rust_bridge_codegen generate` from `player/` (version `2.13.0`, the one CI installs in `deploy-web-player.yml`). Expected: new `parseBatch`/`scoreCandidates` in `lib/native/lib.dart`.
- [ ] **Step 4:** Write `media_names.dart` (thin mapping) and `fake_media_names.dart`.
- [ ] **Step 5:** `./dev flutter analyze` and `scripts/check-rust.sh`. Expected: clean.
- [ ] **Step 6:** Commit: `feat(player): expose filename parsing and match scoring to Dart`.

### Task 4: `FileSystemBackend`, local paths and WebDAV

**Files:**
- Create: `player/lib/core/sources/files/backend/file_system_backend.dart`, `.../backend/local_path_backend.dart`, `.../backend/webdav_backend.dart`
- Test: `player/test/core/sources/files/backend/local_path_backend_test.dart`, `.../webdav_backend_test.dart`, fixture `player/test/fixtures/files/webdav_multistatus.xml`
- Modify: `player/pubspec.yaml` (add `xml` as a direct dependency at the version already in `pubspec.lock`)

**Interfaces:**
- Produces:
  ```dart
  class FileEntry { final String path; final String name; final bool isDir; final int size; final DateTime modified; }
  class PlayableFile { final String url; final Map<String, String> headers; }
  sealed class BackendFailure implements Exception {}   // Unreachable, Unauthorized, PermissionLost, NotFound
  abstract interface class FileSystemBackend {
    Future<List<FileEntry>> list(String dir);   // one level; throws BackendFailure
    Future<FileEntry?> stat(String path);       // null when gone
    Future<PlayableFile> playable(String path);
    Future<void> probe();                       // throws BackendFailure when the root cannot be reached
  }
  class LocalPathBackend implements FileSystemBackend { LocalPathBackend(); }
  class WebDavBackend implements FileSystemBackend {
    WebDavBackend({required Uri base, required String user, required String password, http.Client? client});
  }
  ```
  Paths are absolute for local, and server paths (URI path, decoded) for WebDAV.

- [ ] **Step 1: Tests.**
  - Local (temp dir): `lists_one_level_with_size_and_mtime`; `stat_of_missing_file_is_null`; `playable_is_the_path_with_no_headers`; `probe_of_missing_root_throws_unreachable`.
  - WebDAV (`MockClient` from `package:http/testing.dart`): `propfind_sends_depth_1_and_basic_auth` (method `PROPFIND`, header `Depth: 1`, `Authorization: Basic dXNlcjpwYXNz` for `user`/`pass`); `parses_multistatus_and_skips_the_listed_dir_itself` against the fixture, which must include a directory, a file named `Night Train #2 (2011).mkv` with href `.../Night%20Train%20%232%20(2011).mkv`, a file with a non-ASCII name, and a collection href with a trailing slash; `playable_reencodes_the_path_and_carries_auth` (URL ends `/Night%20Train%20%232%20(2011).mkv`, header `Authorization` present); `status_401_throws_unauthorized`; `socket_error_throws_unreachable`.
- [ ] **Step 2:** Run `./dev flutter test test/core/sources/files/backend/`. Expected: FAIL.
- [ ] **Step 3:** Implement. WebDAV `PROPFIND` body requests `resourcetype`, `getcontentlength`, `getlastmodified`; parse with `package:xml`, namespace `DAV:`; decode hrefs with `Uri.decodeComponent` per segment; build URLs by encoding each segment with `Uri.encodeComponent`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(player): file system backends for local folders and WebDAV`.

### Task 5: `FileLibraryIndex`

**Files:**
- Create: `player/lib/core/sources/files/index/file_library_index.dart`, `.../index/index_records.dart`
- Test: `player/test/core/sources/files/index/file_library_index_test.dart`
- Modify: `player/lib/core/storage/hive_box_migration.dart` (`files_index` in `kMydiaHiveBoxes`)

**Interfaces:**
- Produces records (plain classes with `toMap`/`fromMap`, no Hive adapters, like `HivePlaybackProgressStore`):
  ```dart
  class LibraryRoot { String id; String path; FilesLibraryKind kind; String title; }
  class IndexedFile { String key; String rootId; String path; int size; DateTime modified; DateTime firstSeen;
                      ParsedName? parsed; List<String> sidecars; }
  class GroupMatch { String groupKey; bool isShow; int? tmdbId; bool pinned; DateTime matchedAt; }
  class MatchedMovie { int tmdbId; String title; int? year; String? overview; String? posterPath;
                       String? backdropPath; int? runtimeMinutes; String? releaseDate; }
  class MatchedShow  { int tmdbId; String title; int? year; String? overview; String? posterPath; String? backdropPath;
                       Map<int, List<MatchedEpisode>> seasons; }
  class MatchedEpisode { int season; int episode; String? title; String? overview; String? stillPath; String? airDate; int? runtimeMinutes; }
  ```
- Produces the store:
  ```dart
  class FileLibraryIndex {
    static const boxName = 'files_index';
    FileLibraryIndex(Box<Map<dynamic, dynamic>> box, {required String accountId});
    List<LibraryRoot> roots(); Future<void> putRoot(LibraryRoot r); Future<void> removeRoot(String id); // removes its files
    Map<String, IndexedFile> files(); Future<void> putFiles(Iterable<IndexedFile> f); Future<void> removeFiles(Iterable<String> keys);
    GroupMatch? group(String key); Future<void> putGroup(GroupMatch g);
    MatchedMovie? movie(int id); Future<void> putMovie(MatchedMovie m);
    MatchedShow? show(int id); Future<void> putShow(MatchedShow s);
    Set<String> watched(); Future<void> setWatched(String externalId, bool watched);
    DateTime? lastScanAt(); Future<void> setLastScanAt(DateTime t);
    Future<void> clear();   // removes every key of this account
  }
  ```
  Keys are `<accountId>/<type>/<id>`; everything for one account is read once into memory on construction. `IndexedFile.key` is the first 16 hex chars of SHA-256 over `rootId + "/" + root-relative path`.

- [ ] **Step 1: Tests** (`Hive.init` on a temp dir): `roundtrips_every_record_type`; `accounts_do_not_see_each_other`; `remove_root_drops_its_files_only`; `clear_removes_only_this_account`; `unreadable_record_is_skipped_not_thrown`.
- [ ] **Step 2:** Run; expect FAIL. **Step 3:** Implement. **Step 4:** Run; expect PASS.
- [ ] **Step 5:** Commit: `feat(player): local index for files libraries`.

### Task 6: `FileScanner`

**Files:**
- Create: `player/lib/core/sources/files/scan/file_scanner.dart`
- Test: `player/test/core/sources/files/scan/file_scanner_test.dart`, `player/test/core/sources/files/fake_backend.dart`

**Interfaces:**
- Consumes: `FileSystemBackend`, `MediaNames`, `FileLibraryIndex`, `LibraryRoot`.
- Produces:
  ```dart
  class ScanDelta { final List<IndexedFile> added; final List<IndexedFile> changed; final List<String> removedKeys; }
  class FileScanner {
    FileScanner({required FileSystemBackend backend, required MediaNames names, required FileLibraryIndex index, DateTime Function()? now});
    Future<ScanDelta> scan(LibraryRoot root, {void Function(int done, int total)? onProgress});
  }
  ```
  Writes the files to the index before returning. A directory that throws `BackendFailure` mid-walk aborts the scan and leaves the index as it was (the walk is collected before any write). Hidden entries (names starting with `.`) and `@eaDir`/`#recycle` folders are skipped.

- [ ] **Step 1: Tests** with `FakeBackend` (in-memory tree) and `FakeMediaNames`:
  - `first_scan_adds_videos_and_attaches_sidecars` (`A/Movie.mkv`, `A/Movie.en.srt`, `A/notes.txt` → one file, sidecars `[A/Movie.en.srt]`).
  - `unchanged_files_are_not_reparsed` (scan twice; `parsedPaths` length equals file count after both).
  - `changed_size_or_mtime_is_reparsed`.
  - `missing_files_are_reported_removed`.
  - `hidden_and_nas_metadata_dirs_are_skipped`.
  - `backend_failure_leaves_the_index_untouched`.
  - `progress_reports_done_of_total`.
- [ ] **Step 2:** Run; FAIL. **Step 3:** Implement. **Step 4:** Run; PASS.
- [ ] **Step 5:** Commit: `feat(player): incremental scan of a files library root`.

### Task 7: Relay TMDB client and `FileMatcher`

**Files:**
- Create: `player/lib/core/sources/files/match/relay_tmdb.dart`, `.../match/file_matcher.dart`
- Test: `player/test/core/sources/files/match/relay_tmdb_test.dart`, `.../file_matcher_test.dart`

**Interfaces:**
- Consumes: `metadataRelayBaseUrl` (`core/relay/relay_api_client.dart`), `MediaNames.score`, `FileLibraryIndex`, `ScanDelta`, `PlaybackProgressStore`, `progressKey`.
- Produces:
  ```dart
  class RelayTmdb {
    RelayTmdb({http.Client? client, String baseUrl = metadataRelayBaseUrl});
    Future<List<TmdbCandidate>> searchMovies(String query, {int? year});   // GET /tmdb/movies/search?query=&year=
    Future<List<TmdbCandidate>> searchShows(String query, {int? year});    // GET /tmdb/tv/search?query=&first_air_date_year=
    Future<MatchedMovie> movie(int id);                                     // GET /tmdb/movies/:id
    Future<MatchedShow> show(int id, {required Iterable<int> seasons});     // GET /tmdb/tv/shows/:id and /tmdb/tv/shows/:id/:season
  }
  class RelayUnavailable implements Exception {}   // network error, 5xx, 429
  class FileMatcher {
    FileMatcher({required RelayTmdb tmdb, required MediaNames names, required FileLibraryIndex index,
                 required PlaybackProgressStore progress, required SourceId sourceId,
                 Future<void> Function()? onGroupLanded, int concurrency = 4});
    Future<void> matchPending();                 // every group with no GroupMatch, or whose files changed
    Future<void> pin(String groupKey, {required bool isShow, int? tmdbId});   // tmdbId null = unmatch
  }
  ```
  The relay returns raw TMDB JSON (`results[].{id,title|name,original_title|original_name,release_date|first_air_date}`).

  Item ids (`externalId`, with `ItemRef.kind` carrying the kind):

  | Item | Matched | Not matched yet (relay down) |
  | --- | --- | --- |
  | movie | `<tmdbId>` | `p<sha16(groupKey)>` |
  | show | `<tmdbId>` | `p<sha16(groupKey)>` |
  | season | `<tmdbId>-<n>` | `p<sha16>-<n>` |
  | episode | `<tmdbId>-<s>-<e>` | `p<sha16>-<s>-<e>` |
  | unmatched file (`ItemKind.video`) | | `f<fileKey>` |

  A group searched successfully with no winner is unmatched (`GroupMatch.tmdbId == null`, files become `video` items in Folders). A group never searched because the relay failed is provisional (no `GroupMatch` written, items use `p...` ids). When a provisional group later matches, `FileMatcher` moves each of its progress records and watched flags from the `p...` id to the TMDB id (save under the new `progressKey`, delete the old).

- [ ] **Step 1: Relay tests** with `MockClient` and inline JSON: query parameters as listed; `429_throws_relay_unavailable`; `show_fetches_only_requested_seasons`.
- [ ] **Step 2: Matcher tests** with a fake `RelayTmdb` (subclass with overridden methods) and `FakeMediaNames`:
  - `two_files_of_one_movie_make_one_group` (`Copper Valley (2018) 1080p.mkv` in `A/`, `Copper Valley (2018) 2160p.mkv` in `B/` → one search).
  - `episodes_group_by_show_and_fetch_their_seasons`.
  - `never_more_than_four_requests_in_flight` (fake relay records the max concurrent count over 10 groups).
  - `pinned_group_is_not_searched_again`.
  - `relay_down_leaves_group_provisional_then_migrates_progress` (save progress for `p<...>`, relay fails, relay recovers, `matchPending` → progress readable under the TMDB id, absent under the old one).
  - `below_threshold_is_unmatched_not_provisional`.
  - `unmatch_pin_moves_files_to_folders`.
  - `on_group_landed_fires_once_per_group`.
- [ ] **Step 3:** Run; FAIL. **Step 4:** Implement (a simple semaphore over `Future`s; no new package). **Step 5:** Run; PASS.
- [ ] **Step 6:** Commit: `feat(player): match files libraries against TMDB through the relay`.

### Task 8: `FilesMediaSource`

**Files:**
- Create: `player/lib/core/sources/files/files_media_source.dart`, `.../files/files_queries.dart` (pure functions from index to `ItemSummary`/`ItemDetail`), `.../files/files_account.dart`, `.../files/files_scan_controller.dart`
- Modify: `player/lib/core/sources/source.dart` (`SourceKind.files`), `.../media_source.dart` (`SourceCapability.matchEditing`), `.../capabilities.dart` (`MatchEditing`), `.../source_factories.dart`, `.../all_servers_inclusion.dart` (files included by default), `player/lib/presentation/widgets/nav/source_picker.dart` (`Icons.folder_rounded`), `.../nav/source_switcher.dart`, `player/lib/presentation/screens/sources/manage_sources_screen.dart`, ARB files
- Test: `player/test/core/sources/files/files_media_source_test.dart`, `.../files_queries_test.dart`, `.../files_scan_controller_test.dart`

**Interfaces:**
- Consumes: Tasks 4 to 7.
- Produces:
  ```dart
  // files_account.dart
  const kFilesLocalAccountId = 'flocal';            // server id 'local'
  String webDavAccountId(Uri url);                    // 'w' + first 16 hex of sha256(normalized url); server id the same
  class WebDavCredentials { String user; String password; String toJson(); static WebDavCredentials fromJson(String s); }
                                                       // stored with SourceSecrets as the account token
  // capabilities.dart
  abstract interface class MatchEditing {
    Future<List<TmdbCandidate>> searchMatches(ItemRef ref, String query, {int? year});
    Future<void> setMatch(ItemRef ref, TmdbCandidate? choice);    // null = unmatch
  }
  // files_media_source.dart
  class FilesMediaSource extends MediaSource implements WatchedState, Searchable, ContinueWatching, NextUp,
      RecentlyAdded, UnwatchedListing, MatchEditing {
    FilesMediaSource({required Source source, required FileSystemBackend backend, required FileLibraryIndex index,
                      required PlaybackProgressStore progress, required FileMatcher matcher, required RelayTmdb tmdb});
    FileSystemBackend get backend;
    FileLibraryIndex get index;
  }
  // files_scan_controller.dart
  class ScanState { final bool running; final int done; final int total; final Object? error; }
  final filesScanProvider = NotifierProvider.family<FilesScanController, ScanState, SourceId>(...);
  class FilesScanController { Future<void> rescan(); }   // scan every root, then matcher.matchPending(), then index.setLastScanAt
  ```
  Behaviour pinned by the spec and this plan:
  - `libraries()`: one `Library` per root (`id = root.id`, kind `movies`→`LibraryKind.movies`, `series`→`shows`, `mixed`→`videos`) plus `folders` (`LibraryKind.videos`, title from ARB `filesFoldersLibrary`) when any unmatched file exists.
  - `browse`: movies and shows with a file under that root; `mixed` returns both. Sorts `title` (by `sortTitle`, articles stripped), `added` (`firstSeen` desc), `released`; filter `unwatched`. Cursor is the decimal offset; page size from `BrowseQuery.pageSize`. `browse(folders)` lists each root as an `ItemKind.folder`.
  - `children`: show → seasons ascending with season 0 last; season → episodes ascending; folder → subfolders then unmatched files, by name.
  - `item`: `versions` are the item's files (`id = fileKey`, `container` from extension, `sizeBytes`, `streams` = sidecars as subtitle `MediaStreamInfo` with `externalPath`).
  - Watched: explicit flag, or progress `>= 0.9` of duration. In progress: `position >= 30s` and `< 0.9` of duration. `setWatched` writes the flag and invalidates `SourceRules.watchedChanged(id)` through `invalidatorProvider`.
  - `continueWatching`: in-progress items by `updatedAt` desc, at most 20. `nextUp(show)`: first unwatched episode with a file after the last watched one (season 0 excluded); the first episode when none is watched. `recentlyAdded`: by `firstSeen` desc, 20. `unwatchedListing`: movies plus shows with an unwatched episode, pages of 50. `search`: titles whose `identity_key` contains the query's, at most 50.
  - `artwork`: size bucket is the smallest of `w92 w154 w185 w342 w500 w780` at or above `width`, else `original`; cache key `sourceId|path|bucket`; no headers.
  - Status: `probe()` on open; success → `local`, `BackendFailure.unauthorized` or `.permissionLost` → `_flagReauth` and `unreachable`, other failures → `unreachable`. Browsing reads the index whatever the status.
  - `onGroupLanded` invalidates `SourceOps.browse`, `item`, `children`, `continueWatching`, `recentlyAdded`, `unwatched` for this source via `SourceKeys.family`.
  - Building the source starts `rescan()` when `lastScanAt` is null or older than 6 hours.
  - Web: `files` accounts are filtered out like other third-party sources (`web_sources_test.dart`).

- [ ] **Step 1: Tests.**
  - `files_media_source_test.dart` calls `runMediaSourceContract('Files', ...)` over an index seeded with one movie (two versions), one show (S01E01 to E03, S00E01), and one unmatched file.
  - Plus: `mixed_library_lists_movies_and_shows`; `folders_library_only_when_something_is_unmatched`; `specials_sort_last_and_next_up_skips_them`; `watched_by_flag_or_ninety_percent`; `continue_watching_ignores_under_thirty_seconds`; `artwork_bucket_rounds_up_and_caps_at_original`; `unreachable_backend_still_browses` (Review Focus 4); `unauthorized_flags_reauth`.
  - `files_scan_controller_test.dart`: `rescan_on_open_only_when_older_than_six_hours`; `scan_progress_is_exposed`.
  - Existing `source_rules_test.dart` and `web_sources_test.dart` cover the new kind once the enum value exists; fix any exhaustive switch the analyzer flags.
- [ ] **Step 2:** Run `./dev flutter test test/core/sources/`. Expected: new tests FAIL, existing ones still pass.
- [ ] **Step 3:** Implement; regenerate with `./dev flutter pub run build_runner build` if providers are generated; add ARB strings `sourcesAccountFiles`, `filesFoldersLibrary`, `filesThisDevice`.
- [ ] **Step 4:** Run `./dev flutter test test/core/sources/` and `./dev flutter analyze`. Expected: PASS, clean.
- [ ] **Step 5:** Commit: `feat(player): files source over the local index`.

### Task 9: `FilesPlaybackSession`

**Files:**
- Create: `player/lib/presentation/screens/player/session/files_playback_session.dart`, `player/lib/core/player/local_progress_reporter.dart`
- Modify: `player/lib/presentation/screens/player/session/source_playback_sessions.dart`
- Test: `player/test/presentation/screens/player/session/files_playback_session_test.dart`, `player/test/core/player/local_progress_reporter_test.dart`

**Interfaces:**
- Consumes: `FilesMediaSource.backend`, `FilesMediaSource.index`, `SourcePlaybackSession`, `StreamResolver`, `ResolvedStream`, `containerMime`, `PeriodicProgressReporter`, `PlaybackProgressStore`.
- Produces:
  ```dart
  class FilesPlaybackSession extends SourcePlaybackSession { FilesPlaybackSession({required FilesMediaSource source, required super.item, required super.fileId}); }
  class FilesStreamResolver implements StreamResolver { ... }   // resolve → backend.playable(path); end → no-op
  class LocalProgressReporter extends PeriodicProgressReporter { LocalProgressReporter({required PlaybackProgressStore store, required ItemRef item, required Future<void> Function() onSaved}); }
  ```
  `features` is empty (no cast). `candidatesFor` returns one `DIRECT_PLAY` strategy with `containerMime(version.container)`. `fetchText(path)` reads a sidecar through `backend.playable` (HTTP GET with headers for WebDAV, `File.readAsString` for local). `LocalProgressReporter` saves `LocalPlaybackProgress` and calls `onSaved`, which invalidates `SourceRules.watchedChanged`.

- [ ] **Step 1: Tests:** `direct_play_only`; `resolver_returns_backend_url_and_headers`; `missing_file_surfaces_folder_unavailable` (backend `stat` null → the session reports a `PlaybackProblem` whose message is ARB `filesFolderUnavailable`); `sidecars_become_subtitle_tracks`; reporter `saves_progress_under_progress_key`.
- [ ] **Step 2:** Run; FAIL. **Step 3:** Implement; add the `FilesMediaSource()` arm to `playbackSessionFor`. **Step 4:** Run; PASS.
- [ ] **Step 5:** Manual: `rclone serve webdav --addr :8090 --user u --pass p <dir with invented-title files>`; add it on desktop (after Task 10) and play, seek and resume one file.
- [ ] **Step 6:** Commit: `feat(player): direct play from files libraries`.

### Task 10: Add Folder and Add WebDAV

**Files:**
- Create: `player/lib/presentation/screens/sources/add_folder_screen.dart`, `.../sources/add_webdav_screen.dart`, `.../sources/files_library_kind_picker.dart`, `player/lib/core/sources/files/files_accounts.dart`
- Modify: `player/lib/presentation/screens/sources/add_source_screen.dart`, `player/lib/core/router/app_router.dart` (`/sources/add/folder`, `/sources/add/webdav`, next to `/sources/add/stash`), `.../sources/manage_sources_screen.dart` (roots, Rescan, Remove folder), `player/pubspec.yaml` (`file_selector`), ARB files
- Test: `player/test/presentation/screens/sources/add_webdav_screen_test.dart`, `.../add_folder_screen_test.dart`, `player/test/core/sources/files/files_accounts_test.dart`

**Interfaces:**
- Consumes: Tasks 4, 5, 8.
- Produces:
  ```dart
  Future<void> addLocalRoot(Ref ref, {required String path, required FilesLibraryKind kind});   // creates 'flocal' on first use
  Future<SourceId> addWebDavAccount(Ref ref, {required Uri url, required String user, required String password});
  Future<void> addWebDavRoot(Ref ref, SourceId id, {required String path, required FilesLibraryKind kind});
  Future<void> removeRoot(Ref ref, SourceId id, String rootId);
  Future<void> removeFilesAccount(Ref ref, String accountId);   // secrets, record, index.clear()
  ```
  Root id is `r` + first 12 hex of SHA-256 of the path. The WebDAV secret is written before the account record (`SourceSecrets` ordering in `player/lib/core/sources/README.md`). Adding a root triggers `rescan()`. Folder appears on Linux, Windows and macOS only in this phase (`!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)`); WebDAV everywhere except web.

- [ ] **Step 1: Tests:** `webdav_connect_tests_the_root_before_saving` (unauthorized → inline error, nothing stored); `webdav_lists_folders_and_saves_chosen_roots_with_kinds`; `folder_tile_hidden_on_mobile_and_web`; `adding_existing_webdav_url_reuses_the_account`; `remove_account_clears_index_and_secrets`.
- [ ] **Step 2:** Run; FAIL. **Step 3:** Implement with the same form widgets `stash_connect_screen.dart` uses; give every interactive widget a `Key`. **Step 4:** Run; PASS.
- [ ] **Step 5:** Commit: `feat(player): add local folders and WebDAV shares as sources`.

### Task 11: Scan banner, Folders view and Fix match

**Files:**
- Create: `player/lib/presentation/widgets/files/files_scan_banner.dart`, `player/lib/presentation/widgets/files/fix_match_sheet.dart`
- Modify: the library screen that renders `browse` results (add the banner when `source.kind == SourceKind.files`), the detail screen's action row (add "Fix match" when the source has `SourceCapability.matchEditing`; find it by grepping `setWatched(` under `player/lib/presentation/screens/detail/`), ARB files
- Test: `player/test/presentation/widgets/files/files_scan_banner_test.dart`, `.../fix_match_sheet_test.dart`

**Interfaces:**
- Consumes: `filesScanProvider`, `MatchEditing`.
- Produces: `FilesScanBanner({required SourceId sourceId})`, `showFixMatchSheet(BuildContext, MediaSource, ItemRef)`.

  Copy: banner `filesScanProgress` = "Scanning {done} of {total}" with grouped digits ("Scanning 312 of 2,040"). Sheet: title field prefilled with the item title, optional year field, results list (title, year, poster), "Unmatch" button. Folders view is the `folders` library from Task 8 rendered by the existing library screen; folders open with `children`.

- [ ] **Step 1: Tests:** `banner_shows_grouped_counts_and_hides_when_idle`; `fix_match_pins_the_chosen_result`; `unmatch_calls_set_match_with_null`; `fix_match_hidden_for_sources_without_the_capability`.
- [ ] **Step 2:** Run; FAIL. **Step 3:** Implement. **Step 4:** Run; PASS.
- [ ] **Step 5:** Run `./dev flutter analyze`, `./dev flutter test`, `scripts/check-rust.sh`, `cargo test --manifest-path server/Cargo.toml --all`. Expected: all clean.
- [ ] **Step 6:** Commit: `feat(player): scan progress, folders view and fix match for files libraries`. Open PR 1.

## Phase 2 (PR 2)

### Task 12: Device check for platform folders

Throwaway, not committed.

- [ ] **Step 1:** On an Android phone, pick a folder with `ACTION_OPEN_DOCUMENT_TREE` from a scratch branch, take a persistable grant, build a document URI for one `.mkv`, and open it with media_kit `Media('content://...')`. Record: plays, seeks, survives app restart.
- [ ] **Step 2:** On iOS, pick a folder with `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`, store a bookmark, restart, resolve it, `startAccessingSecurityScopedResource`, open a file path with media_kit. Record the same three results.
- [ ] **Step 3:** Report findings. If Android `content://` fails, skip Task 13 and leave Android on WebDAV; amend the spec's platform table.

### Task 13: Android SAF backend

**Files:**
- Create: `player/android/app/src/main/kotlin/dev/mydia/player/FolderAccessChannel.kt`, `player/lib/core/sources/files/backend/platform_folder_backend.dart`
- Modify: `MainActivity.kt` (register channel `dev.mydia.player/folders`), `add_folder_screen.dart` (show Folder on Android phones and tablets, not on TV: `PackageManager.FEATURE_LEANBACK` reported by the channel)
- Test: `player/test/core/sources/files/backend/platform_folder_backend_test.dart` (mocked `MethodChannel`)

**Interfaces:**
- Produces channel methods: `pick() -> {uri, name}?` (takes a persistable read grant), `list(uri, docId?) -> [{docId, name, isDir, size, modified}]`, `hasGrant(uri) -> bool`, `isTv() -> bool`. `PlatformFolderBackend implements FileSystemBackend` with paths as document ids; `playable` returns the `content://` document URI; `probe` throws `PermissionLost` when `hasGrant` is false.

- [ ] **Step 1:** Dart tests over a mocked channel: `lists_children`, `lost_grant_throws_permission_lost`, `playable_is_content_uri`. Run; FAIL. Implement; PASS.
- [ ] **Step 2:** Manual on a phone: add, scan, play, restart, play again; revoke in system settings and see "Choose the folder again".
- [ ] **Step 3:** Commit: `feat(player): Android folders through the Storage Access Framework`.

### Task 14: iOS bookmark backend

**Files:**
- Create: `player/ios/Runner/FolderAccessChannel.swift`, `player/lib/core/sources/files/backend/bookmark_folder_backend.dart`
- Modify: `AppDelegate.swift` (register `dev.mydia.player/folders`), `add_folder_screen.dart` (show Folder on iOS and iPadOS)
- Test: `player/test/core/sources/files/backend/bookmark_folder_backend_test.dart`

**Interfaces:**
- Produces channel methods: `pick() -> {bookmark (base64), path, name}?`, `resolve(bookmark) -> {path, stale}` (starts security-scoped access, refreshes a stale bookmark), `release(path)`. `BookmarkFolderBackend` resolves once on `probe`, then delegates `list`/`stat`/`playable` to a `LocalPathBackend` on the resolved path; a failed resolve throws `PermissionLost`. The bookmark is stored on `LibraryRoot` (add `String? bookmark`).

- [ ] **Step 1:** Dart tests over a mocked channel: `stale_bookmark_is_refreshed_and_saved`, `failed_resolve_throws_permission_lost`. Run; FAIL. Implement; PASS.
- [ ] **Step 2:** Manual on an iPhone and an iPad: add, scan, play, restart, play.
- [ ] **Step 3:** Commit: `feat(player): iOS folders through security-scoped bookmarks`. Open PR 2.
