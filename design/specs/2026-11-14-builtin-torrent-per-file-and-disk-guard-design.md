# Built-in torrent client: wanted files, early import, disk-space guard

Status: draft for review, 2026-11-14.

## Goal

Make the built-in torrent client do things an external client wired up over
an API cannot:

1. **Wanted files.** From a multi-file torrent (a season pack, a release with
   extras), download only the files Mydia will import.
2. **Early import.** Import each wanted file as soon as it is complete, so a
   season pack's episodes reach the library one by one instead of all at the
   end.
3. **Disk-space guard.** Never start a download that will not fit, and pause
   rather than fill the disk when space runs out while downloading.

Success: grabbing a 10-episode pack for a show with episodes 1 to 4 already in
the library downloads 6 episode files, episode 5 is in the library minutes
after its last piece arrives, and a grab that cannot fit is refused with a
reason the user can read.

## Where Mydia stands

- The built-in client is `rqbit server` (pinned `RQBIT_VERSION=9.0.1` in the
  `Dockerfile`) run by `Mydia.Downloads.BuiltIn.Engine` and driven by
  `Mydia.Downloads.Client.Rqbit`, the same adapter that drives a user-run
  rqbit (`design/specs/2026-11-04-builtin-torrent-vpn-design.md`).
- `Client.Rqbit.add_torrent/3` posts to `/torrents` and never passes a file
  selection. `resolve_torrent_files/2` already drops files rqbit reports as
  `included: false`, so import sees only selected files once a selection
  exists.
- rqbit's HTTP add has no `paused` option; the adapter pauses after adding.
- `DownloadStatus.files` is a list of paths with no per-file progress.
- `MediaImport` accepts `target_files` (`[%{"path", "episode_id"}]`) for
  targeted imports, is unique per `download_id`, and after a full import
  stamps `imported_at`, runs `FileImport.detect_partial_pack/2` and may remove
  the torrent through `ClientRemoval`.
- Automatic searches (`Jobs.MovieSearch`, `Jobs.TvShowSearch`) grab the best
  result; a failed grab is logged as `download_initiation_failed` and retried
  on the next scheduled search, not by trying the next candidate.
- Nothing in Mydia measures free disk space.

### rqbit 9.0.1 API used here (checked against the librqbit source)

- `POST /torrents?list_only=true` resolves metadata (for a magnet, over DHT
  and trackers) and returns `details.files` (`name`, `components`, `length`,
  `included`) in index order plus `seen_peers`, without adding the torrent.
- `POST /torrents?only_files=0,3,4&initial_peers=<addr,...>` adds with a
  selection. `initial_peers` seeds the second resolution with the peers the
  first call found, which is what rqbit's own web UI does.
- `GET /torrents/{id}/stats/v1` returns `file_progress`, bytes held per file
  index.

## Decisions and why

- **List, select, then add.** `list_only` first, then one real add with
  `only_files`. Adding first and deselecting after races the engine, which
  creates every file and fetches pieces before the selection lands. Listing
  first costs a second metadata resolution for magnets, shortened by
  `initial_peers`; for a `.torrent` file it costs nothing. It also lets the
  disk guard check exact sizes before anything is added, so a refusal leaves
  nothing to clean up.
- **The adapter stays ignorant of the library.** It gains an optional
  `list_torrent_files/2` callback and two add options; `Queue.ClientSelection`
  lists, decides and adds. Clients that do not export the callback add
  everything, as today.
- **rqbit only.** The feature lives in `Client.Rqbit`, so a user-run rqbit
  gets it too. qBittorrent and Transmission could implement the same option
  later; nothing here depends on the client being the built-in one.
- **Disk guard on the built-in client only.** Mydia cannot see an external
  client's disk, which may be on another host.
- **Selection failure never blocks a grab.** If listing or selecting fails,
  the adapter adds the torrent with every file, logs a warning, and the
  download behaves as it does today.
- **Partial seeding is accepted.** A torrent with a selection only seeds the
  pieces it holds. The seeding guard and observed seed time work unchanged;
  the docs say that a partial pack contributes less to a private tracker's
  swarm.

## Wanted files

### Selection rule

`Mydia.Downloads.FileSelection.select(context, files)` returns a
`%FileSelection{}`. `context` carries the media item, the release's season
number and the episode ids the search targeted (`metadata.episode_ids`).
`files` is `[%{index, path, length}]` from `list_torrent_files/2`.

For each file:

