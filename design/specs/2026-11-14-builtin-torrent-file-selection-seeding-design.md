# Built-in torrent client: selective files, seeding targets

Status: approved design, 2026-11-14. Answers part of issue #1403, Suggestion
2. Builds on `design/specs/2026-11-12-ui-builtin-torrent-vpn-design.md`.
Speed limits, the third goal of the original design, shipped separately in
#1406 and are out of this spec's scope (see "Speed limits" below).

## Goal

An operator using the built-in torrent client (rqbit) can:

1. Skip unwanted files in a torrent. Obvious junk (samples, trailers, `.nfo`,
   `.exe`, images) is skipped automatically, and the operator can change the
   selection from the Downloads page until the download is imported.
2. Set a seeding target: a ratio, a seed time, or both. A torrent seeds until
   whichever target it reaches first, then Mydia pauses it or removes it from
   the client, as the operator chooses. A tracker's own minimum must be met
   as well, so it can hold a torrent longer but never release it sooner.

Both are configured in the built-in client's settings and layered like
the rest of the `built_in_torrent` section (yaml, then database, then env).

## Where Mydia stands

- The built-in client is a synthetic `rqbit` row from
  `Mydia.Downloads.BuiltIn.client_configs/0`. It never sets `remove_completed`,
  so its torrents seed forever.
- rqbit 9.0.1 (`RQBIT_VERSION` in the `Dockerfile`) has no ratio or seed-time
  limit of any kind. Its HTTP API offers:
  - `POST /torrents/{id_or_hash}/update_only_files` with JSON
    `{"only_files": [0, 2]}`, which changes the file selection of a resolved,
    non-initializing torrent, paused or live.
  - `GET /torrents/{hash}`, whose `files[]` entries carry `name`,
    `components`, `length` and `included`; stats carry `file_progress[]`.
    For a paused or live torrent, stats `total_bytes` counts selected pieces
    only, so progress and completion follow the selection.
- `Mydia.Downloads.SeedingGoal` judges a goal from the tracker terms frozen on
  a download: met when the ratio or the seed time reaches its minimum,
  whichever comes first. `Mydia.Downloads.ClientRemoval.terms_met?/2` applies
  it before Remove After Import, for qBittorrent, Transmission, rTorrent and
  rqbit. `Mydia.Downloads.ObservedSeedTime` supplies seed time for rqbit,
  which reports none.
- `Client.Rqbit.list_files/2` (through `build_status/2`) already drops
  `included: false` files, so import and `DownloadMonitor`'s bad-content
  rejection only ever see selected files.
- `ImportCandidates.importable?/2` and `Mydia.Library.SampleDetector` decide
  what import takes and what it excludes as a sample, trailer or extra.

## Settings

New fields in `Mydia.Config.Schema.BuiltInTorrent`, with entries in
`@env_vars`, edited in the built-in client's settings modal through
`BuiltIn.Settings`:

| field | env | type | meaning |
| --- | --- | --- | --- |
| `seed_ratio` | `MYDIA_TORRENT_SEED_RATIO` | float, >= 0 | ratio target; blank = none |
| `seed_time` | `MYDIA_TORRENT_SEED_TIME` | integer minutes, >= 0 | seed-time target; blank = none |
| `seed_goal_action` | `MYDIA_TORRENT_SEED_GOAL_ACTION` | `"pause"` (default) or `"remove"` | what happens at the target |

With `seed_ratio` and `seed_time` both blank, behaviour is unchanged: built-in
torrents seed forever.

`BuiltIn.Settings` gains a float type for `seed_ratio` and a choice list for
`seed_goal_action`, stored as strings the overlay cast understands, as the
existing booleans and integers are. Env-set fields stay read-only.

None of the new fields joins `BuiltIn.Config.restart_key/1`: changing them
never restarts the engine. A reload that leaves the key unchanged still
publishes the new config on the running `Runtime` entry, where the policies
read it.

## Seeding targets

### Effective goal

The goal of a built-in download is a conjunction of two goals, each judged
on its own:

- the tracker terms, under the existing `met?/3`: met by whichever dimension
  comes first, met when the terms ask for nothing, and never met for a
  private tracker with no known ratio or seed time;
- the operator target: met when either its ratio or its seed time is
  reached. `seed_time` is converted from minutes to seconds.

`SeedingGoal` gains two functions for the decision:

    goal_applies?(download, opts) :: boolean()
    goal_met?(download, ratio, seeding_time, opts) :: boolean()

