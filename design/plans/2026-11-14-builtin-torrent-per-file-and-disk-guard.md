# Built-in torrent: wanted files, early import, disk-space guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rqbit downloads only the files Mydia will import, imports each one as it completes, and never starts or continues a download the disk cannot hold.

**Architecture:** `Queue.ClientSelection` lists a torrent's files through a new optional adapter callback, asks a pure-ish `WantedFiles` which to keep, checks free space for the built-in client, then adds with `only_files`. `DownloadMonitor` turns rqbit's per-file progress into partial `MediaImport` jobs. A `SpaceGuard` process under the built-in supervisor pauses and resumes torrents around a free-space reserve.

**Tech Stack:** Elixir/Phoenix, Oban, Req + Bypass, rqbit 9.0.1 HTTP API, busybox `df`.

**Spec:** `design/specs/2026-11-14-builtin-torrent-per-file-and-disk-guard-design.md`

## Global Constraints

- rqbit API as pinned by `RQBIT_VERSION=9.0.1`: `POST /torrents?list_only=true`, `POST /torrents?only_files=0,3&initial_peers=a:1,b:2`, `GET /torrents/{id}/stats/v1` field `file_progress`.
- Clients without `list_torrent_files/2` behave exactly as today.
- Listing or selection failure never blocks a grab: warn and add every file.
- Disk guard only for `BuiltIn.managed?/1` configs. Setting `min_free_space_gb`, env `MYDIA_TORRENT_MIN_FREE_SPACE_GB`, default `5`, `0` disables. Resume threshold: reserve + 1 GiB. Poll: 60 s. Record file: `<state_dir>/space-paused`.
- Refusal copy: `"Not enough space on the download volume: needs 41.2 GB, 12.8 GB free, 5 GB kept free"` (decimal GB, one decimal; reserve shown as given).
- Fictional media only in tests (`The Lantern Keepers`, `Saltmarsh Hollow`). No em dashes in prose or copy.
- Migrations: none. All new state lives in `downloads.metadata` (JSON).
- Run tests with `./dev mix test <path>`; finish each PR with `./dev mix precommit`. Commit with plain `git commit -m` from the worktree; check `git show --stat` after each commit.

## Review Focus

1. **A magnet whose metadata never resolves.** `list_only` blocks until rqbit resolves it; the grab must fall back to a plain add when the adapter's request times out, not fail the grab. Test in Task 4.
2. **A torrent where every file is a sample or junk except one unparseable video.** The video must be kept (unmatched means kept), never an empty `only_files`. Test in Task 3.
3. **rqbit run by the user on another host with path mapping.** Early import must skip paths that do not exist locally and leave them to the full import. Test in Task 7.
4. **Completion arriving while a partial import is queued.** The full import must still be enqueued and run. Test in Task 6.
5. **`df` missing or printing an unexpected format.** Grabs and the guard keep working with a warning. Tests in Tasks 10 and 12.

---

## PR 1: wanted files and early import

### Task 1: Per-file progress from rqbit

**Files:**
- Modify: `lib/mydia/downloads/structs/download_status.ex` (struct, `@type t`)
- Modify: `lib/mydia/downloads/structs/enriched_download.ex` (field after `:files`)
- Modify: `lib/mydia/downloads/history.ex:719` (copy `file_progress` next to `files`)
- Modify: `lib/mydia/downloads/client/rqbit.ex` (`build_status/2`)
- Test: `test/mydia/downloads/client/rqbit_test.exs`

**Interfaces:**
- Produces: `DownloadStatus.file_progress :: [%{index: non_neg_integer(), path: String.t(), length: non_neg_integer(), have: non_neg_integer()}] | nil`, same field on `EnrichedDownload`.

- [ ] **Step 1: Write the failing test** in `describe "get_status/2"`:

