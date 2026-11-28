# Torrent File Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a built-in torrent's files as a selectable folder tree on the
Downloads drawer, and let the operator choose files before a manual grab from
a movie or show page.

**Architecture:** A pure `Mydia.Downloads.FileTree` builds and toggles the
tree; a function component renders it for both the Files panel and a new
pre-grab modal. The pre-grab path splits `ClientSelection.add_to_client/2`
into a reusable `prepare/2` step, so `Queue.FilePreview` can fetch and list a
torrent without adding it, and the confirmed grab reuses that preview through
`Downloads.grab_async/2`.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, daisyUI 5, ExUnit, Bypass.

**Spec:** `design/specs/2026-11-28-torrent-file-tree-design.md`

## Global Constraints

- Built-in client (rqbit) only: gate on `Client.supports_file_selection?/1`.
- Download stays one click; "Choose files…" is a separate action, media page only.
- A manual choice stamps `"file_selection" => %{"source" => "manual"}`.
- A choice with no importable video is refused (`:no_importable_file`), one shared rule.
- All UI strings through `gettext`; no em dashes in copy, docs or comments.
- Never real movie or TV titles in tests or fixtures; invent them.
- Two PRs: Tasks 1-2 are PR 1, Tasks 3-5 are PR 2 (branched from PR 1).
- Run each `git commit` in its own step inside the devenv environment
  (`direnv exec . git commit -F <msgfile>`); check `git show --stat` after.

## Deviation from the spec, decided here

- The spec routes the confirm through `initiate_download`. Manual grabs on the
  media page actually go through `Downloads.grab_async/2` (`Grabber`), which
  calls `ClientSelection.add_to_client/2` and already re-runs the duplicate
  check. The preview option is therefore read in `add_to_client/2`, which
  serves both paths, and the modal calls `grab_async/2`.
- `"skipped_owned_episode_ids"` for a manual choice is computed directly: the
  owned episodes whose files the operator left out. For an unchanged automatic
  pick this equals the automatic list, and it needs no second input.
- The preview does not re-run `Lifecycle`'s missing-target check: the media
  page's item exists, and the grab's own path handles a delete after it.

## Review Focus

- A torrent with files at its root next to folders (no single root folder) must render both, root files after folders.
- A magnet whose listing times out (30 s client timeout) must leave the modal with the fallback button, never a spinner forever or a crash.
- Closing the modal while the preview is still loading must not open it again when the async result lands.
- A release grabbed by another tab between preview and confirm must show "already downloading", not add twice.
- A Files panel save after the client dropped the torrent keeps the existing error path; the tree must not lose the operator's unsaved choice on that error.

---

## PR 1: the file tree

### Task 1: `Mydia.Downloads.FileTree`

**Files:**
- Create: `lib/mydia/downloads/file_tree.ex`
- Test: `test/mydia/downloads/file_tree_test.exs`

**Interfaces:**
- Consumes: `Mydia.Downloads.Structs.TorrentFile` (`index`, `path`, `size`, `included?`, `downloaded`).
- Produces:
  - `%FileTree.Folder{path: String.t(), name: String.t(), children: [Folder.t() | Leaf.t()], size: non_neg_integer(), selected_size: non_neg_integer(), state: :all | :none | :partial}` (root has `path: ""`)
  - `%FileTree.Leaf{index: non_neg_integer(), name: String.t(), size: non_neg_integer(), selected?: boolean(), file: TorrentFile.t()}`
  - `build([TorrentFile.t()], MapSet.t(non_neg_integer())) :: Folder.t()`
  - `toggle(MapSet.t(), [TorrentFile.t()], {:folder, String.t()} | {:file, non_neg_integer()}) :: MapSet.t()`
  - `toggle_all(MapSet.t(), [TorrentFile.t()]) :: MapSet.t()`
  - `selected_size([TorrentFile.t()], MapSet.t()) :: non_neg_integer()`
  - `state([TorrentFile.t()], MapSet.t()) :: :all | :none | :partial` (whole torrent, for the header)

Nested structs live in `lib/mydia/downloads/file_tree/folder.ex` and `leaf.ex` (one module per file).

- [ ] **Step 1: Write the failing tests**

Fixture: files `"The.Lantern.Keepers.S01/E01.mkv"` (index 0, 100), `"The.Lantern.Keepers.S01/E02.mkv"` (1, 100), `"The.Lantern.Keepers.S02/E10.mkv"` (2, 50), `"The.Lantern.Keepers.S02/E9.mkv"` (3, 50), `"readme.nfo"` (4, 1).