The goal applies when the tracker terms apply or an operator target is set.
It is met only when both halves are. Merging the two per dimension and
taking the first dimension met would be wrong both ways: a tracker's 72 hour
minimum would release a torrent the operator wants seeded to ratio 2.0, and
a private tracker with unknown rules, whose terms carry no minimums, would
be released by the operator's numbers alone (a ratio of 0 releases it at
completion).

A third function, `effective_terms/2`, still merges the two per dimension
(the larger requirement wins, nils ignored, `private?` carried), but only
for the numbers the Downloads page shows.

The operator target applies only to downloads on the built-in client. A
helper, `BuiltIn.seeding_target/0`, reads it from the running `Runtime`'s
config and returns `nil` when neither target is set.

### Enforcement

A new module, `Mydia.Downloads.BuiltIn.SeedingPolicy`, holds the rule.
`DownloadMonitor` calls it once per polled row whose client is the built-in
one and whose status is `:seeding`. It is one call, keeping the logic out of
the monitor.

When the effective goal is met and the row carries no
`metadata["seeding_goal_reached_at"]`:

- **pause**: call `Client.pause_torrent/3`. On `:ok`, stamp
  `seeding_goal_reached_at`. A stamped row is never paused again, so an
  operator who resumes it by hand keeps it seeding.
- **remove**, with `imported_at` set: leave it to removal (below).
- **remove**, not yet imported: pause and stamp as above. Removal follows
  once the import lands.

A failed pause writes no stamp, so the next poll retries.

### Removal

`BuiltIn.client_configs/0` sets the synthetic row's `remove_completed` to
`seed_goal_action == "remove"` when a seeding target is set. The existing
Remove After Import paths (`ClientRemoval.maybe_remove_after_import/1` and
`finish_pending_removal/2`) then do the removal, deleting the torrent's data
as they do today. The import already holds its own copy.

`ClientRemoval` reads the whole goal instead of the tracker terms alone:
`terms_met?/2` uses `SeedingGoal.goal_met?/4` and the `guarded?` check in
`remove_when_ready/3` uses `SeedingGoal.goal_applies?/2`. Both include the
operator target for the built-in client only, so every other client is held
to the tracker terms alone. One rule serves
both the post-import and the deferred path, and there is no second removal
loop.

### Display

The Downloads page's seeding-goal display (`MydiaWeb.SeedingComponents`, fed
by `SeedingGoal.for_download/2`) shows the tracker requirement and the
operator target separately, never merged: `required_*` are the tracker's
minimums (nil when it states none, so a private tracker with unknown rules
still reads "Private, kept seeding") and `target_*` are the operator's target
(nil when there is none). The chip adds a "target" part to the tracker part,
and the manual-removal hit-and-run warning states the tracker's requirement
as before, then a separate sentence that the seeding target is not yet
reached. `met?` is `goal_met?/4`. `for_download/2` takes the operator target
as an option and resolves it once per call.

## Selective files

### Adapter seam

Two optional callbacks on `Mydia.Downloads.Client`, with `Client` wrappers
that return `{:error, :unsupported}` when the adapter lacks them, as
`set_share_limits/3` does:

    @callback torrent_files(config(), client_id :: String.t()) ::
                {:ok, [TorrentFile.t()]} | {:error, Error.t()}
    @callback set_file_selection(config(), client_id :: String.t(), [non_neg_integer()]) ::
                :ok | {:error, Error.t()}

`Mydia.Downloads.Structs.TorrentFile` is a new struct: `index`, `path`
(relative to the torrent root), `size`, `included?`, `downloaded`.

Only `Client.Rqbit` implements them. `torrent_files/2` joins
`GET /torrents/{hash}` `files[]` with stats `file_progress[]` by index.
`set_file_selection/3` posts `update_only_files`. Both go through the
adapter's `guarded/2`. `list_files/2` is unchanged.

### Automatic junk skipping

`Mydia.Downloads.FileSelection` is a pure module: `keep(files)` returns the
indices to keep. A file is kept when import would take it
(`ImportCandidates.importable?/2` and not `SampleDetector.excluded?/1`, the
rules import itself uses) or when it is a subtitle (`.srt`, `.ass`, `.ssa`,
`.sub`, `.idx`, `.sup`, `.vtt`). Everything else is skipped. If nothing would
be kept, everything is kept, and `DownloadMonitor`'s existing bad-content
rejection decides the release as it does today.