```elixir
test "maps file_progress by index, keeping indices of excluded files", %{bypass: bypass, config: config} do
  # details: three files, the middle one included: false
  # stats: "file_progress" => [100, 0, 40]
  assert {:ok, status} = Rqbit.get_status(config, @hash)
  assert status.file_progress == [
           %{index: 0, path: "/downloads/Pack/e01.mkv", length: 100, have: 100},
           %{index: 2, path: "/downloads/Pack/e03.mkv", length: 50, have: 40}
         ]
  assert status.files == ["/downloads/Pack/e01.mkv", "/downloads/Pack/e03.mkv"]
end

test "file_progress is nil when stats carry none", ... do
  assert {:ok, %{file_progress: nil}} = Rqbit.get_status(config, @hash)
end
```

- [ ] **Step 2: Run and see it fail:** `./dev mix test test/mydia/downloads/client/rqbit_test.exs` (FAIL: key `:file_progress` not found).
- [ ] **Step 3: Implement.** Add `file_progress: nil` to `DownloadStatus` and `EnrichedDownload`; in `Client.Rqbit` build it from `details["files"]` zipped with `stats["file_progress"]` by position before `file_included?/1` filtering, reusing the path join `resolve_torrent_files/2` uses. `nil` when either list is missing.
- [ ] **Step 4: Run and see it pass**, plus `./dev mix test test/mydia/downloads` (no regressions).
- [ ] **Step 5: Commit** `feat(downloads): report per-file progress from rqbit`.

### Task 2: `list_torrent_files/2` and selective add

**Files:**
- Modify: `lib/mydia/downloads/client.ex` (callback, `@optional_callbacks`, `add_torrent_opts` type, dispatcher `list_torrent_files/3`)
- Modify: `lib/mydia/downloads/client/rqbit.ex` (`list_torrent_files/2`, `add_params/2`)
- Test: `test/mydia/downloads/client/rqbit_test.exs`

**Interfaces:**
- Produces: `@callback list_torrent_files(config(), torrent_input()) :: {:ok, %{files: [%{index: non_neg_integer(), path: String.t(), length: non_neg_integer()}], peers: [String.t()]}} | {:error, Error.t()}`
- Produces: `Client.list_torrent_files(adapter, config, input) :: same | {:error, :unsupported}` (returns `{:error, :unsupported}` when `function_exported?(adapter, :list_torrent_files, 2)` is false).
- Produces: add options `only_files: [non_neg_integer()] | nil`, `initial_peers: [String.t()] | nil`.

- [ ] **Step 1: Write failing tests:**

```elixir
test "list_torrent_files posts list_only and returns files and peers", %{bypass: bypass, config: config} do
  Bypass.expect_once(bypass, "POST", "/torrents", fn conn ->
    assert conn.query_params["list_only"] == "true"
    json_resp(conn, 200, %{"id" => nil, "output_folder" => "/downloads/Pack",
      "seen_peers" => ["10.0.0.2:6881"],
      "details" => %{"info_hash" => @hash, "output_folder" => "/downloads/Pack",
        "files" => [%{"name" => "e01.mkv", "components" => ["Pack", "e01.mkv"], "length" => 100, "included" => true, "attributes" => %{}}]}})
  end)
  assert {:ok, %{files: [%{index: 0, path: "Pack/e01.mkv", length: 100}], peers: ["10.0.0.2:6881"]}} =
           Rqbit.list_torrent_files(config, {:magnet, "magnet:?xt=urn:btih:#{@hash}"})
end

test "add_torrent sends only_files and initial_peers comma-joined", ... do
  # assert conn.query_params["only_files"] == "0,3" and ["initial_peers"] == "10.0.0.2:6881,10.0.0.3:6881"
  assert {:ok, @hash} = Rqbit.add_torrent(config, {:magnet, @magnet}, only_files: [0, 3], initial_peers: ["10.0.0.2:6881", "10.0.0.3:6881"])
end

test "add_torrent omits only_files when nil or empty", ...
test "list_torrent_files returns the API error on non-2xx", ...
test "Client.list_torrent_files returns {:error, :unsupported} for an adapter without the callback"
```

Paths in `files` are relative (`components` joined with `/`), because the torrent is not added yet and has no output folder of its own.

