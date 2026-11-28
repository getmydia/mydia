# Torrent file tree and file choice before a manual grab

Status: approved design, 2026-11-28. Answers issue #1542. Builds on
`design/specs/2026-11-14-builtin-torrent-file-selection-seeding-design.md`
(the Files panel) and
`design/specs/2026-11-14-builtin-torrent-per-file-and-disk-guard-design.md`
(wanted files before the add).

## Goal

An operator using the built-in torrent client (rqbit) can:

1. See a torrent's files as a folder tree on the Downloads detail drawer,
   select or deselect a whole folder (a season) in one click, and see sizes
   per folder and for the whole selection.
2. Choose the files of a release before it is added, from the manual-search
   results on a movie or show page, starting from the files Mydia would pick
   on its own.

Automatic grabs, the one-click Download button, external clients and the
global Search page behave exactly as they do today.

## Where Mydia stands

- Only clients with `c:Client.set_file_selection/3` and `c:torrent_files/2`
  can select files (`Client.supports_file_selection?/1`). Today that is the
  built-in rqbit client.
- `MydiaWeb.DownloadsLive.FilesPanel` lists a download's files flat, one
  checkbox each, and writes the selection with `TorrentFiles.save/2` under
  `TorrentFiles.with_selection_lock/2`, stamping
  `"file_selection" => %{"source" => "manual"}` so
  `BuiltIn.FileSelectionPolicy` leaves it alone. It refuses a selection
  without an importable video and an imported download.
- `Queue.ClientSelection.add_to_client/2` already lists a torrent's files
  before every rqbit add (`Client.list_torrent_files/3`, rqbit
  `POST /torrents?list_only=true`, which resolves a magnet's metadata and adds
  nothing), picks the files with `WantedFiles.select/2`, and adds with
  `only_files`. The listing shares the client's 30-second request timeout.
- A manual grab from a media page goes through
  `MediaLive.Show.SearchEvents.download_from_search/2` to
  `Downloads.initiate_download/2`.

## Decisions

- **The pre-grab choice is a separate action.** Download stays one click.
  A "Choose files…" button sits next to it. Listing a magnet can take tens of
  seconds, which no plain Download should wait for.
- **Media page only.** The global Search page can add the title to the
  library as part of the grab, so the episode context that drives the
  automatic picks does not exist yet when a dialog would open.
- **Server-rendered tree.** The tree is built and toggled in Elixir and
  tested in ExUnit. The only JavaScript is a hook that sets a checkbox's
  `indeterminate` property, which HTML has no attribute for.
- **Confirm reuses the preview.** The fetched torrent, the client and the
  listing are carried from the preview into the add, so a magnet resolves
  once.
- **Save stays explicit.** The Files panel writes to the client only on Save,
  as today.
- **Two PRs.** The tree on the Downloads page first, the pre-grab dialog
  second. The dialog reuses the tree component.

## Part 1: the file tree

### `Mydia.Downloads.FileTree`

A pure module: no client calls, no database.

- `build(files, selected)` takes files as `%{index, path, size}` (a
  `TorrentFile` or a listing entry) and a `MapSet` of selected indexes, and
  returns the root of a tree of `%FileTree.Folder{}` and `%FileTree.Leaf{}`
  structs.
  - A folder carries `path` (its full relative path, the toggle key), `name`,
    `children`, `size` (all files below it), `selected_size`, and `state`:
    `:all`, `:none` or `:partial`.
  - A leaf carries `index`, `name`, `size`, `selected?`, and the source file
    so the component can show progress.
  - Children sort folders first, then by name in natural order (`S2` before
    `S10`, `E9` before `E10`), case-insensitively.
  - When every file sits under one top-level folder, that folder is the root.
    The component renders it expanded.
- `toggle(selected, files, {:folder, path} | {:file, index})` returns the new
  selection. A file flips. A folder whose state is `:all` clears every file
  below it; a folder in `:none` or `:partial` selects every file below it.
