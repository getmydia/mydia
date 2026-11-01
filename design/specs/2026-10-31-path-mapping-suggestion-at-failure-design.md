# Compute path-mapping suggestions when the import fails

Issue: #1315.

## Problem

The Downloads Issues tab and the download detail drawer suggest a
remote-to-local path mapping for every download whose import failed with
`path_mapping_mismatch`. `enrich_path_mapping_suggestions/1` in
`lib/mydia_web/live/downloads_live/index.ex` calls `MountRoots.detect/0` and
then `PathMapping.suggest/2` for each such download. The call is synchronous and
happens inside the LiveView.

`suggest/2` walks every detected mount root depth-first, up to 6 levels, looking
for a directory with the reported path's basename. The mount probe in
`MountRoots` is time-boxed to 250ms. The walk has no time or entry budget, so a
large, healthy mount (one big `/data` volume, a NAS share) gets walked in full,
once per mismatched download.

It repeats far more often than once per visit. The Issues tab reloads on every
`{:download_updated, _}` PubSub event (300ms debounce), on every
`:external_scan_updated`, and the drawer runs the enrichment again. With a large
mount the tab can stay frozen for minutes.

## Decision

Compute the suggestion once, in the background, when the import fails. Store it
on the download. The page only reads it.

`path_mapping_mismatch` is already a terminal failure in `Mydia.Jobs.MediaImport`
(`terminal_failure?/2`), so each failed download triggers exactly one search.
Downloads that failed before this change are covered by a one-shot backfill job.

Rejected:

- **Bound the walk but keep it at render time.** The page would still block for
  up to the budget on every reload.
- **ETS cache plus an async task from the LiveView.** It avoids a migration, but
  the cache is lost on restart, and wiring async results into a streamed list
  that reloads on every PubSub event is fragile.

## Schema

One migration on `downloads`, valid on both adapters (plain `add` columns, no
type changes):

| column | type | meaning |
| --- | --- | --- |
| `path_mapping_remote_prefix` | `:text` | suggested remote prefix, null when no suggestion |
| `path_mapping_local_prefix` | `:text` | suggested local prefix, null when no suggestion |
| `path_mapping_searched_at` | `:utc_datetime` | when the search ran, set whether or not it matched |

The two prefixes are both set or both null. `path_mapping_searched_at` makes the
backfill idempotent: a search that found nothing is never repeated.

Use a real timestamp for the migration filename and check remote branches for
collisions, as `AGENTS.md` describes.

`Download.changeset/2` casts the three fields. The `EnrichedDownload` struct and
the `history.ex` builders that copy `import_reported_path` (around lines 730,
780 and 853) also carry the two prefix fields.

## Search

`PathMapping.suggest/2` stays a pure function of `(reported_path, roots)` and
keeps its single-match rule: exactly one candidate directory returns
`{:ok, %{remote_prefix, local_prefix}}`, anything else returns `:none`. Two
changes:

1. **Suffix join first.** Split the reported path into its trailing slices
   (`X`, `complete/X`, `downloads/complete/X`, and so on, up to the full path
   without its leading `/`). For each root and each slice, check whether
   `Path.join(root, slice)` is a directory. Take the longest slice that matches
   anything, since a longer matched suffix is stronger evidence. If that slice
   matches exactly one distinct directory, return it, deriving `local_prefix`
   as its dirname and `remote_prefix` as the reported path's dirname, the same
   derivation as today. If it matches more than one, or nothing matches at all,
   fall through to step 2. This is a few `stat` calls and covers the common
   `/downloads/complete/X` to `/data/downloads/complete/X` layout.

2. **Bounded walk as a fallback.** The existing basename walk keeps its depth
   limit and gains two budgets for the whole call, across all roots: at most
   `@max_scan_dirs` directories visited (20_000) and `@max_scan_ms` of wall
   clock (5_000). Exceeding either returns `:none`. A partial walk cannot prove
   a match is unique, so it never returns a match. Both budgets are overridable
   through an options keyword for tests.

The walk keeps using non-`raw` `File` calls, for the reason given in
`MountRoots.reachable_dirs/2`. `MountRoots.detect/0` has already dropped
unreachable mounts before the walk starts.