- [ ] **Step 2: Run, see failures.**
- [ ] **Step 3: Implement** the callback (guarded like the other calls) and extend `add_params/2` with `maybe_put(:only_files, join(opts[:only_files]))` and `initial_peers` likewise; empty list counts as nil.
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/client/` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): list a torrent's files before adding it to rqbit`.

### Task 3: `WantedFiles`

**Files:**
- Create: `lib/mydia/downloads/wanted_files.ex`
- Test: `test/mydia/downloads/wanted_files_test.exs` (`Mydia.DataCase`)

**Interfaces:**
- Consumes: file maps from Task 2.
- Produces:

```elixir
defstruct only_files: nil,            # [index] | nil (nil = keep everything)
          selected_bytes: 0,
          file_episodes: %{},         # %{index => episode_id}
          skipped_owned_episode_ids: []

@spec select(%{media_item: MediaItem.t() | nil, season_number: integer() | nil,
               targeted_episode_ids: [binary()]}, [file_map]) :: t()
@spec to_metadata(t() | nil) :: map()   # string keys: "selected_files", "file_episodes" (index keys as strings), "skipped_owned_episode_ids"; %{} for nil
@spec context_for(SearchResult.t(), keyword()) :: map()  # from opts[:media_item_id]/[:episode_id] and search_result.metadata (season_number, episode_ids)
```

- [ ] **Step 1: Write failing table tests** for `The Lantern Keepers` S02, 10 episodes, episodes 1 to 4 with media files, search targeted episodes 5 to 10:

| Case | Files | Expect |
| --- | --- | --- |
| owned skipped | `S02E01.mkv`..`S02E10.mkv` | `only_files` = indices of E05..E10; `skipped_owned_episode_ids` = E01..E04 ids; `file_episodes` maps those 6 indices |
| targeted but owned kept | E03 also in `targeted_episode_ids` | E03 kept |
| subtitles follow video | `S02E01.en.srt`, `S02E05.en.srt` | only E05's subtitle kept |
| samples/extras/junk | `Sample/s02e05.mkv`, `Featurettes/x.mkv`, `info.nfo`, `cover.jpg` | dropped |
| unmatched kept | `bonus_unlabeled.mkv` | kept, absent from `file_episodes` |
| all dropped would empty | every video owned and untargeted | `only_files == nil` |
| nothing dropped | all missing | `only_files == nil` |
| movie | `Saltmarsh.Hollow.2031.mkv`, `Sample/sample.mkv`, `x.nfo` | only the movie index |
| multi-episode file | `S02E05E06.mkv` | kept, not in `file_episodes` |
| `selected_bytes` | | sum of kept lengths (all lengths when `only_files` is nil) |

- [ ] **Step 2: Run, see failures.**
- [ ] **Step 3: Implement.** Parse with `ReleaseParser.parse(Path.basename(path), [])`; samples via `SampleDetector.detect(path) |> SampleDetector.excluded?()`; video and subtitle extensions from the lists import already uses (find them in `lib/mydia/jobs/media_import/discovery.ex`, reuse, do not copy). Owned query: one `MediaFile` query on `episode_id in ^ids and is_nil(trashed_at) and is_nil(extra_kind)`, matching `Queue.Duplicates.all_episodes_have_files?/1`. Episode lookup by `(media_item_id, season, episode_number)` in one query.
- [ ] **Step 4: Run** (PASS).
- [ ] **Step 5: Commit** `feat(downloads): choose which files of a torrent Mydia will import`.

### Task 4: Grab path lists, selects and adds

**Files:**
- Modify: `lib/mydia/downloads/queue/client_selection.ex` (`select_and_add_to_client/2`, `add_torrent_to_client_with_input/4`)
- Modify: `lib/mydia/downloads/queue/lifecycle.ex:75` and `ClientSelection.create_download_record/4` (merge metadata)
- Modify: `lib/mydia/downloads/grabber.ex` (`attach_to_client/3`, `store_client_assignment/3` merges metadata)
- Modify tests matching the 4-tuple: `test/mydia/downloads/queue_test.exs`, `queue_cookie_scope_test.exs`, `cardigann_download_grab_test.exs`, `seeding_limits_test.exs`
- Test: `test/mydia/downloads/queue/wanted_files_grab_test.exs` (Bypass rqbit as a runtime client)