- `toggle_all(selected, files)` applies the same rule to the whole torrent.
- `selected_size(files, selected)` sums the selection, for the header.

### `MydiaWeb.Components.FileTreeComponents.file_tree/1`

A function component in its own file. It is used by the Files panel and the
pre-grab dialog, and is not globally imported.

Attributes: `id`, `tree`, `files` (for the header totals), `selected`,
`disabled`, `target` (the `phx-target`), and `show_progress`.

- A header row holds a select-all checkbox (three states, `phx-click`
  `"toggle_all_files"`) and "12.4 GB of 48.1 GB selected".
- Folders render as `<details>`, so expanding and collapsing needs no round
  trip. The root folder starts `open`; every other folder starts closed.
  Each folder row shows a checkbox, a folder
  icon, the name, and `selected_size / size`.
- File rows show a checkbox, the name, the size, and, with `show_progress`,
  the existing progress bar for selected files.
- Checkboxes are `phx-click="toggle_files"` with `phx-value-folder={path}` or
  `phx-value-index={index}`. The parent owns the selection and re-renders.
- Every checkbox carries `data-state` (`all`, `none`, `partial`) and
  `phx-hook="IndeterminateCheckbox"`.
- DOM ids: `#{id}-folder-<hash of path>` and `#{id}-file-<index>`, so tests
  can address rows.

`assets/js/hooks/indeterminate_checkbox.mjs` sets
`this.el.indeterminate = this.el.dataset.state === "partial"` in `mounted`
and `updated`. It does not own the element's DOM, so no `phx-update="ignore"`.

### `FilesPanel`

Loading, Refresh, the empty and failed states, and the error messages are
unchanged.

- On load the selection is seeded into a `MapSet` assign from each file's
  `included?`.
- `toggle_files` and `toggle_all_files` update the assign through `FileTree`.
- The flat list becomes `<.file_tree show_progress>`. When the assign differs
  from what the client reported, the panel shows "Unsaved changes" next to
  Save.
- Save calls `TorrentFiles.save/2` with the assign's indexes. Save remains the
  only write.
- An imported download renders the tree with checkboxes disabled and no Save,
  as the flat list does today.

### Tests

- `test/mydia/downloads/file_tree_test.exs`: nesting, the single-root rule,
  natural sort, each folder state, folder and file toggles, select all,
  size totals, files at the torrent root next to folders.
- `test/mydia_web/live/downloads_live/files_panel_test.exs`: the tree
  renders, toggling a folder and saving sends exactly that folder's indexes to
  the stub adapter, a partly selected folder renders `data-state="partial"`,
  and an imported download renders disabled.

## Part 2: choosing files before a manual grab

### `Downloads.preview_files/2`

`preview_files(search_result, opts) :: {:ok, FilePreview.t()} | {:error, reason}`,
delegating to a new `Queue.FilePreview` module.

It runs the first half of `ClientSelection.add_to_client/2`, extracted into
shared private steps rather than duplicated:

1. Normalise the result's metadata, then `Duplicates.check_for_duplicate_download/2`
   and the missing-target check `Lifecycle` runs before an add.
2. `TorrentFetch.prepare_torrent_input/2` and
   `TorrentFetch.refuse_banned_info_hash/3`. An NZB returns
   `{:error, :unsupported}`.
3. Choose the client exactly as the add would. A client without file
   selection returns `{:error, :unsupported}`.
4. `Client.list_torrent_files/3`. An empty listing returns
   `{:error, :no_files}`.
5. `WantedFiles.select(WantedFiles.context_for(search_result, opts), files)`.

`%FilePreview{}` holds `search_result`, `opts`, `client_config`, `adapter`,
the prepared `torrent_input`, `files`, `peers`, and `auto` (the
`WantedFiles` result). `auto_selected/1` returns the indexes to tick: the
automatic `only_files`, or every listed index when the automatic pass kept
everything.

Nothing is added to the client during a preview.

### Confirming

`initiate_download(search_result, opts)` accepts two new options together:
`file_preview: %FilePreview{}` and `only_files: [index]`.

