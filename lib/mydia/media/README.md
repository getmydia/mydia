# Media data model: invariants and traps

Notes on the media data model that are not obvious from the schema and that have
each caused a shipped bug. Paths point at `lib/mydia/library/` as often as
`lib/mydia/media/`, because the two contexts share these tables.

## A TV media_file has media_item_id NULL

An episode's `media_files` row carries `episode_id`, and its `media_item_id` is
NULL. The show hangs off `episode.media_item`. On galactica that was 1763 of 2268
media files, so code gating on `media_file.media_item` drops nearly the whole
library without raising anything.

This has shipped twice. PR #430 fixed Recent Activity, which showed "Unknown
Media" for every TV watch. PR #439 fixed `Streaming.list_active_sessions/0`,
where `if media_file && media_file.media_item` made the admin dashboard report
nobody watching during a live TV stream.

The two associations are XOR by data shape, and reading the show off `media_item`
finds nil rather than raising, so the failure is a silent empty list.

Preload `episode: :media_item` and match the episode clause first, since a file
could carry both keys. When writing a test, use an episode fixture. A movie
fixture passes either way, which is why both bugs shipped green. The same split
applies to `Mydia.Playback.Progress` rows (`validate_one_parent/1`) and to
`Streaming.progress_content_id/1`.

## media_files.path is nil on every row

The legacy `media_files.path` column is nil on every production row (verified
2026-08-15 on galactica: 2288 of 2288, including all 353 movie files). The real
location is `relative_path` joined onto the preloaded `library_path`.