A magnet has no file list until its metadata resolves, so selection cannot be
passed at add time. `SeedingPolicy`'s sibling hook,
`BuiltIn.FileSelectionPolicy`, runs from the same `DownloadMonitor` call for
built-in rows with no `metadata["file_selection"]`, once the client's file
list is non-empty and the torrent is not `:checking`. It calls
`set_file_selection/3` only when `keep/1` skips something, then stamps
`metadata["file_selection"] = %{"source" => "auto", "skipped" => n}`. A few
junk pieces fetched before the metadata resolved are accepted waste.

A failed call writes no stamp and is retried on the next poll, up to three
attempts (counted in the same metadata key). After that it stamps
`"source" => "auto_failed"` and stops.

### Manual checklist

The Downloads detail drawer
(`MydiaWeb.DownloadsLive.DetailDrawer`) gains a **Files** section for rows
whose adapter exports `set_file_selection/3`. It lists every file with a
daisyUI checkbox, its size and its progress, and has a Save button.

- Editable while the row's `imported_at` is nil, read-only after. Re-checking
  a file can therefore never restart a download that was already imported.
- Saving requires at least one file that import would take. Otherwise the
  release would be rejected as bad content, so the form shows an inline error
  instead of saving.
- A save stamps `"source" => "manual"`. The automatic pass never runs on a
  stamped row, so it never overrides a manual choice.
- Re-checking a file on a finished but not yet imported torrent sends it back
  to downloading. rqbit handles that natively, and import still waits for
  `:seeding`.
- A failed save shows a flash error and reloads the list from the client.

The file list is fetched when the drawer opens and on Save. It is not part of
the Downloads list poll.

## Speed limits

Out of scope here. Download and upload limits shipped separately in #1406
(`download_limit_kib`, `upload_limit_kib`, `MYDIA_TORRENT_DOWNLOAD_LIMIT`,
`MYDIA_TORRENT_UPLOAD_LIMIT`): rqbit gets them as its
`--ratelimit-download`/`--ratelimit-upload` flags, a change restarts the
engine through `BuiltIn.Config.restart_key/1`, and 16 KiB/s is the lowest
accepted limit.

## Errors

Every action here is best effort and safe to repeat. A stopped engine is
reported by `BuiltIn.guard/1` as a named reason, as everywhere else. No
failure blocks a download, an import or a removal that would have happened
without this feature.

## Testing

- `test/mydia/downloads/client/rqbit_test.exs` (Bypass): `torrent_files/2`
  joining files and progress, `set_file_selection/3` body shape and error
  mapping.
- `FileSelection`: season pack, sample folder, trailer, subtitles kept,
  `.nfo`/`.exe` skipped, all-junk fallback keeps everything.
- `SeedingGoal.effective_terms/2`: operator only, tracker only, max per
  dimension, minutes to seconds.
- `SeedingGoal.goal_met?/4`: a private tracker with unknown terms is never
  met under any target (ratio 0 included); a tracker minimum met first does
  not release a torrent short of the operator target, nor the reverse.
- `SeedingPolicy`: pauses once at the goal; no re-pause after a manual
  resume; remove mode leaves imported rows to removal and pauses unimported
  ones; a failed pause leaves no stamp; a private row with unknown terms is
  never paused.
- `FileSelectionPolicy`: waits for the file list, stamps once, never
  overrides a manual stamp, gives up after three failures.
- `ClientRemoval`: the operator target guards built-in removal; a private
  built-in row with unknown terms is never removed in remove mode; other
  clients are unchanged.
- `BuiltIn.Settings`: the new fields validate, cast and stay read-only under
  env.
- `BuiltIn.Manager`: a seeding-only reload refreshes the runtime entry
  without restarting the engine.
- LiveView (drawer): the Files section renders, saves, shows the
  no-importable-file error, and is read-only after import.

## Out of scope

- Issue #1403 Suggestion 1: listing the built-in client by default and
  disabling external clients instead of deleting them.
- The "Open Built-in" buttons opening an empty page. This shipped separately
  in #1406.
- The download directory: `download_path` already exists in the section.
- File selection for qBittorrent and Transmission. The adapter seam allows it
  later.
- A file picker before grabbing (rqbit's `list_only=true`).

## Docs

Update `lib/mydia/downloads/README.md`: the "Seeding guard and share limits"
section (operator target, effective goal) and the "Built-in client" section
(file selection, the new env vars). Ship in the same PR.
