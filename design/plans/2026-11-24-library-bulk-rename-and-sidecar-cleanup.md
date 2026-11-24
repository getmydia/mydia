# Library-wide Rename and Orphaned Sidecar Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin rename every file in a library to Mydia's naming in one previewed action, with sidecars travelling with their videos, and move sidecars orphaned by earlier renames into the trash.

**Architecture:** `LibraryMove.Sidecars` gains the `-thumb` form and a shared `move_all/5` (extracted from `LibraryMove.FileStep`), which `FileRenamer.rename_file/2` adopts. A new `Mydia.Library.BulkRename` context and `Mydia.Jobs.LibraryRename` worker drive renames library-wide; a new `Mydia.Library.SidecarCleanup` module and `Mydia.Jobs.SidecarCleanup` worker classify and trash orphans. Both surface as preview modals on the Library Paths admin page, with progress over the existing `library_scanner` PubSub topic.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Oban, Ecto (SQLite + PostgreSQL), daisyUI.

**Spec:** `design/specs/2026-11-24-library-bulk-rename-and-sidecar-cleanup-design.md`

## Global Constraints

- Folders never change: a rename keeps the file's directory. No task calls `FileOrganizer`'s placement or `LibraryMove.plan/2`.
- Never remove item/season metadata: `tvshow.nfo`, `movie.nfo`, `season.nfo`, `season\d+-*`, `poster.*`, `fanart.*`, `folder.*`, `banner.*`, `clearlogo.*`, `landscape.*`.
- A sidecar never fails or rolls back its video's rename. A sidecar listing error (other than a missing folder) fails the rename before the video moves.
- Bulk rename ignores `library_path.auto_rename`.
- Cleanup is local-only; the action is hidden for `s3://` libraries.
- Trash container name: `sidecar-cleanup-<UTC timestamp>` under the library's trash root, relative paths preserved.
- PubSub topic `"library_scanner"`; event tuples `{:library_rename_started | :library_rename_progress | :library_rename_completed, map}` and `{:sidecar_cleanup_started | :sidecar_cleanup_completed, map}`, each map carrying `library_path_id`.
- Fixtures use invented titles only. No em dashes in prose or strings. All UI strings via `gettext`/`ngettext`.
- Commit from the worktree with plain `git commit -F <msgfile>` after `git add` of every touched path; verify with `git show --stat HEAD`.

## Review Focus

1. **Two videos sharing a prefix in one folder** (`Glass.mkv` and `Glass.Harbor.mkv`): renaming `Glass.mkv` must not take `Glass.Harbor-thumb.jpg` or `Glass.Harbor.en.srt`, and cleanup must not call them orphans. Pinned in Task 1 and Task 4.
2. **A subtitle `subtitles.file_path` row pointing at a sidecar that a rename moves**: the row must follow the file, and be put back if the move fails. Pinned in Task 2.
3. **A video on disk that no `media_files` row knows yet** (scan pending): its sidecars are not orphans. Pinned in Task 4.
4. **Two files proposing the same new name** in one bulk run (e.g. two versions of one episode with identical quality): neither is renamed onto the other; both are reported as conflicts. Pinned in Task 3.
5. **Pruning walking too far**: a run that empties a season folder removes it, but never the show folder that still holds `tvshow.nfo`, and never the library root even when it ends up empty. Pinned in Task 4.

---

### Task 1: Sidecars learn `-thumb` and a shared `move_all/5`

**Files:**
- Modify: `lib/mydia/library/library_move/sidecars.ex`
- Modify: `lib/mydia/library/library_move/file_step.ex` (replace private `move_sidecars/5`, `move_sidecar/4`, `place_sidecar/4`, `rewrite_subtitle_rows/3` with a call to `Sidecars.move_all/5`)
- Test: `test/mydia/library/library_move_sidecars_test.exs` (create)