- `"nests by path and totals sizes"`: root `size == 301`; folder `"The.Lantern.Keepers.S01"` has `size == 200`.
- `"folders sort before files, natural order"`: S02's leaves are `["E9.mkv", "E10.mkv"]`; root children names are `["The.Lantern.Keepers.S01", "The.Lantern.Keepers.S02", "readme.nfo"]`.
- `"a single top-level folder becomes the root"`: with only S01 files, `build/2` returns a folder with `path == "The.Lantern.Keepers.S01"`.
- `"folder states"`: selected `[0, 1, 2]` gives S01 `:all`, S02 `:partial`, and with `[]` S01 is `:none`; `selected_size == 250` for `[0, 1, 2]`.
- `"toggling a partial or empty folder selects it, a full one clears it"`: `toggle(MapSet.new([2]), files, {:folder, "The.Lantern.Keepers.S02"}) == MapSet.new([2, 3])`, toggling again gives `MapSet.new([])`.
- `"toggling a file flips it"` and `"toggle_all selects all unless all are selected"`.
- `"a folder path that matches no files leaves the selection unchanged"`.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/file_tree_test.exs`. Expected: FAIL, `FileTree` undefined.

- [ ] **Step 3: Implement** the module. Split each path on `/`; natural sort key is the name downcased and split into digit and non-digit runs with digits as integers. A folder's files for `toggle/3` are those whose path starts with `path <> "/"`. Toggling a folder uses its current state: `:all` removes its files, otherwise adds them.

- [ ] **Step 4: Run** the test file. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): build torrent file lists into a folder tree`.

### Task 2: tree component, hook, Files panel

**Files:**
- Create: `lib/mydia_web/components/file_tree_components.ex`
- Create: `assets/js/hooks/indeterminate_checkbox.mjs`
- Modify: `assets/js/app.js` (register `IndeterminateCheckbox` next to the other hooks)
- Modify: `lib/mydia_web/live/downloads_live/files_panel.ex`
- Test: `test/mydia_web/live/downloads_live/files_panel_test.exs`

**Interfaces:**
- Consumes: Task 1's `FileTree`.
- Produces: `MydiaWeb.FileTreeComponents.file_tree/1` with attrs `id` (string, required), `files` (list, required), `selected` (MapSet, required), `disabled` (boolean, false), `target` (any, nil), `show_progress` (boolean, false). It calls `FileTree.build/2` itself. Events sent to `target`: `"toggle_files"` with `%{"folder" => path}` or `%{"index" => "3"}`, and `"toggle_all_files"`. DOM ids: `#{id}-all`, `#{id}-folder-#{:erlang.phash2(path)}`, `#{id}-file-#{index}`. Every checkbox carries `data-state="all|none|partial"`.

- [ ] **Step 1: Write the failing LiveView tests** (extend the existing `StubAdapter` setup in `files_panel_test.exs`; files as in Task 1, all `included?: true` except index 3).
  - `"renders the files as a tree"`: `has_element?(view, "#download-files-tree-folder-#{:erlang.phash2("The.Lantern.Keepers.S02")}[data-state=partial]")`.
  - `"toggling a folder then saving sends that selection"`: click the S02 folder checkbox, submit `#download-files-form`; `StubAdapter.selections()` head is `{client_id, [0, 1, 2, 3, 4]}`.
  - `"select all clears a fully selected torrent"`: the fixture starts partly selected (index 3 unticked), so click `#download-files-tree-all` twice (select all, then clear all); Save then shows the existing "Keep at least one video file." error.
  - `"shows unsaved changes until saved"`: `#download-files-unsaved` appears after a toggle and is gone after Save.
  - `"a failed save keeps the operator's choice"`: `StubAdapter.selection_fails!()`, toggle, Save; the toggled folder keeps its new `data-state`.
  - `"an imported download renders disabled"`: checkboxes have `disabled`, no `#download-files-save`.
  - Update existing tests that addressed `#download-file-<index>` to `#download-files-tree-file-<index>`.

- [ ] **Step 2: Run** `./dev mix test test/mydia_web/live/downloads_live/files_panel_test.exs`. Expected: new tests FAIL.

- [ ] **Step 3: Implement the component.** Header: select-all checkbox plus `gettext("%{selected} of %{total} selected", ...)` using `format_file_size/1`. Folders as `<details open={folder.path == tree.path} phx-mounted={JS.ignore_attributes(["open"])}>` (so a patch never closes a folder the operator opened), each row showing `selected_size` of `size`, with the checkbox inside `<summary>` (stop the click from toggling `<details>` by putting `phx-click` on the input only). File rows reuse the Files panel's progress bar when `show_progress`. Checkboxes use `phx-hook="IndeterminateCheckbox"` and `checked={state == :all}`.