- `Lifecycle` runs the duplicate and missing-target checks again, since time
  has passed since the preview.
- `ClientSelection.add_to_client/2` takes the torrent input, client, listing
  and peers from the preview instead of fetching and listing again.
- The choice is refused with `{:error, :no_importable_file}` when it holds no
  importable video, the same rule as `TorrentFiles.save/2` (extracted to a
  shared function, not copied).
- The disk-space guard counts the chosen files' bytes.
- The add sends the chosen indexes as `only_files`. rqbit's
  `reconcile_only_files` already handles a torrent it manages.

The download's metadata records:

- `"file_selection" => %{"source" => "manual"}`, so `FileSelectionPolicy`
  never touches it, exactly like a Files panel save.
- `"selected_files"`: the chosen indexes.
- `"file_episodes"`: every chosen video that parses to a single episode of
  the item. A new `WantedFiles.episode_map(context, files)` maps any list of
  files using the rules `select/2` already uses, so a file the operator added
  beyond the automatic picks can still be imported early.
- `"skipped_owned_episode_ids"`: the automatic list, minus any episode whose
  file the operator chose to download.

### UI

In `MediaLive.Show.ManualSearchComponents`:

- When the manual-search dialog opens, `SearchEvents` computes once whether
  the client a torrent grab would use supports file selection, and assigns
  `file_choice?`.
- Torrent results with `file_choice?` get a secondary "Choose files…" button
  (`hero-folder-open`, `btn-ghost`) next to Download, with
  `phx-click="choose_files"` and `phx-value-ref`.

A new `MediaLive.Show.FileChoiceEvents` module and a `file_choice_modal`
component handle the flow:

1. `choose_files` opens the modal (daisyUI `modal`, `id="file-choice-modal"`)
   in a loading state and starts `start_async(:file_preview, ...)`. The modal
   shows a spinner, "Fetching the file list…", "A magnet link can take a
   while.", and Cancel.
2. On `{:ok, preview}` the modal shows the release title, "Mydia picked N of M
   files", and `<.file_tree>` seeded with `FilePreview.auto_selected/1`.
   `toggle_files` and `toggle_all_files` update the selection.
3. The confirm button reads "Download selected (12.4 GB)". It is disabled
   when no importable video is selected, with the reason shown under the
   tree. Confirm calls `initiate_download` with the preview and the indexes,
   then closes the modal and marks the result grabbed exactly as
   `download_from_search/2` does on success, sharing its success and error
   handling.
4. `{:error, :unsupported | :no_files | reason}` or an exit shows the reason
   and a "Download with automatic selection" button, which runs the plain
   `download_from_search` path. A duplicate shows the same message the plain
   Download shows.
5. Cancel, or closing the modal, drops the preview and cancels a pending
   async. Nothing was added, so nothing is undone.

The preview lives only in the LiveView's assigns. A torrent file body is held
until the modal closes.

### Tests

- `test/mydia/downloads/queue/file_preview_test.exs`, Bypass for rqbit: a
  `.torrent`, a magnet, a client without file selection, a failed and an
  empty listing, a duplicate refused before any fetch.
- Lifecycle tests: confirming with a preview adds with the chosen
  `only_files`, fetches and lists nothing again, stamps `manual`, writes the
  episode map for an operator-added file, and refuses a choice without a
  video.
- `WantedFiles.episode_map/2` unit tests.
- LiveView: the button appears only with `file_choice?`; the modal shows the
  automatic picks ticked; ticking a season folder and confirming creates the
  download with those indexes; Cancel creates nothing; a failed preview offers
  the automatic download.

## Out of scope

- File selection for qBittorrent, Transmission, rTorrent or debrid clients.
- The global Search page.
- Changing automatic grabs or `FileSelectionPolicy`.
- Remembering an operator's choices for future releases.

## Docs

`lib/mydia/downloads/README.md`, "Wanted files and early import", gains a
paragraph on the manual choice before a grab and the metadata it writes.