**Interfaces:**
- Produces:
  - `Sidecars.for/1` (unchanged signature) now also returns `<video-root>-thumb.jpg` / `-thumb.png` (extension case-insensitive), subject to the same `Mydia.Subtitles.Sidecars.owned_by/2` guard.
  - `Sidecars.sidecar_name?(entry :: String.t(), video_name :: String.t()) :: boolean()`: true when `entry` is a sidecar form of the video file named `video_name` (no ownership check). Used by Task 5.
  - `Sidecars.move_all(sidecars :: [String.t()], source_video :: String.t(), dest_video :: String.t(), media_file_id :: binary(), confine_root :: String.t()) :: [String.t()]`: moves each sidecar to `dest_for/3`, rewriting matching `subtitles.file_path` rows first and restoring them on failure; returns the sidecars left at the source. Behaviour identical to FileStep's current private code (skip when destination exists; `FileOrganizer.place_file/3` with `use_hardlinks: true, remove_source_after_hardlink: true, fallback: :move, confine_to: confine_root`).

- [ ] **Step 1: Write the failing tests** in `library_move_sidecars_test.exs` (`use Mydia.DataCase, async: false`, `@moduletag :tmp_dir`, fixtures from `Mydia.MediaFixtures`/`Mydia.SettingsFixtures`):
  - `"for/1 lists a -thumb.jpg and a -thumb.PNG beside the video"`: files `Quiet Orchard - S01E01.mkv`, `Quiet Orchard - S01E01-thumb.jpg`, `Quiet Orchard - S01E01-thumb.PNG`, `Quiet Orchard - S01E01.nfo` → all three sidecars returned.
  - `"for/1 never takes a longer sibling's thumb"`: `Glass.mkv` and `Glass.Harbor.mkv` both with rows; `Glass.Harbor-thumb.jpg` is not in `Sidecars.for(glass)`.
  - `"sidecar_name?/2"`: true for `{"A.en.srt","A.mkv"}`, `{"A-thumb.jpg","A.mkv"}`; false for `{"A-poster.jpg","A.mkv"}`, `{"poster.jpg","A.mkv"}`, `{"A.mkv","A.mkv"}`.
  - `"move_all/5 renames -thumb with the video root and rewrites subtitle rows"`: a `Subtitle` row with `file_path` = old `.en.srt`; after `move_all` the files sit at the new root (`New-thumb.jpg`, `New.en.srt`), the row points at the new path, return is `[]`.
  - `"move_all/5 leaves a sidecar whose destination exists"`: return contains it; its row unchanged.
- [ ] **Step 2: Run** `./dev mix test test/mydia/library/library_move_sidecars_test.exs`. Expected: thumb, `sidecar_name?` and `move_all` tests FAIL (undefined / missing entries).
- [ ] **Step 3: Implement** in `sidecars.ex`: extend `sidecar?/3` to accept `prefix-thumb` + `.jpg/.png`; `dest_for/3` already preserves the tail. Add `sidecar_name?/2` (reuse `sidecar?/3`). Move FileStep's four private functions into `move_all/5` verbatim, then make `FileStep.delete_source/5` call `Sidecars.move_all(sidecars, source, dest, media_file_id, target.path)`. Update the moduledoc to mention `-thumb`.
- [ ] **Step 4: Run** the new test file plus `./dev mix test test/mydia/library/library_move_file_step_test.exs test/mydia/jobs/library_move_test.exs`. Expected: all PASS.
- [ ] **Step 5: Commit** `feat(library): carry -thumb sidecars and share sidecar moves`.

### Task 2: `FileRenamer.rename_file/2` carries sidecars

**Files:**
- Modify: `lib/mydia/library/file_renamer.ex` (`rename_file/2`, `do_rename_file/2`, `rename_object/2`)
- Test: `test/mydia/library/file_renamer_sidecars_test.exs` (create); extend `test/mydia/library/file_renamer_s3_test.exs`