**Interfaces:**
- Consumes: `Client.list_torrent_files/3`, `WantedFiles.select/2`, `context_for/2`, `to_metadata/1`.
- Produces: `select_and_add_to_client(search_result, opts) :: {:ok, client_config, client_id, detected_type, WantedFiles.t() | nil} | {:error, term()}`.
- Produces: private hook `check_space(client_config, selection, search_result) :: :ok | {:error, Error.t()}`, returning `:ok` in this PR; Task 11 fills it in.

- [ ] **Step 1: Write failing tests:**

```elixir
test "lists, then adds with only_files and initial_peers, and records the selection" do
  # Bypass: first POST has list_only=true, second has only_files="4,5,6,7,8,9"
  assert {:ok, download} = Queue.initiate_download(pack_result, media_item_id: show.id)
  assert download.metadata["selected_files"] == [4, 5, 6, 7, 8, 9]
  assert download.metadata["file_episodes"]["4"] == e05.id
end

test "Grabber.run_grab records the selection on the existing row"
test "falls back to adding every file when list_only errors" # second POST has no only_files
test "falls back when list_only times out" # Bypass sleeps past options.timeout
test "falls back when WantedFiles raises" # media_item_id of a deleted item
test "an adapter without list_torrent_files adds as before and returns nil selection"
```

- [ ] **Step 2: Run, see failures.**
- [ ] **Step 3: Implement.** In the `with` after `get_adapter_for_client/1`: list, select inside `try/rescue` (log `Logger.warning("File selection failed; adding every file", ...)`), `check_space/3`, then add with `only_files`/`initial_peers` put into `torrent_opts`. Callers merge `WantedFiles.to_metadata(selection)` into the metadata map they write. Update the existing tests' patterns to `{:ok, _, _, _, _}`.
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads test/mydia/jobs/movie_search_test.exs test/mydia/jobs/tv_show_search_test.exs` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): download only the wanted files of a torrent`.

### Task 5: Partial-pack check ignores skipped owned episodes

**Files:**
- Modify: `lib/mydia/jobs/media_import/file_import.ex:116` (`detect_partial_pack/2`)
- Test: `test/mydia/jobs/media_import/file_import_test.exs` (create if absent)

- [ ] **Step 1: Failing test:** metadata `%{"episode_count" => 10, "skipped_owned_episode_ids" => [4 ids]}`, 6 imported files with distinct episode ids: `assert FileImport.detect_partial_pack(download, files) == nil`; with 5 imported: `== "partial_pack"`.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement:** `expected_count - length(List.wrap(metadata["skipped_owned_episode_ids"]))`.
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `fix(import): do not call a pack partial for episodes it was told to skip`.

### Task 6: `MediaImport` partial mode

**Files:**
- Modify: `lib/mydia/jobs/media_import/args.ex` (`partial: false`, parsed from `"partial"`)
- Modify: `lib/mydia/jobs/media_import.ex` (`do_process_targeted_import/4`, `import_download/2`, `perform/1`)
- Create: `lib/mydia/jobs/media_import/partial.ex` (`enqueue/2`, `executing?/1`, `exclude_early/2`)
- Test: `test/mydia/jobs/media_import_partial_test.exs`

**Interfaces:**
- Produces: `MediaImport.Partial.enqueue(download_id :: binary(), [%{"path" => String.t(), "episode_id" => binary()}]) :: {:ok, Oban.Job.t()} | {:error, term()}`; builds `MediaImport.new(%{"download_id" => id, "target_files" => t, "partial" => true, "use_hardlinks" => true}, unique: [period: 600, keys: [:download_id, :partial], states: [:available, :scheduled, :executing, :retryable]])`, with the same `Oban.insert` / `Repo.insert` fallback `DownloadMonitor.enqueue_import_job/2` uses.
- Produces: `Partial.executing?(download_id) :: boolean()` (an executing `MediaImport` job whose args have this `download_id` and `"partial" => true`).
- Produces: `Partial.exclude_early(files, download) :: files` (drops `%{path: p}` with `p in download.metadata["early_imported_paths"]`).