| File | Kept |
| --- | --- |
| Video whose name parses (`Mydia.Library.ReleaseParser`) to episodes of this show, at least one of them targeted or without a file | yes |
| Video whose episodes are all untargeted and already have a file | no |
| Sample, trailer or extra (`SampleDetector.detect/1`, path rules only) | no |
| Subtitle whose base name matches a kept video | yes |
| Video or subtitle that does not parse or does not match | yes |
| Anything else (`.nfo`, `.txt`, `.jpg`, `.url`, `.exe`) | no |

"Has a file" uses the rule `Queue.Duplicates` already applies: a
`MediaFile` with that `episode_id`, not trashed, `extra_kind` nil. Episodes
the search targeted are always kept, which covers quality upgrades: a search
that grabs a pack to upgrade episodes targets those episodes.

Movies and single-episode grabs keep every file except samples, extras and
junk.

The selection keeps every file (`only_files: nil`) when nothing would be
dropped, and when every video would be dropped (a pack that adds nothing is not this feature's call
to make; the duplicate check already handles it).

`SampleDetector` checks that read file size or contents are skipped: at
selection time nothing is on disk. Only the path rules apply.

### Adapter and grab

`Client` gains the optional callback
`list_torrent_files(config, torrent_input) :: {:ok, %{files, peers}} |
{:error, Error.t()}` (rqbit: `POST /torrents?list_only=true`), and
`add_torrent_opts` gains `only_files: [index]` and `initial_peers:
[String.t()]`, which `Client.Rqbit` sends as comma-joined query params and
other adapters ignore.

`Queue.ClientSelection`, after choosing the client and before adding:

1. If the adapter exports `list_torrent_files/2`, list. On error, warn and
   add with no selection.
2. `FileSelection.select/2`. If it raises, warn and add with no selection.
3. Disk guard check (see below); a refusal returns
   `{:error, {:client_error, Error.insufficient_space(...)}}` and adds
   nothing.
4. Add with `only_files` (omitted when everything is kept) and
   `initial_peers`.

`select_and_add_to_client/2` returns the `%FileSelection{}` (or nil) as a
fifth tuple element, and both callers (`Queue.Lifecycle.initiate_download/2`
and `Grabber.run_grab/3`) merge `FileSelection.to_metadata/1` into the
download's metadata: `"selected_files"` (indices), `"file_episodes"` (file
index, as a string, to the one episode id a kept video parsed to) and
`"skipped_owned_episode_ids"`.

`FileImport.detect_partial_pack/2` subtracts `skipped_owned_episode_ids` from
the expected count, so a pack whose owned episodes were skipped is not
flagged `partial_pack`.

## Early import

### Per-file progress

`DownloadStatus` gains `file_progress: [%{index, path, length, have}] | nil`
(carried onto `EnrichedDownload`), built
by `Client.Rqbit` from `details.files` and `stats.file_progress` matched by
index before excluded files are dropped. Other adapters leave it nil.

### Monitor

On each poll, for a download whose client reports `file_progress`, has more
than one included file, and is not complete, `DownloadMonitor` takes every
included file with `have == length`, an entry in `metadata["file_episodes"]`
and a path that exists on this host, removes paths already in
`metadata["early_imported_paths"]`, and enqueues one `MediaImport` with
`target_files` (`path` plus the recorded `episode_id`) and
`"partial" => true`. Files with no single recorded episode (multi-episode
files, unmatched names), and paths that only exist behind a path mapping,
wait for the full import, which handles them as it does today.

Partial jobs are unique on `[:download_id, :partial]`, so a queued partial
job never swallows the full import enqueued at completion, and a second
partial job for the same download is dropped until the first finishes (the
next poll picks up what it left). A partial job that starts after the
download is marked complete does nothing. A full import that starts while a
partial job for the download is executing snoozes 30 seconds.

### MediaImport partial mode

With `"partial" => true`:

- Place and record the target files through the existing targeted-import
  path.
- Append the placed source paths to `metadata["early_imported_paths"]` and
  their episode ids to `metadata["early_imported_episode_ids"]`.
- Do not stamp `imported_at`, do not run `detect_partial_pack`, do not call
  `ClientRemoval` or `Placement.cleanup_sources`, do not touch
  `match_status`.
- A file that fails to import stays out of `early_imported_paths`; the full
  import retries it.

The full import excludes paths in `early_imported_paths` from the files it
discovers, then runs `detect_partial_pack` and client removal over early and
late files together.

Placement uses hardlink, then copy, as today, so the seeding torrent keeps
its file.

## Disk-space guard