- [ ] **Step 4: Implement the hook**: `mounted()` and `updated()` both set `this.el.indeterminate = this.el.dataset.state === "partial"`.

- [ ] **Step 5: Switch `FilesPanel`.** Add assigns `selected` (MapSet from `included?` on each load) and `saved` (the same set as loaded). Handle `"toggle_files"` and `"toggle_all_files"` via `FileTree`. Save submits `MapSet.to_list(selected)` (drop the `files[]` params parsing). Render `#download-files-unsaved` (`gettext("Unsaved changes")`) when `selected != saved`. `reload_after_error/2` keeps `selected` as is.

- [ ] **Step 6: Run** the files panel tests and `./dev mix test test/mydia_web/live/downloads_live/detail_drawer_test.exs`. Expected: PASS.

- [ ] **Step 7: Run** `./dev mix precommit` (in chunks if it outruns the Bash cap). Expected: clean.

- [ ] **Step 8: Commit** `feat(downloads): choose torrent files from a folder tree`, push, open PR 1 ("Torrent file tree on the Downloads drawer", "Part of #1542").

## PR 2: choosing files before a grab

Branch `feat/torrent-file-choice` from PR 1's branch.

### Task 3: manual selections in `WantedFiles`

**Files:**
- Modify: `lib/mydia/downloads/file_selection.ex` (add `keeps_video?/2`)
- Modify: `lib/mydia/downloads/torrent_files.ex` (use it in `check_importable/2`)
- Modify: `lib/mydia/downloads/wanted_files.ex`
- Test: `test/mydia/downloads/wanted_files_test.exs`, `test/mydia/downloads/file_selection_test.exs`

**Interfaces:**
- Produces:
  - `FileSelection.keeps_video?([%{index: i, path: p}], [non_neg_integer()]) :: boolean()`
  - `WantedFiles` struct gains `source: :auto | :manual` (default `:auto`).
  - `WantedFiles.manual(context(), [file_map()], [non_neg_integer()]) :: {:ok, t()} | {:error, :no_importable_file}` returning `only_files` (sorted chosen indexes), `selected_bytes`, `file_episodes` (every chosen video mapping to one episode, same parsing as `select/2`), `skipped_owned_episode_ids` (owned episodes of unchosen videos), `skipped_files`, `source: :manual`.
  - `to_metadata/1` with `source: :manual` writes `"file_selection" => %{"source" => "manual"}` instead of the auto entry, plus `"selected_files"`, `"file_episodes"`, `"skipped_owned_episode_ids"`.

- [ ] **Step 1: Write failing tests** in `wanted_files_test.exs` (reuse its show and episode fixtures):
  - `"manual keeps exactly the chosen files"`: `only_files == [0, 2]`, `selected_bytes` equals their lengths.
  - `"manual maps an operator-added owned episode"`: a file `select/2` would skip as owned, chosen manually, appears in `file_episodes`.
  - `"manual records owned episodes the operator left out"`.
  - `"manual refuses a choice without a video"`: only a subtitle index gives `{:error, :no_importable_file}`.
  - `"a manual selection writes the manual stamp"`: `to_metadata(sel)["file_selection"] == %{"source" => "manual"}`.
  - `file_selection_test.exs`: `keeps_video?/2` true for a chosen `.mkv`, false for a chosen `sample.mkv` only.

- [ ] **Step 2: Run** both files. Expected: FAIL.

- [ ] **Step 3: Implement.** Extract the episode lookup in `select_episodes/3` so `manual/3` reuses `parse/1`, `lookup_episodes/2`, `episode_for/3` and `owned_episode_ids/1`; a non-TV context gets `file_episodes: %{}` and `skipped_owned_episode_ids: []`. `TorrentFiles.check_importable/2` calls `FileSelection.keeps_video?/2`.

- [ ] **Step 4: Run** those two files and `test/mydia/downloads/torrent_files_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(downloads): record an operator's file choice made before the add`.

### Task 4: `Queue.FilePreview` and the confirmed add

**Files:**
- Create: `lib/mydia/downloads/queue/file_preview.ex`
- Modify: `lib/mydia/downloads/queue/client_selection.ex`
- Modify: `lib/mydia/downloads.ex` (delegates)
- Test: `test/mydia/downloads/queue/file_preview_test.exs`