- [ ] **Step 1: Failing tests:**

```elixir
test "partial import places files, appends early_imported_paths, leaves imported_at nil and keeps the torrent"
  # assert download.imported_at == nil; metadata["early_imported_paths"] == [path]; ClientRemoval not called (no remove request at Bypass)
test "a failed target is left out of early_imported_paths and does not fail the others"
test "partial job is a no-op once the download has completed_at"
test "full import skips early_imported_paths and counts them for detect_partial_pack"
test "full import snoozes 30s while a partial job is executing"   # assert {:snooze, 30}
test "a queued partial job does not block the full import from being enqueued"
  # Partial.enqueue then DownloadMonitor's full enqueue: two jobs in the table
```

- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement.** In partial mode `do_process_targeted_import/4` leaves `imported_at` and `match_status` alone and skips `cleanup_sources` (`MediaServerNotifier.notify_all/0` still runs); it appends successful source paths to `metadata["early_imported_paths"]` and their episode ids to `metadata["early_imported_episode_ids"]` with a fresh read-modify-write of the row and returns `{:ok, :partial}` even if some targets failed (logged). `perform/1`: partial and `download.completed_at` set returns `:ok`; non-partial and `Partial.executing?/1` returns `{:snooze, 30}`. `import_download/2` (non-targeted) pipes discovered files through `Partial.exclude_early/2`, and `detect_partial_pack/2` counts `metadata["early_imported_episode_ids"]` as imported.
- [ ] **Step 4: Run** `./dev mix test test/mydia/jobs/media_import*` (PASS).
- [ ] **Step 5: Commit** `feat(import): import single files of a download before it finishes`.

### Task 7: Monitor enqueues early imports

**Files:**
- Create: `lib/mydia/downloads/early_import.ex`
- Modify: `lib/mydia/jobs/download_monitor.ex` (after `check_progress/3`)
- Test: `test/mydia/downloads/early_import_test.exs`, plus one case in `test/mydia/jobs/download_monitor_test.exs`

**Interfaces:**
- Consumes: `EnrichedDownload.file_progress`, `metadata["file_episodes"]`, `metadata["early_imported_paths"]`, `Partial.enqueue/2`.
- Produces: `EarlyImport.ready_targets(EnrichedDownload.t(), exists? :: (String.t() -> boolean()) \\ &File.exists?/1) :: [%{"path" => String.t(), "episode_id" => binary()}]`; `EarlyImport.run([EnrichedDownload.t()]) :: :ok`.

- [ ] **Step 1: Failing tests** for `ready_targets/2`:
  - complete file with `file_episodes` entry, not yet imported: returned with its episode id;
  - `have < length`: excluded; already in `early_imported_paths`: excluded; no `file_episodes` entry: excluded;
  - `exists?` returns false (path-mapped remote rqbit): excluded;
  - single included file, `file_progress` nil, or status not `"downloading"`: `[]`.
  - Monitor case: a downloading rqbit row with one finished episode produces exactly one partial job.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** `run/1`: for each download with non-empty `ready_targets`, `Partial.enqueue/2`; errors logged, never raised. Call it from `perform/1` with the `active_for_stall_check` list.
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/early_import_test.exs test/mydia/jobs/download_monitor_test.exs` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): import finished episodes while the pack downloads`.

### Task 8: Docs and PR 1 wrap-up