### Setting

`min_free_space_gb` on `Mydia.Config.Schema.BuiltInTorrent`, env var
`MYDIA_TORRENT_MIN_FREE_SPACE_GB`, default `5`, `0` turns the guard off.
Editable on the built-in client's settings form next to the download path.
`Config` carries it as `min_free_space_bytes`; it is left out of
`Config.restart_key/1`, so changing it never restarts the engine.

### Measuring

`Mydia.Downloads.BuiltIn.DiskSpace.free_bytes(path)` runs `df -Pk <path>`
(busybox `df` in the Alpine image supports `-P`) and parses the available
column. An error returns `{:error, reason}` and the guard lets the action
through with a warning; an unmeasurable disk must not stop every download.

### At grab

For a download going to the built-in client (`BuiltIn.managed?/1`),
`Queue.ClientSelection` checks after selection: if
`selected_bytes + reserve > free_bytes(download_path)` the grab fails with
`Error.insufficient_space/2` (details `%{needed, free, reserve}`), which:

- does not blacklist the release (nothing is wrong with it),
- shows on the downloads page and in the event log as "Not enough space on
  the download volume: needs 41.2 GB, 12.8 GB free, 5 GB kept free",
- is retried by the next scheduled search like any failed grab.

When listing failed, `selected_bytes` is the indexer's release size; with no
size at all the check is skipped. Bytes already on disk for the selected
files are not subtracted. Resuming a known torrent does not pass through the
grab path.

### While running

`Mydia.Downloads.BuiltIn.SpaceGuard`, a new child of `BuiltIn.Supervisor`
started after `Engine`, checks free space every 60 seconds.

- Below the reserve: pause every torrent the engine is downloading (not
  seeding, not already paused), record their info hashes in
  `<state_dir>/space-paused`, and set the `Status` part `:disk` to
  `{:low, %{free, reserve}}` (`:ok` otherwise).
- Free space back above the reserve plus 1 GiB (hysteresis, so it does not
  flap): resume exactly the recorded torrents, clear the file and the status.
- A torrent the user resumes by hand while paused for space is dropped from
  the record and is not paused again until the next crossing.
- The file survives a restart, so torrents paused for space are resumed after
  a reboot once there is room.

Low disk space is not a blocking reason: `BuiltIn.guard/2` keeps letting
calls through so imports, removals and seeding continue. The admin download
clients page and the downloads page show a warning banner while it holds.

## Errors

| Situation | Behaviour |
| --- | --- |
| `list_only` fails or times out | Warn, add with all files |
| `FileSelection.select/2` raises | Warn, add with all files |
| Second add fails | Same error as a failed add today |
| `df` fails | Warn once per hour, guard allows |
| Partial import fails | Logged; full import retries the file |

## Testing

- `FileSelection`: table-driven unit tests over fictional pack layouts
  (`The Lantern Keepers S02` with owned and missing episodes, samples,
  extras, subtitles, unparseable names, targeted-but-owned episodes, movies).
- `Client.Rqbit`: Bypass tests for `list_torrent_files/2` and for add with
  `only_files` and `initial_peers`; `file_progress` mapping with excluded
  files in the middle.
- `ClientSelection`: list, select and add in order; fallback when listing
  errors or selection raises; refusal adds nothing; the fifth tuple element
  reaches the download's metadata from both grab paths.
- `DownloadMonitor`: completed files enqueue one partial job, already
  imported paths are skipped, non-rqbit statuses enqueue nothing.
- `MediaImport` partial mode: no `imported_at`, no client removal,
  `early_imported_paths` updated; full import skips early paths and counts
  them in `detect_partial_pack`.
- `DiskSpace`: `df -Pk` output parsing, error path.
- `SpaceGuard`: pause below reserve, resume above reserve plus 1 GiB,
  hand-resumed torrent left alone, record survives restart. `df` injected.
- Grab refusal: `:insufficient_space` not blacklisted, event recorded.

## Delivery

Two PRs off one spec:

1. Wanted files and early import (adapter, `FileSelection`, monitor,
   `MediaImport` partial mode).
2. Disk-space guard (setting, `DiskSpace`, grab check, `SpaceGuard`, banner).

Docs: the built-in client page under `docs/using/` gets a section per
feature, including the partial-seeding note.

## Out of scope

Selection and per-file progress for qBittorrent and Transmission, choosing
files by hand in the UI, streaming a file while it downloads, piece priority
or sequential download, quality-aware selection inside a pack, a disk guard
for external clients.