**Interfaces:**
- Consumes: Task 3's `WantedFiles.manual/3`.
- Produces:
  - `%Queue.FilePreview{search_result, opts, client_config, adapter, torrent_input_result, listed, peers, context, auto}` where `listed` is the adapter's listing (`%{index, path, length}`) and `auto` is `WantedFiles.t() | nil`.
  - `FilePreview.build(SearchResult.t(), keyword()) :: {:ok, t()} | {:error, :unsupported | :no_files | :duplicate_download | :already_have_files | term()}`
  - `FilePreview.files(t()) :: [TorrentFile.t()]` (`size` from `length`, `included?` from `auto_selected/1`)
  - `FilePreview.auto_selected(t()) :: MapSet.t()` (`auto.only_files`, or every listed index)
  - `ClientSelection.prepare(SearchResult.t(), keyword()) :: {:ok, %{torrent_input_result: term(), download_type: atom() | nil, opts: keyword(), client_config: map(), adapter: module()}} | {:error, term()}`
  - `ClientSelection.file_choice_available?() :: boolean()` (the client `select_client_by_priority(:torrent)` picks supports file selection)
  - `Downloads.preview_files/2` delegating to `FilePreview.build/2`; `Downloads.file_choice_available?/0`.
  - `add_to_client/2` accepts `file_preview: FilePreview.t()` with `only_files: [index]`.

- [ ] **Step 1: Write failing tests** in `file_preview_test.exs`, mirroring the Bypass rqbit setup of `wanted_files_grab_test.exs` (`setup_runtime_config([rqbit_client(port)])`):
  - `"previews a magnet without adding it"`: Bypass expects `POST /torrents` with `list_only=true` once and no other add; `{:ok, preview}`; `FilePreview.files(preview)` has the listed paths.
  - `"auto picks match the grab path"`: with an owned episode, `auto_selected/1` excludes its file.
  - `"a client without file selection is unsupported"`: `PlainAdapter` from the grab test gives `{:error, :unsupported}`.
  - `"an empty listing is :no_files"` and `"a failed listing returns the error"`.
  - `"a duplicate is refused before any fetch"`: an active download for the item gives `{:error, :duplicate_download}` and Bypass sees no request.
  - `"confirming adds with the chosen files and fetches nothing again"`: run `Grabber.run_grab/3` with `file_preview: preview, only_files: [1]`; Bypass sees exactly one non-list `POST /torrents` whose `only_files` is `1`; the download's metadata has `"file_selection" => %{"source" => "manual"}` and `"selected_files" => [1]`.
  - `"confirming a choice without a video fails the grab"`: `only_files: [subtitle_index]` gives a failed grab with reason `:no_importable_file`, and nothing is added.
  - `"file_choice_available? follows the priority client"`: true with rqbit, false with `PlainAdapter` first.

- [ ] **Step 2: Run** the file. Expected: FAIL.

- [ ] **Step 3: Extract `prepare/2`** from `add_to_client/2` (fetch, banned-hash refusal, type detection, content type, client and adapter), and change `add_with_client` to take `{selection, peers, listed}` from its caller. `add_to_client/2` becomes: with a `:file_preview` opt, use the preview's `prepare` fields, listing and peers and `WantedFiles.manual(preview.context, preview.listed, only_files)`; without it, `prepare/2` then `select_files/6` as today. Existing grab tests must pass unchanged.

- [ ] **Step 4: Implement `FilePreview.build/2`**: normalise metadata, `Duplicates.check_for_duplicate_download/2` with `download_type` set, `ClientSelection.prepare/2`, refuse an NZB or an adapter without `supports_file_selection?` as `:unsupported`, `Client.list_torrent_files/3`, then `WantedFiles.context_for/2` and `select/2` (rescued to `nil` like `safe_select/3`).

- [ ] **Step 5: Run** `file_preview_test.exs` and `./dev mix test test/mydia/downloads/queue test/mydia/downloads/grabber_test.exs`. Expected: PASS.

- [ ] **Step 6: Commit** `feat(downloads): preview a torrent's files before adding it`.

### Task 5: "Choose files…" on the media page

**Files:**
- Create: `lib/mydia_web/live/media_live/show/file_choice_events.ex`
- Create: `lib/mydia_web/live/media_live/show/file_choice_components.ex` (`file_choice_modal/1`)
- Modify: `lib/mydia_web/live/media_live/show/search_events.ex` (assign `file_choice?` in the three manual-search openers; expose the grab success path as `grab_search_result/3` taking extra opts)
- Modify: `lib/mydia_web/live/media_live/show/manual_search_components.ex` (`release_row` gets `attr :file_choice?, :boolean, default: false` and the button)
- Modify: `lib/mydia_web/live/media_live/show/modals.ex:909` (pass `file_choice?`)
- Modify: `lib/mydia_web/live/media_live/show.ex` (events and `handle_async(:file_preview, ...)`), `show.html.heex` (render the modal)
- Modify: `lib/mydia/downloads/README.md` ("Wanted files and early import")
- Test: `test/mydia_web/live/media_live/show/file_choice_test.exs`