**Interfaces:**
- Consumes: `Sidecars.for/1`, `Sidecars.move_all/5` (Task 1).
- Produces: `FileRenamer.rename_file/2` unchanged signature; now returns `{:error, {:sidecars_unlisted, reason}}` when the listing fails, before the video moves. After a committed video rename, sidecars move via `move_all(sidecars, current_path, new_path, file.id, file.library_path.path)`; leftovers are logged with `file_id` and never change the return value.

- [ ] **Step 1: Write the failing tests** (`DataCase`, `:tmp_dir`, setup like `file_renamer_preview_test.exs` with show "The Lantern Keepers"):
  - `"renaming an episode renames its nfo, subtitles and thumb"`: video `lk.s01e01.mkv` with `lk.s01e01.nfo`, `lk.s01e01.en.srt`, `lk.s01e01-thumb.jpg`; rename to the preview's `proposed_path`; assert each sidecar exists under the proposed root and none remain under the old root.
  - `"a taken sidecar destination stays behind and the video still renames"`: pre-create the destination `.nfo`; result `{:ok, _}`, old `.nfo` still present.
  - `"a subtitle row follows its file"`: `Subtitle` row on the `.en.srt`; after rename `file_path` equals the new path.
  - `"an unlistable folder fails before the video moves"`: stub by making the directory unreadable (`File.chmod!(dir, 0o300)`, restore in `on_exit`); result `{:error, {:sidecars_unlisted, _}}`, video untouched. Tag `@tag :unix_permissions` if the suite skips root runs; check `test/README.md`.
  - In `file_renamer_s3_test.exs`: `"S3 rename carries the .en.srt object"` using that file's existing S3 setup.
- [ ] **Step 2: Run** both files. Expected: new tests FAIL.
- [ ] **Step 3: Implement**: list sidecars in `rename_file/2` before the `cond` dispatch (skip when `current_path == new_path`); thread them to `commit_rename/4`'s success branch, then call `move_all/5`.
- [ ] **Step 4: Run** `./dev mix test test/mydia/library/file_renamer_sidecars_test.exs test/mydia/library/file_renamer_s3_test.exs test/mydia/library/file_renamer_test.exs test/mydia/library/file_renamer_preview_test.exs test/mydia_web/live/media_live`. Expected: PASS.
- [ ] **Step 5: Commit** `fix(library): rename sidecars along with their video` (body: `Refs #1520`).

### Task 3: `BulkRename` context and `LibraryRename` job

**Files:**
- Create: `lib/mydia/library/bulk_rename.ex`, `lib/mydia/library/structs/bulk_rename_preview.ex`, `lib/mydia/jobs/library_rename.ex`
- Test: `test/mydia/library/bulk_rename_test.exs`, `test/mydia/jobs/library_rename_test.exs`

**Interfaces:**
- Consumes: `FileRenamer.generate_rename_preview/1`, `FileRenamer.rename_file/2`, `%RenamePreview{}`.
- Produces:
  - `%Mydia.Library.Structs.BulkRenamePreview{total: non_neg_integer, changed: non_neg_integer, unchanged: non_neg_integer, conflicts: [{RenamePreview.t(), :target_exists | :duplicate_target}], sample: [RenamePreview.t()]}` (sample capped at 20, changed and non-conflicting only).
  - `BulkRename.preview(LibraryPath.t()) :: {:ok, BulkRenamePreview.t()} | {:error, :library_unavailable}`
  - `BulkRename.run(LibraryPath.t(), on_progress: ({done, total} -> any)) :: {:ok, %{renamed: n, unchanged: n, conflicts: n, errors: n}} | {:error, :library_unavailable}`
  - `Mydia.Jobs.LibraryRename.enqueue(library_path_id) :: {:ok, Oban.Job.t()} | {:error, term}`; queue `:media`, `max_attempts: 1`, `unique: [keys: [:library_path_id], states: [:available, :scheduled, :executing]]`. Broadcasts `{:library_rename_started, %{library_path_id}}`, `{:library_rename_progress, %{library_path_id, done, total}}` (at most once per media item), `{:library_rename_completed, %{library_path_id} ++ run counts}`.