Reading it is a latent crash, not stale data. `Path.basename(nil)` raises
`FunctionClauseError` in `IO.chardata_to_string/1`, which kills the LiveView on
render. That is how the subtitle search modal took down the media detail page on
every click of Search (fixed in PR #467).

The column is unwritten in practice rather than structurally dead.
`populate_media_file_relative_paths` skips files sitting outside every configured
library path, leaving them with no `relative_path` and no `library_path_id`, and
never clears their `path`. On an install upgraded from a version that still wrote
`path`, that column is the only location such a row has left. `:path` is also
still castable in the main changeset.

Use `Mydia.Library.MediaFile.display_path/1`, which falls back absolute to
relative to legacy `path`, or `display_name/1`, which is never nil and yields
`"Unknown file"`. `display_path/1` returns nil for a fully orphaned row, so call
sites rendering a full path need `display_name/1` as the label fallback or they
render blank. `absolute_path/1` is right when you need a real filesystem path and
can tolerate nil, but preload `:library_path` first or it warns and returns nil.

Two things to watch. In `import_media_live`, `file.path` is a scanner struct with
a genuine path, not a `%MediaFile{}`. And `lib/mydia/library/file_renamer.ex:247`
still feeds `absolute_path/1` into `Path.basename/1` unguarded, left out of PR
#467 on purpose; it is a background rename, where erroring is probably better
than displaying a placeholder.

Component test fixtures that pass plain maps with invented fields hide this whole
class of bug. The modal test asserted against a map with a populated `path:` that
production never has, so 20 tests passed over a crash on every real file.
Fixtures for component tests should be real structs in production shape.

## Never restore unique_index(:media_files, [:path])

`media_files_path_index` does not exist on master, on either adapter.
`20251115185757_make_media_files_path_nullable.exs` dropped it deliberately when
`path` became nullable. It was not lost in a SQLite table rebuild.

Adding it back turns `test/mydia/jobs/media_import_test.exs` from 57 tests / 0
failures into 57 / 2 on both adapters. `duplicate_media_file_scenario/1` (around
line 1580) creates two `media_files` rows with the same `relative_path` in a
`for _ <- 1..2` loop on purpose, and `media_file_fixture/1` derives `path` from
`relative_path`, so both rows collide. Constructing that duplicate is the point
of the test. The index also guards nothing in production, since `path` is nil
everywhere.

If a `media_files` migration ever rebuilds the table on SQLite, recreate the
other indexes and leave this one out. And when a test failure implicates a schema
constraint, verify against an actual `origin/master` worktree. `git stash` cannot
detect this, because stashing application code leaves the migration already
applied to the test database.

## Every "does this item have files" query counts every media_file

Roughly a dozen queries answer that question by counting or existence-checking
`media_files` rows with no filter beyond `trashed_at`. Persisting a new kind of
row that is not real content breaks all of them at once, and the damage lands in
modules far from the one you changed. This was hit during the movie-extras work
(PR #596), which produced three separate regressions before the catalogue below
was complete.

The severe failure mode is invisible, because a movie or episode holding only
bonus content reads as owned:

- `Mydia.Media.movies_needing_search/1` and
  `Mydia.Jobs.MovieSearch.load_monitored_movies_without_files/0` left-join files
  and keep only items with `having count(mf.id) == 0`, so the item is excluded
  from search permanently.
- `Mydia.Downloads.Queue` skips the grab and logs "media files already exist for
  movie", which reads like success.
- `Mydia.Library.episode_has_media_file?/1`, consumed only by
  `MediaImport.skip_already_filed_episode?/2`, makes a season-pack import skip
  the episode's real file. Combined with the fixed search path this sustains
  itself: searched and grabbed forever, imported never.

Less catastrophically affected: `Media.get_media_status/1` (the movie clause is
literally `has_files = media_item.media_files != []`, so the Downloaded badge
lies), `owned_media_item_ids/1`, `media_live/index.ex`'s two preloads,
`Playback.OnDeck.load_movie_files/1` and `load_episodes_with_files/1`,
`Upgrades.analyzed_files_query/0` and its `analyzed_movie_ids/0` /
`analyzed_episode_ids/0`, `TvShowSearch`'s three episode joins,
`Media.list_episodes_by_air_date/3`'s raw `EXISTS` fragment, `Queue`'s episode
checks, and `WatchStatus.load_shows/2`.

Two traps when fixing these. The `count == 0` queries are LEFT joins, so the
condition belongs in the join's `on:` clause; putting it in a `where:` filters the
item row rather than the joined files and inverts the fix, and a naive test can
still pass. And some queries must stay unfiltered: the analysis workers
(`FileAnalysis`, `HdrBackfill`, `SegmentDetectionScheduler`) need every row,
because analysis produces the duration a classifier later reads. Also leave alone
`import_groups` (it operates on `media_item_id IS NULL`), `Prune.Grouping` (it
needs to see them to refuse those groups), trash cleanup, `nfo_writer`,
`target_resolver`, and `media_live/show/loaders.ex`, whose detail page must see
them to display them. `Library.torrent_already_imported?/2` matches on download
provenance rather than ownership, so filtering it would be wrong.

Before persisting any new category of `media_files` row, grep
`is_nil(mf.trashed_at)|is_nil(f.trashed_at)` across `lib/` and triage every hit
against those two lists. `Mydia.Library.MediaFile.versions/0` (untrashed and
`extra_kind IS NULL`) is the shared seam for the real-content case, and
`active/0` is untrashed-only. Prefer them to hand-writing the predicate.
`SampleDetector`'s path layer is media-type agnostic, so a TV library gets
flagged rows even when a feature is scoped to movies.

## Multi-file items are mostly misidentification, not quality duplicates

Measured on galactica 2026-08-20 across 3437 active `media_files`: 518 episodes
and 39 movies have more than one active file, and most are not redundant copies.

Of the 518 episodes, 137 hold files from two different show folders
(misidentification, for instance one row carrying both
`Comme des têtes pas de poule S03E24` and `Les mots de Passe-Partout S03E24`),
153 have two rows with an identical `library_path_id` plus `relative_path` (one
file on disk registered twice), and 228 are same-show distinct paths. Only that
last group contains genuine duplicates, and within-show cross-episode
misidentification hides in it too: one row held `Star.trek.TOS.s01e07`, `s02e07`
and `s03e07`, and `FROM S04E02` held files titled "Fray" and "Crepe".

Of the 39 movies, 30 have one feature-sized file plus bonus content rather than
duplicates. Monsters University has 21 files, a 4.6 GB feature plus
`Campus Life.mkv`, `Easter Egg.mkv` and trailers, sitting loose in the movie
folder where `SampleDetector`'s Plex-extras-folder and keyword rules do not catch
them.

Any "keep the best, trash the rest" sweep therefore destroys real media, since
only about 44% of TV cases and 23% of movie cases are true redundancy. Gate on
proof of same content before ranking. Duration is the usable signal, present on
3355 of 3437 files, and it rejects all 137 cross-show cases, none of which fall
within 60s. It is not sufficient alone, since `FROM`'s Fray and Crepe are 34s
apart, so pair it with `ReleaseParser.parse_with_path/2` plus `TargetContext`,
which already sets `:binding_suspect` and `:parsed_title_unbound`.

`phash` is populated on 0 of 3437 files, so there is no content-identity hash
available. `analyzed_at` is on 3357 and `fingerprint_blob` on 2197. Also, 148 of
237 media_items have a quality profile and no `media_file` carries a
`quality_profile_id`, so `Upgrades.Comparator` needs a fallback ranker.

That ranking fallback must put bitrate above codec. Jujutsu Kaisen S03E03 has
1080p h264 at 8.8 Mbps (1.58 GB), h264 at 5.0 Mbps, and av1 at 2.9 Mbps (520 MB);
codec-before-bitrate keeps the 520 MB av1 and trashes the source.

This shipped as the prune feature in PR #520, with the admin page now at
`/admin/config/duplicates` (`MydiaWeb.AdminDuplicatesLive`) after PR #522. The
backend context is still `Mydia.Library.Prune`. The gate lives in
`Mydia.Library.Prune.Eligibility`, where the 2% duration tolerance and the
codec-ranks-last rule are module attributes with the reasoning in their
moduledocs. Selection is stored as the operator's Keep choices, and the page has
one Keep/Trash radio pair per file row with no separate keeper widget: the keeper
is the best-ranked copy still on Keep, so trashing the top row promotes a
successor rather than emptying the item, which is why `Ranker.decide/2` returns
losers in rank order.

Two known gaps. The page holds `decisions` and `refusals` in assigns rather than
streams, measured at 9756 bytes per group and about 5.2 MB at galactica's 557
groups, bounded and per-open-page, deferred to issue #523; every handler
enumerates `decisions`, so streaming needs a parallel compact index and getting
the selection math wrong trashes real files. And hyphen-slug filenames
(`Muppets-Most-Wanted-2014-1080p.mkv`) fail `ReleaseParser` title extraction, so
those movies are refused rather than pruned, which fails safe.

## An empty scan trashes the whole library

A library scan returning zero files classifies every existing `media_file` under
that path as deleted and physically moves the bytes to the trash store. There is
no empty-scan guard.

The chain, verified 2026-08-15:

1. `Scanner.detect_changes/3` (`lib/mydia/library/scanner.ex:128-139`) computes
   `deleted_files` as every existing `media_file` whose absolute path is absent
   from the scan result, so an empty scan means all deleted.
2. `lib/mydia/jobs/library_scanner.ex:529-545` calls `Library.trash_media_file/1`
   on each. Its comment claims these files are missing from disk, "the one case
   `trash_media_file/1` has nothing to move". That assumption is what breaks.
3. `TrashStore.store/1` (`trash_store.ex:105`) checks `File.exists?(source)`,
   finds it true, and moves the bytes into `.mydia-trash/<id>/`.
4. `Mydia.Jobs.TrashCleanup` runs daily at 05:00 and permanently deletes the row
   and the bytes after `@default_retention_days 30`.

`validate_directory/1` (`scanner.ex:172-188`) only catches a missing or
unreadable directory, not a readable one with zero matching files.

Two real triggers: an unmounted network share, and a library whose type does not
match its contents. `extensions_for_library_type/1` returns video extensions only
for `:movies`, `:series` and `:mixed`, so pointing a `:mixed` library at a music
or image directory scans to zero.

The durable fix is for `process_scan_result/2` to refuse the deletion pass when
`scan_result.files == []` and `existing_files != []`. Not yet implemented; it was
left out of the MBA removal branch as scope expansion.

## library_paths.disabled is one-way

Setting `disabled` hides a library path permanently, with no way back through the
UI.

`Mydia.Settings.LibraryPaths.list_library_paths/1`
(`lib/mydia/settings/library_paths.ex:16`) filters
`where([l], l.disabled == false or is_nil(l.disabled))`, so disabled rows never
leave the context, and `AdminLibraryPathsLive.Index` sources its page from that
function. The edit modal has no form field bound to `:disabled` and no handler
clears it, while `monitored` is an editable checkbox
(`admin_library_paths_live/components.ex:111-117`).

The admin component renders a "Disabled" section (`components.ex:52-57`) that can
never populate. It was dead the day it was written: the context filter landed in
`c8ff9713` (2025-12-25), the component section in `dd42289a` (2026-04-03).

If code needs to take a library path out of service in a way an operator can
undo, set `monitored: false`. The MBA removal migration was written with
`disabled` first and had to be corrected for this reason. Fixing the dead section
properly means either exposing disabled paths through `list_library_paths/1` so
the section renders and the modal offers a way back, or deleting the section.
They are a matched pair.

## TV season monitoring is derived, not stored

Mydia does not copy Sonarr's `seasons` table. Season monitoring state is derived
from the episode rows (`Media.season_monitoring_state/1`), and the menu label is
derived too (`Media.derive_monitoring_preset/1`, falling back to `:custom`).

The deciding argument, if this is ever revisited: Sonarr needs season records
because its UI lists provider-announced seasons before any episodes exist, so a
user can unmonitor an empty season. Mydia renders seasons by grouping existing
episode rows, so that state is neither visible nor settable. A seasons table
would buy two sources of truth that can disagree.

What is stored is `media_items.monitor_new_seasons` (`:all | :none`), because a
season that does not exist yet has no episodes to inherit from. It has to stay
independent of the presets. Inferring it from the applied preset (tried
2026-08-13, reverted) makes two states unreachable: keeping everything currently
monitored without chasing new seasons, and setting the flag at all without a bulk
rewrite that destroys hand-curated per-season monitoring. It also lets a preset
contradict itself, since `:future` unmonitors every aired episode while implying
new seasons are wanted.

Admission order for a newly discovered episode (`should_monitor_new_episode?/2`):
show unmonitored gives false; a season that already has episodes gives
`any?(monitored)`; season 0 gives false; otherwise `monitor_new_seasons`.

Any path that empties a season erases its intent. `provider_switch.ex` deletes
all episodes before re-upserting, so it captures the per-season verdict first and
replays it. A new delete-and-recreate path needs the same.

## The :existing preset is what enables the Upgrades sweep

`lib/mydia/upgrades.ex:99` filters upgrade candidates on
`e.monitored == true and m.monitored == true`. The `:existing` TV monitoring
preset (monitor only episodes that have files) is therefore the enabling
condition for episode upgrades, and it is the only way to express "upgrade the
quality of the files I have, but stop searching for the episodes I never found".

This preset was deleted on 2026-08-13 on the reasoning that it duplicated the
Upgrades system. That was backwards, a reviewer caught it, and it was restored in
the same branch.

Before trimming any monitoring preset, check what reads `episodes.monitored`.
`Mydia.Upgrades` and `tv_show_search.ex` both gate on it and want opposite
things: search targets monitored episodes without files
(`tv_show_search.ex:616`), upgrades target monitored episodes with files. A
preset that looks pointless for one is often load-bearing for the other.

## The season-refresh throttle silently skips the episode leg

`Media.refresh_episodes_for_tv_show/2` gates its whole season and episode fetch
behind `should_skip_season_refresh?/1`, which compares
`media_items.seasons_refreshed_at` against
`config.media.season_refresh_threshold_hours` (default 24), or
`completed_show_refresh_threshold_hours` (default 168) when the metadata blob's
status is ended or canceled.

It used to apply to the UI button too. A user clicked Refresh metadata, the
media_item row updated and the flash said success, while episodes went untouched
with nothing saying so. Confirmed on production 2026-08-19: Black Clover, stamped
2026-08-17T19:09Z, status Ended, so a refresh 33h later did nothing to its
episodes.

PR #499 fixed it. `refresh_episodes_for_tv_show/2` and `Refresh.run/2` take
`:force`; the show page's button and the manual-match API endpoint pass
`force: true`, and the weekly `MetadataRefresh` sweep does not, because the
throttle is what it was sized for. Any new user-initiated refresh path has to
pass it, since the default is still `false`.

`should_skip_season_refresh?/1` reads the struct handed to it, not the row, so a
test that stamps and then passes the stale struct passes for the wrong reason.
Reload first.

Never prescribe "refresh the metadata" as the remedy in a user-facing error. Make
the feature self-healing on the path that needs the data, the way
`SeasonOrder.switch/3` backfills `provider_episode_id` itself.

## Favorites is a per-user system collection

There is no favorites table. `Mydia.Collections.get_or_create_favorites/1`
creates a per-user system collection, `toggleFavorite` adds or removes a
`collection_items` row, and the `favorites` GraphQL query reads that collection
ordered by `asc: position`. It is not ordered by date added.

This was deliberate. Migration
`20251228233656_migrate_favorites_to_collections.exs` folded a former
`user_favorites` table (created by `20251225044807_create_user_favorites.exs`)
into collections.

Anything implementing favorites has to build collections storage underneath it.
That bit the Mydia Server Slice 4 design, where the plan was to ship favorites
while leaving collections out of scope; the tables have to land regardless, even
if the `collections`, `collection` and `collectionItems` queries stay stubbed.
When a favorites rail orders wrongly, check `position` before suspecting
timestamps.

## Mydia.Collections bypasses Mydia.Media

`Mydia.Collections` does not go through `Mydia.Media`.
`list_collection_items/2` queries `collection_items` and preloads `:media_item`
directly, `preview_smart_rules/2` builds its own `MediaItem` query, and
`is_favorite?/2` queries `collection_items` on its own.

Any filtering, scoping or authorization added to the `Media` context is
therefore absent from every collection and from Favorites. A smart collection
matching the whole library exposes the whole library.

When adding a rule that limits which media items a caller may see, treat
`Mydia.Collections` as a second enforcement point and change those three
functions. Apply the filter to a joined and selected `MediaItem` binding rather
than to a preload, and keep `order_by: [asc: ci.position]` on the manual clause.

## Repo.insert/update are guarded; the *_all variants are not

Shipped 2026-08-27 in PR #591 (issue #587), merge `97d76eac3`.

`Mydia.Repo` uses `defoverridable` and `super` on `insert/1,2`, `update/1,2` and
`insert_or_update/1,2`, delegating to `Mydia.Repo.ForeignKeyGuard`. That converts
`ecto_sqlite3`'s nameless foreign key violations (`[foreign_key: nil]`, because
SQLite does not report which constraint failed) into `{:error, changeset}`
instead of a raised `Ecto.ConstraintError`. It attributes the failure by walking
the changeset's declared FK constraints to their `belongs_to` and
existence-checking each. On PostgreSQL it is a strict no-op, handling only
`type: :foreign_key` with `constraint: nil`.

The coverage boundary is the thing to remember. A write with no changeset has
nothing to attach an error to:

- `Repo.insert_all/3`, `Repo.update_all/2,3` and `Repo.delete_all/1,2` are
  uncovered.
- Bang functions (`insert!`, `update!`) bypass it, calling `Ecto.Repo.Schema`
  directly. That is intended, since they are documented to raise.
- `Ecto.Multi` is covered, because it dispatches via
  `apply(repo, changeset.action, ...)`.

An uncovered write with a client-supplied FK raises the raw driver error
(`Exqlite.Error` or `Postgrex.Error`) rather than `Ecto.ConstraintError`, because
Ecto only translates driver errors against a changeset's declared constraints.

Two such sites were fixed by checking ids up front and are the pattern to copy:
`Collections.add_items/2` and `Media.update_media_items_batch/2`. The latter
raised on both adapters, so it was never a SQLite-only bug. An audit at the time
found 18 client-facing write paths carrying a client-supplied FK, and 16 needed
no edit.

The per-site rescue approach does not hold. #585 added one to
`TrackSettings.set_offset/3`, #588 added a verbatim copy to `record_resync/4` the
next day, and both were deleted in #591.

When adding a write that takes a client-supplied id, use a changeset write and
you get this for free. If you reach for `insert_all`, `update_all` or
`delete_all`, you own the id validation. Ecto does not bless overriding repo
write callbacks, so if a major Ecto upgrade breaks compilation in
`lib/mydia/repo.ex`, this is why. `test/mydia/repo/foreign_key_guard_test.exs`
pins the behavior.

## CandidatePromotion locking runs only on PostgreSQL

`Mydia.Library.CandidatePromotion` serializes a group promotion differently per
adapter, and one whole function is unreachable on the default test adapter.

On SQLite, `commit_group/4` opens `Repo.transaction(..., mode: :immediate)`,
taking the single writer lock up front, and `lock_group/1` returns `:ok` without
locking. On PostgreSQL, `lock_group/1` locks the `library_paths` row
`FOR UPDATE`, then calls `lock_candidates/1`, which takes candidate row locks
ordered by id.

So `lock_candidates/1` never executes under SQLite. Since SQLite is the default
for dev, test and most self-hosted deploys, a defect there passes a fully green
local suite and appears only in the PostgreSQL CI job.

Found exactly that way on 2026-08-31. The import-pipeline-split branch was green
on SQLite (9762 tests) and had passed a whole-branch review, but its first
PostgreSQL run returned 3 failures. `lock_candidates/1` returned a bare
`{:error, :candidate_missing}` while every sibling error in the module carries
the offending row's id, including `reread_candidates/1`, which is what SQLite
surfaces for the same condition. Callers saw a different error shape depending on
the adapter. Fixed in `32820f75c`.

Two traps when reading this module. `promote_group/3` does
`candidates = Enum.sort_by(candidates, & &1.id)` and rebinds before
`commit_group`, `lock_group` and `lock_candidates` see the list, so `ids` is
always id-ascending and matches the locking query's `order_by(asc: candidate.id)`
even though `ImportCandidates.load_all_members/2` hands `accept_group/2` its
members ordered by `relative_path`. Reading the caller chain without reading
`promote_group`'s body above its `with` produces a convincing but wrong "order
mismatch" theory. And `candidate_promotion_test.exs`'s two-candidate test asserts
`{:error, _reason}` with a wildcard, so a wrong error satisfies it as well as the
right one; the only success-path promotion test used a single candidate, leaving
multi-member promotion success unpinned until `32820f75c` added a regression.

When touching promotion locking, ownership transactions, or anything under
`DB.postgres?()` / `DB.sqlite?()`, run the PostgreSQL suite before claiming done.
A local PostgreSQL is available via devenv.