**Files:**
- Modify: `docs/using/download-clients.md` (built-in section: "Only the files Mydia needs" and "Episodes arrive as they finish", with the partial-seeding note from the spec)
- Modify: `lib/mydia/downloads/README.md` (one paragraph: selection metadata keys, partial import uniqueness and snooze)
- Add: the spec and this plan.

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** `./dev mix precommit` (PASS; run the suite in chunks if it outruns the shell timeout).
- [ ] **Step 3: Commit** `docs: built-in client wanted files and early import` including `design/specs/...` and `design/plans/...`.

---

## PR 2: disk-space guard

### Task 9: `min_free_space_gb` setting

**Files:**
- Modify: `lib/mydia/config/schema/built_in_torrent.ex` (field `:min_free_space_gb, :integer, default: 5`, env table, `validate_number(greater_than_or_equal_to: 0)`)
- Modify: `lib/mydia/downloads/built_in/config.ex` (`min_free_space_bytes: 5 * 1024**3`; set from section; drop from `restart_key/1`)
- Modify: `lib/mydia/downloads/built_in/settings.ex` (`@fields`, `@integers`, validation)
- Modify: `lib/mydia_web/live/admin_download_clients_live/built_in_events.ex:26` (`@torrent_fields`), `built_in_form_components.ex` (number field after download path, hint "Grabs that would leave less than this free are refused, and downloads pause below it. 0 turns this off.")
- Modify: `docs/using/reference/environment-variables.md`
- Test: `test/mydia/downloads/built_in/config_test.exs`, `settings_test.exs`, `test/mydia_web/live/admin_download_clients_live/built_in_settings_test.exs`

- [ ] **Step 1: Failing tests:** env `MYDIA_TORRENT_MIN_FREE_SPACE_GB=12` gives `config.min_free_space_bytes == 12 * 1024 ** 3`; default `5 * 1024 ** 3`; `restart_key/1` equal for configs differing only in it; settings rejects `-1`; form field `#built-in-min-free-space-gb` saves `0`.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/built_in test/mydia_web/live/admin_download_clients_live` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): setting for the free space the built-in client keeps`.

### Task 10: `DiskSpace`

**Files:**
- Create: `lib/mydia/downloads/built_in/disk_space.ex`
- Test: `test/mydia/downloads/built_in/disk_space_test.exs`

**Interfaces:**
- Produces: `DiskSpace.free_bytes(path, cmd \\ &System.cmd/3) :: {:ok, non_neg_integer()} | {:error, term()}`; `DiskSpace.format_gb(bytes) :: String.t()` (`"41.2 GB"`, decimal GB, one decimal).

- [ ] **Step 1: Failing tests:** busybox and GNU `df -Pk` outputs parse to `available * 1024`; a missing path (exit 1) and garbage output return `{:error, _}`; `cmd` raising `ErlangError` (no `df`) returns `{:error, :df_unavailable}`; `format_gb(41_200_000_000) == "41.2 GB"`.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** with `cmd.("df", ["-Pk", path], stderr_to_stdout: true)`, last line, fourth column.
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** `feat(downloads): measure free space on the download volume`.

### Task 11: Refuse grabs that will not fit

**Files:**
- Modify: `lib/mydia/downloads/queue/client_selection.ex` (`check_space/3` from Task 4)
- Modify: `lib/mydia/downloads/grabber.ex` (`format_error/1` clause for `{:client_error, %Error{type: :insufficient_space, message: m}}` returning `m`)
- Test: `test/mydia/downloads/queue/disk_guard_grab_test.exs`

**Interfaces:**
- Consumes: `BuiltIn.managed?/1`, `BuiltIn.runtime/0` (`%Runtime{config: %Config{download_path, min_free_space_bytes}}`), `DiskSpace.free_bytes/2`.
- Produces: grab option `:free_bytes` (`(String.t() -> {:ok, integer()} | {:error, term()})`, default `&DiskSpace.free_bytes/1`), read from the opts `select_and_add_to_client/2` already receives, so tests inject it without global env.