Files are grouped by media item (movie: `media_item_id`; episode: `episode.media_item_id`) and only those with `library_path_id == library_path.id` and `trashed_at` nil are considered. `:library_unavailable` when a local path does not exist (`File.dir?/1` false) or an S3 root fails `Storage.stat`.

- [ ] **Step 1: Write the failing tests** for `BulkRename` (`DataCase`, `:tmp_dir`; a movie "Paper Comet" (2019) and show "The Lantern Keepers"):
  - `"preview counts changed and unchanged files"`: one junk-named movie file, one already-canonical episode → `changed: 1, unchanged: 1, total: 2`.
  - `"a proposed name already on disk is a target_exists conflict"`.
  - `"two files proposing one name are both duplicate_target conflicts and neither moves on run"` (two versions of an episode, identical quality fields).
  - `"files in another library are ignored"`.
  - `"run renames changed files, carries sidecars, and is idempotent"`: second `run` returns `renamed: 0`.
  - `"run reports progress once per media item"`: collect calls via `send(self(), …)`; assert `{2, 2}` last.
  - `"an unmounted library path is library_unavailable"`.
  - `"run renames even when auto_rename is false"`.
- [ ] **Step 2: Write the failing job tests** (`use Oban.Testing, repo: Mydia.Repo`): `perform_job(LibraryRename, %{"library_path_id" => id})` returns `:ok`, files renamed, and `assert_receive {:library_rename_completed, %{renamed: 1}}` after subscribing to `"library_scanner"`; `enqueue/1` twice yields one job (`all_enqueued(worker: LibraryRename)` length 1). Check how `test/mydia/library_scan_trigger_test.exs` inserts jobs with Oban's engine disabled and follow it.
- [ ] **Step 3: Run** both files. Expected: FAIL (modules undefined).
- [ ] **Step 4: Implement** the struct, context and worker. `run/2` re-derives previews; never takes a preview from the caller.
- [ ] **Step 5: Run** both files. Expected: PASS.
- [ ] **Step 6: Commit** `feat(library): library-wide rename with preview` (body: `Refs #1520`).

### Task 4: `SidecarCleanup` module and job

**Files:**
- Create: `lib/mydia/library/sidecar_cleanup.ex`, `lib/mydia/jobs/sidecar_cleanup.ex`
- Modify: `lib/mydia/library/trash_store.ex` (add `root_for_library/1`)
- Test: `test/mydia/library/sidecar_cleanup_test.exs`, `test/mydia/jobs/sidecar_cleanup_test.exs`

**Interfaces:**
- Consumes: `Sidecars.sidecar_name?/2` (Task 1), `Mydia.Library.Scanner.extensions_for_library_type(:movies)` (video extensions), `TrashStore.dir_name/0`.
- Produces:
  - `TrashStore.root_for_library(LibraryPath.t()) :: String.t() | nil`: the root `root_for/1` would give any file of that library; `root_for/1` delegates to it.
  - `SidecarCleanup.preview(LibraryPath.t()) :: {:ok, %{folders: [{dir :: String.t(), [String.t()]}], count: n, bytes: n, destination: String.t()}} | {:error, :library_unavailable | :s3_unsupported}` (`destination` is the trash root; paths absolute).
  - `SidecarCleanup.run(LibraryPath.t(), paths :: [String.t()]) :: {:ok, %{moved: n, kept: n, pruned_dirs: n, container: String.t()}} | {:error, …same}`
  - `SidecarCleanup.orphan?(path :: String.t(), LibraryPath.t()) :: boolean()` (public for the run-time re-check and tests).
  - `Mydia.Jobs.SidecarCleanup.enqueue(library_path_id, paths)`; queue `:media`, `max_attempts: 1`, unique on `:library_path_id` in available/scheduled/executing. Broadcasts `{:sidecar_cleanup_started, %{library_path_id}}` and `{:sidecar_cleanup_completed, %{library_path_id} ++ run counts}`.