**Interfaces:**
- Consumes: Task 4's `Downloads.preview_files/2`, `Downloads.file_choice_available?/0`, `FilePreview.files/1`, `FilePreview.auto_selected/1`; Task 2's `file_tree/1`.
- Produces: events `"choose_files"` (`%{"ref" => ref}`), `"toggle_files"`, `"toggle_all_files"`, `"confirm_file_choice"`, `"cancel_file_choice"`, `"download_auto_from_choice"`; assigns `file_choice?`, `file_choice` (`nil | %{ref, status: :loading | :ready | {:error, reason}, preview, selected}`).

- [ ] **Step 1: Write failing tests** (setup like `grab_flow_test.exs`, with the Bypass rqbit client from Task 4 and a fictional show):
  - `"the button shows only when the client can choose files"`: `#choose-files-<ref>` present with rqbit, absent with a plain client, absent on an NZB result.
  - `"opening shows the automatic picks ticked"`: click it, `render_async(view)`; `#file-choice-modal` contains `#file-choice-tree-file-0[checked]` and the text "picked 2 of 3 files".
  - `"confirming grabs the chosen files"`: toggle a season folder, click `#file-choice-confirm`; the download row's metadata has `"selected_files"` equal to the folder's indexes, and the release row shows grabbing.
  - `"confirm is disabled without a video"`.
  - `"cancel adds nothing"`: Bypass sees only the `list_only` request.
  - `"a failed preview offers the automatic download"`: listing returns 500; `#file-choice-auto` is shown and clicking it grabs like Download.
  - `"closing during loading ignores the late result"`: cancel before `render_async`; after it, `#file-choice-modal` is absent.
  - `"a duplicate found at confirm shows already downloading"`.

- [ ] **Step 2: Run** the file. Expected: FAIL.

- [ ] **Step 3: Implement the button**: `btn btn-ghost` with `hero-folder-open`, `id={"choose-files-#{ref}"}`, `phx-click="choose_files"`, title `gettext("Choose files…")`, shown in the default `cond` branch only when `@file_choice?` and `@result.download_protocol != :nzb`.

- [ ] **Step 4: Implement `FileChoiceEvents`**: `choose_files` authorises like `download_from_search/2`, finds the result by ref, assigns `file_choice` loading, and `start_async(:file_preview, fn -> Downloads.preview_files(result_with_metadata, opts) end)` using the same opts and season metadata `grab_search_result` builds (extract that into a shared `grab_opts/2`). `handle_async` ignores a result whose ref no longer matches `file_choice`. Confirm calls `SearchEvents.grab_search_result(result, socket, file_preview: preview, only_files: MapSet.to_list(selected))` and clears `file_choice`. Cancel uses `cancel_async(socket, :file_preview)` and clears it.

- [ ] **Step 5: Implement the modal** (daisyUI `modal modal-open`, `id="file-choice-modal"`): loading shows a spinner, `gettext("Fetching the file list…")` and `gettext("A magnet link can take a while.")`; ready shows the title, `ngettext("Mydia picked %{count} of %{total} file", "Mydia picked %{count} of %{total} files", ...)`, `<.file_tree id="file-choice-tree" ...>`, and `#file-choice-confirm` reading `gettext("Download selected (%{size})")`, disabled with `gettext("Choose at least one video file.")` when `FileSelection.keeps_video?/2` is false; errors show the reason and `#file-choice-auto` (`gettext("Download with automatic selection")`).

- [ ] **Step 6: Document** in `lib/mydia/downloads/README.md` a paragraph on the manual choice before a grab: `FilePreview`, the reused listing, and the `manual` stamp.

- [ ] **Step 7: Run** the new file plus `test/mydia_web/live/media_live/show/grab_flow_test.exs` and `manual_search_streaming_test.exs`. Expected: PASS.

- [ ] **Step 8: Run** `./dev mix precommit` (gettext catalog refresh included). Expected: clean.

- [ ] **Step 9: Commit** `feat(media): choose a release's files before grabbing it`, push, open PR 2 ("Choose files before a manual grab", "Closes #1542").
