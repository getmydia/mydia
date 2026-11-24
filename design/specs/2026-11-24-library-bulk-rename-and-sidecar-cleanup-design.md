# Library-wide rename and orphaned sidecar cleanup

Issue: getmydia/mydia#1520

## Problem

A user migrating from Sonarr and Radarr imported about 100 shows and 300
movies without `auto_rename`. Bringing their filenames in line with Mydia's
naming means opening every item and pressing "Rename Files", one at a time.

The items they did rename left debris behind: episode `.nfo` files and
`-thumb.jpg` thumbnails named after the old video filename. Shows added after
the switch have none of it.

Two defects and one missing feature sit underneath:

1. `Mydia.Library.FileRenamer.rename_file/2` renames the video and nothing
   else. Its subtitles, NFO, EDL and thumbnail keep the old name and stop
   matching any video. (`LibraryMove` already carries sidecars through
   `LibraryMove.Sidecars`; the renamer never adopted it.)
2. `LibraryMove.Sidecars` matches `<video-root>.<ext>` only, so a Kodi/*arr
   thumbnail (`<video-root>-thumb.jpg`) is not a sidecar to any move.
3. There is no library-wide rename, and no way to clear sidecars that earlier
   renames already orphaned.

## Goals

- An admin renames every file in a library to Mydia's naming in one action,
  with a preview first.
- Sidecars always travel with their video, in the bulk action and in the
  existing per-item modal.
- An admin clears sidecars orphaned by earlier renames, recoverably.

## Non-goals

- Changing folder layout. Files stay in their directories; a Sonarr
  `Season 1` folder stays `Season 1`. (`FileOrganizer` reorganize and
  `LibraryMove` own placement.)
- Removing item- or season-level metadata: `poster.jpg`, `fanart.jpg`,
  `season01-poster.jpg`, `tvshow.nfo`, `movie.nfo`. Kodi and Jellyfin setups
  read these.
- A batch action in the media index selection toolbar. `select_all` covers
  only the loaded window, and cleanup is library-scoped anyway.

## Design

### 1. Sidecars travel with every rename

`LibraryMove.Sidecars` learns a second form: `<video-root>-thumb.jpg` and
`<video-root>-thumb.png` (case-insensitive extension). The existing
`Mydia.Subtitles.Sidecars.owned_by/2` guard applies to both forms, so
`Glass.mkv` never takes `Glass.Harbor-thumb.jpg` from `Glass.Harbor.mkv` in
the same folder. `Sidecars.dest_for/3` already swaps the video root and keeps
the tail, so `-thumb.jpg` needs no new destination logic.

`FileRenamer.rename_file/2`, local and S3:

1. Lists the video's sidecars with `Sidecars.for/1` before anything moves
   (afterwards the video is no longer among the folder's siblings).
2. Renames the video and commits the row, as today.
3. Renames each sidecar to `Sidecars.dest_for/3`. A sidecar whose destination
   exists, or whose move fails, stays where it is and is logged with the
   media file id. A sidecar never fails or rolls back the video's rename.

A `Sidecars.for/1` listing error (other than a missing folder) fails the
rename before the video moves, the same rule `LibraryMove` follows, so a
transient NAS error cannot orphan sidecars.

The per-item "Rename Files" modal gets this for free.

### 2. Bulk rename

**`Mydia.Library.BulkRename`** (new context module).

- `preview(library_path)` walks the library's media items, and for each one
  runs `FileRenamer.generate_rename_previews_for_media_item/1`, restricted to
  files on this library path. It returns a struct:
  - `total`, `changed`, `unchanged` counts
  - `conflicts`: changed previews whose proposed path already exists on disk,
    or is proposed for two files in this run
  - `sample`: the first 20 changed, non-conflicting previews, for the modal
- `run(library_path, opts)` recomputes the previews (never trusting a stale
  modal), renames each changed, non-conflicting file through
  `FileRenamer.rename_file/2`, and returns counts: `renamed`, `unchanged`,
  `conflicts`, `errors`. `opts[:on_progress]` is called after each media item
  with `{done, total}`.

Work proceeds one media item at a time so memory stays flat on large
libraries. It renames regardless of `library_path.auto_rename`: that flag
governs imports, and this is an explicit admin action. S3 libraries work
through `FileRenamer`'s existing S3 branch; cross-storage renames cannot
arise because the directory never changes.

A re-run is idempotent: canonical files preview as unchanged.

**`Mydia.Jobs.LibraryRename`** (new Oban worker, modelled on
`Mydia.Jobs.LibraryReorganize`).

- Args: `library_path_id`. Unique per `library_path_id` while available,
  scheduled or executing, so a double click enqueues one job.
- Broadcasts `started`, `progress` and `completed` (with the summary) on the
  `library_scanner` PubSub topic that the Library Paths page already
  subscribes to.

### 3. Orphaned sidecar cleanup

**Definition.** A file is an orphaned sidecar when all of these hold:

- Its name has a sidecar form: a subtitle extension
  (`Mydia.Subtitles.Sidecars.extensions/0`), `.nfo`, `.edl`, or
  `-thumb.jpg`/`-thumb.png`.
- It is not item- or season-level metadata. Those names carry no video
  prefix, so the next rule already excludes them; the module also keeps an
  explicit deny list (`tvshow.nfo`, `movie.nfo`, `season.nfo`,
  `season\d+-*`, `poster.*`, `fanart.*`, `folder.*`, `banner.*`,
  `clearlogo.*`, `landscape.*`) as a second line of defence.
- It sits in a directory that holds a file with a scanner video extension
  (a symlink to one counts), and no non-directory, non-sidecar-form entry in
  that directory (a symlinked version included) claims it. A file
  claims a sidecar when the sidecar's name starts with the file's root,
  compared case-insensitively. So an `.iso`, `.strm` or `VIDEO_TS.IFO` protects
  its sidecars too, while `Subs/` folders and directories without a video are
  never touched. Checking disk rather than `media_files` rows means a video
  the scanner has not picked up yet still protects its sidecars.
- It is not a subtitle Mydia tracks (a path recorded by the subtitle
  reconciliation in `Mydia.Subtitles.Sidecars`).
- It is under the library path and outside every directory the scanner skips
  (`.mydia-trash` and friends).

**`Mydia.Library.SidecarCleanup`** (new module).

- `preview(library_path)` walks the library and returns the orphans grouped
  by folder, with a total count and byte size.
- `run(library_path, paths)` takes exactly the paths the preview showed,
  re-checks each against the definition at run time (a video added since the
  preview protects its sidecars again), and moves each survivor into
  `<trash root>/sidecar-cleanup-<library id>-<UTC timestamp>/<path relative
  to the library>`. The library id keeps two libraries sharing a trash root
  apart. The re-check lists and stats each directory once. The trash root is the one `Mydia.Library.TrashStore` uses for
  this library (`root_for/1`'s rule), so the move is a same-filesystem
  `rename(2)`, and the scanner never sees the container.
- There is no directory pruning. Under the eligibility rule every orphan sits
  in a directory that still holds a video, so a run never empties a directory.
- Local libraries only in the first version. On an S3 library the action is
  hidden; object listings make the disk-claim rule expensive.

**Retention and restore.** A `sidecar-cleanup-*` container has no
`media_files` row, so `TrashStore.audit/0` reports it as orphaned (it
classifies non-UUID containers like this one as orphaned without querying
them) and the Trash admin page can sweep it. Restoring is a manual move back; the
preview and the completion message both say where the files went. This is
deliberate: these are files Mydia never read, and a restore flow is not worth
building for them.

**`Mydia.Jobs.SidecarCleanup`** (new Oban worker). Args: `library_path_id`
and the confirmed `paths`. Unique per library. Broadcasts on the same topic as
the rename job.

### 4. UI: Library Paths admin page

Two actions on each library row, beside the existing Reorganize controls:

- **Rename files.** Opens a modal whose contents load with `start_async`
  (a NAS walk must not block the LiveView): counts, the before/after sample,
  and the conflict list with each conflict's reason. "Rename N files"
  enqueues `LibraryRename`. Hidden while a rename job runs for the library.
- **Clean up orphaned sidecars.** Same modal pattern: folders and the files in
  each, total size, and where they will go. "Move N files to trash" enqueues
  `SidecarCleanup` with the shown paths.

Progress and the final summary show on the library row, from the PubSub
broadcasts. Both use core components and daisyUI modal classes, with stable
DOM ids for tests. All new strings go through gettext.

## Error handling

- Per-file rename failures (`file_not_found`, `target_exists`, storage
  errors) are counted and logged; the job carries on with the next file and
  finishes `:ok`. The summary shows the error count.
- A sidecar that cannot move during a rename is logged and left in place; the
  cleanup action will offer it later if it is now orphaned.
- A cleanup file that fails the run-time re-check is skipped and counted as
  `kept`.
- A library path that disappears (unmounted NAS) makes preview return an
  error the modal shows; the jobs discard rather than retry forever.

## Testing

All fixtures use invented titles.

- `LibraryMove.Sidecars`: `-thumb.jpg`/`.png` detection, case of extension,
  and the `owned_by` guard between `Glass` and `Glass.Harbor`.
- `FileRenamer.rename_file/2`: sidecars renamed alongside the video; a sidecar
  destination already taken leaves that sidecar in place and still renames
  the video; a listing error fails before the video moves; the S3 branch.
- `BulkRename`: preview counts, conflict detection (on disk and duplicate
  proposals), `run` renaming only changed non-conflicting files, idempotent
  re-run, progress callback.
- `SidecarCleanup`: orphan classification; artwork and item NFOs spared;
  tracked subtitles spared; sidecars of an unscanned video on disk spared;
  run-time re-check after a video appears; files land under the trash
  container with relative paths preserved; `Subs/` folders and video-less
  directories untouched; `.iso`/`.strm` protect their sidecars;
  `TrashStore.audit/0` reports the container.
- Both Oban workers via `perform_job`, including uniqueness.
- LiveView tests for both modals: preview renders, confirm enqueues the job,
  completion broadcast updates the row.

## Changes during implementation

- Cleanup's orphan rule: a directory is eligible only if it holds a file with
  a scanner video extension (a symlink to one counts); in it, any
  non-directory, non-sidecar-form entry, symlinks included, claims sidecars by
  root, case-insensitively. Only a regular file is ever moved, so a symlinked
  sidecar stays. `Subs/` folders and video-less
  directories are never touched, and `.iso`/`.strm` protect their sidecars.
- There is no directory pruning, because it is unreachable under that rule.
- `TrashStore.audit/0` classifies non-UUID containers (like
  `sidecar-cleanup-<library id>-<ts>`) as orphaned without querying them.
- `FileNamer` no longer reads a canonical name's bracketed tail as a release
  group, so a name such as `-GROUP[tracker]` is kept whole. It takes a group
  only after a scene-style hyphen (after `]` or `)`, in a name without
  whitespace before it, or after a quality word in a spaced scene name) and
  never a quality, source or resolution word, so Sonarr and Radarr default
  names (`Show - S01E01 - Pilot WEBDL-1080p`, `Film (2020) Bluray-1080p`) do
  not gain a `-1080p` or `-Pilot` suffix. An empty episode title is treated
  as no title.
- `Mydia.Jobs.LibraryRename` broadcasts completion with
  `error: :library_unavailable` for a deleted library path instead of
  raising, so the page's spinner clears.
- `BulkRename.run/2` re-reads each media item's rows just before renaming
  them. A file whose row vanished, or whose preview no longer matches the
  plan, is skipped and counted unchanged; conflicts still come from the
  up-front plan.
- `Mydia.Jobs.SidecarCleanup` refuses with `:busy` (zero counts) while a
  `LibraryRename` of the same library or a `LibraryMove` into or out of it is
  executing; the page flashes that the cleanup was skipped.