`orphan?/2` is true only when: the file is under the library root and no path segment is `TrashStore.dir_name()`; the basename is not on the deny list (Global Constraints); it matches a sidecar form per `sidecar_name?/2` for *some* video name (subtitle ext, `.nfo`, `.edl`, `-thumb.jpg/png`); no file in the same directory with a video extension satisfies `sidecar_name?(basename, video)`; and no `Subtitle` row has `file_path` equal to it. Preview walks with `File.ls/1` recursively (skipping the trash dir), not the scanner.

Pruning after a run: for each directory a moved file left, remove it if `File.ls/1` returns `[]`, then repeat on its parent; stop at the library root, at the first non-empty directory, and at the directory `PathAnchor.anchor_for/2` names as the item folder (the anchor itself is never removed).

- [ ] **Step 1: Write the failing tests** (`DataCase`, `:tmp_dir`; library at `<tmp>/lib`, trash env pointed at `<tmp>/trash` via `Application.put_env(:mydia, :trash_dir, …)` restored in `on_exit`):
  - `"an nfo and thumb whose video is gone are orphans"`: `Quiet Orchard (2020)/Season 1/old.name.S01E01.nfo` + `old.name.S01E01-thumb.jpg` beside `Quiet Orchard - S01E01 - Pilot.mkv` → both listed.
  - `"artwork and item nfos are never orphans"`: `tvshow.nfo`, `poster.jpg`, `season01-poster.jpg`, `fanart.jpg` → none listed.
  - `"sidecars of a video no row knows are kept"`: `Unscanned.mkv` + `Unscanned.en.srt`, no `media_files` row → not listed.
  - `"a tracked subtitle is kept"`: orphan-shaped `.srt` with a `Subtitle` row → not listed.
  - `"a longer sibling's sidecar is not taken as orphan"`: `Glass.Harbor.mkv` + `Glass.Harbor-thumb.jpg` → not listed.
  - `"run re-checks: a video added after preview protects its sidecars"`: preview, then write `old.name.S01E01.mkv`, run → `kept: 2, moved: 0`.
  - `"run moves orphans under sidecar-cleanup-<ts> with relative paths"`: assert file at `<trash>/sidecar-cleanup-*/Quiet Orchard (2020)/Season 1/old.name.S01E01.nfo`.
  - `"pruning removes an emptied season folder but not the show folder or root"`: `Season 9/` holding only an orphan `.nfo` is removed; `Quiet Orchard (2020)/` with `tvshow.nfo` stays; a library whose only content was one orphan keeps its root.
  - `"TrashStore.audit reports the container as orphaned"`.
  - `"an s3 library is s3_unsupported"`.
- [ ] **Step 2: Write the failing job tests**: `perform_job` moves the given paths and broadcasts completion; duplicate `enqueue/2` yields one job.
- [ ] **Step 3: Run** both files. Expected: FAIL.
- [ ] **Step 4: Implement** `root_for_library/1`, the module and the worker. Moves use `File.rename/2`; on `{:error, :exdev}` (trash root on another mount) copy with `File.cp/2`, then `File.rm/1` the source only after the copy succeeded.
- [ ] **Step 5: Run** both files plus `./dev mix test test/mydia/library/trash_store_test.exs`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(library): move orphaned sidecars to the trash` (body: `Refs #1520`).

### Task 5: Library Paths admin UI

**Files:**
- Create: `lib/mydia_web/live/admin_library_paths_live/maintenance.ex` (event and PubSub handlers, called from `index.ex` one-line delegations, as `media_live/show/rename_events.ex` does), `lib/mydia_web/live/admin_library_paths_live/maintenance_modals.ex` (function components)
- Modify: `index.ex` (assigns, delegations, `handle_async`), `index.html.heex` (render modals), `components.ex` (two menu items in the row dropdown, after the File Organization group, under a "Maintenance" `menu-title`)
- Test: `test/mydia_web/live/admin_library_paths_maintenance_test.exs`