## Write side

`Mydia.Jobs.MediaImport.Failure.handle_import_failure/4`:

- When `failure_reason_tag(reason) == "path_mapping_mismatch"`, call a new
  `PathMapping.suggestion_attrs(reported_path, roots \\ nil)`. It runs
  `suggest/2` (detecting roots with `MountRoots.detect/0` when `roots` is nil)
  and returns the three column values, with
  `path_mapping_searched_at` set to now in every case. Merge them into the
  existing `attrs` so everything is written in one update.
- For any other failure reason, set all three columns to nil, so a download
  never shows a suggestion left over from an earlier failure.

A crash inside the search must not lose the failure record: `suggestion_attrs/1`
rescues and logs, then returns null prefixes with the stamp set.

Clearing the import-failure fields must clear the three columns too. Today three
call sites do this by hand: `DownloadsLive.Retry` (`retry.ex:23`),
`DownloadsLive.Index.retry_mismatches_under_prefix/1` (`index.ex:1580`), and
`Mydia.Jobs.DownloadMonitor` (`download_monitor.ex:849`). Extract the reset map
into one function on the downloads context, for example
`Downloads.cleared_import_failure_attrs/0`, and use it at all three sites, so
the next field added cannot be missed.

## Backfill

New `Mydia.Jobs.PathMappingSuggestionBackfill`, following
`Mydia.Jobs.HdrBackfill`:

- Selects downloads with `import_failure_reason == "path_mapping_mismatch"`,
  `import_failed_at` not null, `import_reported_path` not null and
  `path_mapping_searched_at` null, in batches of 25.
- Detects mount roots once per batch and writes
  `PathMapping.suggestion_attrs(path, roots)` for each row, which stamps every
  row whatever the outcome.
- Re-enqueues itself while rows remain, with the same uniqueness setup as
  `HdrBackfill`, including its narrowed reschedule states.
- `enqueue_once/0` is called from `Mydia.Application.start/2` next to the
  other backfills, and never raises.
- Runs on an existing background queue (`:analysis` or similar), never on the
  import queue, so a slow walk cannot delay imports.

## Read side

`enrich_path_mapping_suggestions/1` in `DownloadsLive.Index` no longer touches
the filesystem. For mismatch downloads it builds
`%{remote_prefix:, local_prefix:}` from the two stored columns, or nil when they
are null. The affected count stays a DB query
(`Downloads.list_path_mapping_mismatches_under_prefix/1`), cached per remote
prefix within the batch as it is today.

There is no staleness check at render time: a `stat` there could hang on a
wedged network mount, which is the problem being fixed. A stale suggestion heals
itself. Applying it re-runs the import, the import fails again as a mismatch,
and that failure runs a fresh search.

Between the upgrade and the backfill finishing, old rows show the plain guidance
(the Path Mappings page link) that already renders when there is no suggestion.

## Testing

- `test/mydia/library/path_mapping_suggestion_test.exs`: suffix-join hit with no
  walk needed; longest slice wins; ambiguous longest slice falls through to the
  walk; directory budget exhausted returns `:none` even when a match exists past
  the budget; time budget exhausted returns `:none` (budgets passed as options;
  no sleeps). Existing single-match and ambiguity cases keep passing.
- `Failure` tests: a mismatch failure stores the suggestion and the stamp; a
  mismatch with no match stores null prefixes and the stamp; a different
  failure reason clears all three; a raising search still records the failure.
- Reset sites: each of the three call sites clears the three columns.
- Backfill job: fills unstamped rows, skips stamped ones, stamps rows with no
  match, reschedules while rows remain, and `enqueue_once/0` does not stack.
- LiveView: the Issues tab and drawer render a suggestion from the stored
  columns, and the enrichment calls neither `MountRoots` nor `suggest`. Assert
  this by giving the test a library path under a directory that would match if
  walked, with no stored suggestion, and checking that none renders.
- Migration: the existing `no_varchar_columns_test.exs` covers the column types.

## Out of scope

- Changing how `MountRoots` chooses roots.
- Recomputing suggestions when library paths or mounts change. The self-healing
  apply flow covers the practical case.