- [ ] **Step 1: Failing tests:**
  - selected 41.2 GB, free 12.8 GB, reserve 5 GiB: `{:error, {:client_error, %Error{type: :insufficient_space}}}`, no add request reaches Bypass, message equals the copy in Global Constraints;
  - fits: adds;
  - `min_free_space_bytes == 0`: adds without calling `df`;
  - `df` fails: adds, warning logged;
  - non-managed rqbit config: never calls `df`;
  - listing failed: uses `search_result.size`; size nil: skips the check;
  - grab refusal leaves no blacklist row (`ReleaseBlacklist` empty).
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): refuse a grab the download volume cannot hold`.

### Task 12: `SpaceGuard`

**Files:**
- Create: `lib/mydia/downloads/built_in/space_guard.ex`
- Modify: `lib/mydia/downloads/built_in/status.ex` (`disk: :ok` in struct; `put/3` spec adds `:disk`; `describe({:low_disk, %{free: f, reserve: r}})` returns `"The download volume is low on space (#{f} free, #{r} kept free). Downloads are paused until space frees up."`)
- Modify: `lib/mydia/downloads/built_in/supervisor.ex` (child after `engine`)
- Test: `test/mydia/downloads/built_in/space_guard_test.exs`, `supervisor_test.exs`

**Interfaces:**
- Produces: `SpaceGuard.start_link(config: Config.t(), status: server, free_bytes: (String.t() -> {:ok, integer()} | {:error, term()}), client: {adapter, config_map} | nil, interval_ms: 60_000, name: ...)`; `SpaceGuard.check_now(server) :: :ok` for tests. The `:disk` status value is `:ok` or `{:low, %{free: String.t(), reserve: String.t()}}`, both formatted with `DiskSpace.format_gb/1`. `client` defaults to `ClientSelection.resolve_adapter(BuiltIn.name())` at each check.

- [ ] **Step 1: Failing tests** (stub adapter module recording pause/resume calls, `check_now/1`):
  - free below reserve: pauses only torrents with state `:downloading`, writes their hashes to `<state_dir>/space-paused`, `Status.get(...).disk == {:low, %{free: _, reserve: _}}`;
  - free between reserve and reserve + 1 GiB: no change either way;
  - free above reserve + 1 GiB: resumes exactly the recorded hashes, deletes the file, `disk == :ok`;
  - a recorded torrent found `:downloading` while low (user resumed it): dropped from the record, not paused again during this low period;
  - restart with the file present and room: resumes on first check;
  - `free_bytes` error: no pause, no resume, status unchanged, warning logged at most once per hour;
  - `min_free_space_bytes == 0`: never calls `free_bytes`;
  - `Status.blocking_reason/1` stays nil while `disk` is low.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** a GenServer with `Process.send_after(self(), :check, interval_ms)`; record file written with `File.write!/2` of newline-joined hashes; client errors logged and retried next tick.
- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/built_in` (PASS).
- [ ] **Step 5: Commit** `feat(downloads): pause the built-in client when the disk runs low`.

### Task 13: Banners, docs, PR 2 wrap-up

**Files:**
- Modify: `lib/mydia_web/live/admin_download_clients_live/built_in_components.ex` (alert `#built-in-low-disk` with `Status.describe/1` when `@status.disk` is `{:low, _}`)
- Modify: the downloads page LiveView under `lib/mydia_web/live/downloads_live/` (subscribe to `Status.topic()`, show the same alert `#downloads-low-disk`)
- Modify: `docs/using/download-clients.md` ("Disk space" subsection)
- Test: `test/mydia_web/live/admin_download_clients_live/built_in_test.exs`, the downloads LiveView test

- [ ] **Step 1: Failing tests:** broadcasting a status with `disk: {:low, %{free: "3.1 GB", reserve: "5 GB"}}` renders `#built-in-low-disk` and `#downloads-low-disk`; `disk: :ok` renders neither.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** with daisyUI `alert alert-warning` and `<.icon name="hero-exclamation-triangle">`; strings through `gettext`.
- [ ] **Step 4:** `./dev mix precommit` (PASS).
- [ ] **Step 5: Commit** `feat(admin): show when the built-in client is paused for disk space`.