**Interfaces:**
- Consumes: `BulkRename.preview/1`, `LibraryRename.enqueue/1`, `SidecarCleanup.preview/1`, `Mydia.Jobs.SidecarCleanup.enqueue/2`, the PubSub tuples above.
- Produces (DOM ids for tests): menu buttons `#rename-files-<id>` (event `"preview_bulk_rename"`), `#cleanup-sidecars-<id>` (event `"preview_sidecar_cleanup"`, absent for `s3://` paths); modals `#bulk-rename-modal` with `#bulk-rename-confirm` (`"confirm_bulk_rename"`), `#bulk-rename-conflicts`, `#bulk-rename-sample`; `#sidecar-cleanup-modal` with `#sidecar-cleanup-confirm` (`"confirm_sidecar_cleanup"`), `#sidecar-cleanup-destination`; shared `"close_maintenance_modal"`. Assigns: `:maintenance_modal` (`nil | {:bulk_rename | :sidecar_cleanup, library_path_id, AsyncResult}`), `:renaming_library_ids`, `:cleaning_library_ids` (`MapSet`).

Previews load with `start_async` (modal shows a `loading` spinner meanwhile; `:library_unavailable` shows an `alert-error`). Confirm buttons read "Rename %{count} files" / "Move %{count} files to trash" (`ngettext`), are disabled at zero, and the cleanup confirm sends the paths the preview showed (kept server-side in the assign, never round-tripped through the client). Row badges show "Renaming %{done}/%{total}" and "Cleaning up" while ids are in the sets; completion puts a flash with the counts ("Renamed %{renamed} files, %{conflicts} conflicts, %{errors} errors"; "Moved %{moved} files to %{container}").

- [ ] **Step 1: Write the failing LiveView tests** (follow `admin_library_paths_live_test.exs` setup; `:tmp_dir` library with one junk-named movie file and one orphan `.nfo`):
  - `"rename preview shows counts and sample"`: click `#rename-files-<id>`, `render_async(view)`, `has_element?(view, "#bulk-rename-sample")`.
  - `"confirming rename enqueues LibraryRename"`: `assert_enqueued(worker: Mydia.Jobs.LibraryRename, args: %{library_path_id: id})`.
  - `"cleanup preview lists the orphan and its destination"`.
  - `"confirming cleanup enqueues SidecarCleanup with the shown paths"`.
  - `"the cleanup action is absent on an s3 library"`.
  - `"a completion broadcast clears the badge and flashes"`: `send(view.pid, {:library_rename_completed, %{library_path_id: id, renamed: 1, unchanged: 0, conflicts: 0, errors: 0}})`.
- [ ] **Step 2: Run** the file. Expected: FAIL.
- [ ] **Step 3: Implement** the components, handlers and menu items. Keep `index.ex` additions to delegations and mount assigns.
- [ ] **Step 4: Run** the new file and `admin_library_paths_live_test.exs`. Expected: PASS.
- [ ] **Step 5: Extract gettext**: `./dev mix gettext.extract --merge` and run the catalog check named in `lib/mydia_web/gettext/README.md`. Expected: clean.
- [ ] **Step 6: Commit** `feat(admin): rename files and clean up sidecars from Library Paths` (body: `Closes #1520`).

### Task 6: Docs and final verification

**Files:**
- Modify: `lib/mydia/media/README.md` (a short "Library-wide rename and sidecar cleanup" section: sidecar forms, the orphan rule, where cleaned files go, how to restore), user docs page for library paths under `docs/` if one describes the row menu (`grep -rl "Reorganize" docs/`).

- [ ] **Step 1: Write the doc sections** (no em dashes; invented titles in examples).
- [ ] **Step 2: Run** `./dev mix precommit` in foreground chunks if it exceeds the Bash timeout (see `test/README.md`). Expected: format, credo, compile warnings and tests clean.
- [ ] **Step 3: Check co-changes**: `git diff --name-only origin/master...` and confirm no file outside this plan's lists appears.
- [ ] **Step 4: Commit** `docs(library): describe bulk rename and sidecar cleanup`.
