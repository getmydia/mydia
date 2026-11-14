# Built-in torrent: selective files, seeding targets, speed limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in (rqbit) torrents skip junk files automatically and accept a manual file selection; they stop seeding at an operator ratio or seed-time target by pausing or being removed; the engine honours download and upload caps.

**Architecture:** Five new `built_in_torrent` settings flow through `BuiltIn.Config` into the `Runtime` without restarting the engine. `SeedingGoal.goal_terms/2` merges the operator target into the tracker terms (max per dimension), and every reader of the goal uses it. A `BuiltIn.Policies` hook, called once per `DownloadMonitor` poll, runs `FileSelectionPolicy` and `SeedingPolicy` on built-in rows. File selection goes through two new optional adapter callbacks that only rqbit implements. Speed limits go through a new `BuiltIn.Limits` process in the instance tree.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, daisyUI 5, Ecto (SQLite + PostgreSQL), Req, Bypass, rqbit 9.0.1 HTTP API.

**Spec:** `design/specs/2026-11-14-builtin-torrent-file-selection-seeding-design.md`

## Global Constraints

- rqbit endpoints, exactly: `POST /torrents/{hash}/update_only_files` with JSON `{"only_files": [ints]}`; `GET /torrents/{hash}` `files[]` (`name`, `components`, `length`, `included`); `GET /torrents/{hash}/stats/v1` `file_progress[]`; `POST /torrents/limits` with `{"upload_bps": n | null, "download_bps": n | null}`, both keys always sent.
- Env vars: `MYDIA_TORRENT_SEED_RATIO`, `MYDIA_TORRENT_SEED_TIME`, `MYDIA_TORRENT_SEED_GOAL_ACTION`, `MYDIA_TORRENT_DOWNLOAD_LIMIT`, `MYDIA_TORRENT_UPLOAD_LIMIT`.
- Units: `seed_time` in minutes in settings, seconds everywhere downstream (`TrackerTerms.minimum_seed_time`). Speed limits in KiB/s in settings, `* 1024` bytes/s to rqbit. 0 or blank speed = unlimited (`null`).
- `seed_ratio = 0` is a valid target (stop seeding at completion). Blank is "no target". Both targets blank = no change to today's behaviour.
- `seed_goal_action` is `"pause"` (default) or `"remove"`.
- Metadata keys: `"seeding_goal_reached_at"` (ISO 8601 string), `"file_selection"` (`%{"source" => "auto" | "manual" | "auto_failed" | "auto_pending", ...}`).
- Subtitle extensions kept by auto-selection: `.srt .ass .ssa .sub .idx .sup .vtt`.
- None of the new settings may change `BuiltIn.Config.restart_key/1`.
- No em dashes in code comments, docs or UI copy. All UI strings through `gettext`. Never real movie or TV titles in tests; invent them.
- Tests that touch `BuiltIn.put_runtime/1` (a `:persistent_term`) are `async: false` and clear it in `on_exit`.
- Commit with `devenv shell -- git commit -F <msgfile>` after staging every path; verify with `git show --stat`.

## Review Focus

1. **A seeding target set with a private tracker whose terms are unknown.** The goal stays unmet, so the torrent is never paused or removed. Test in Task 2.
2. **The operator resumes a torrent Mydia paused.** It keeps seeding and is not paused again. Test in Task 3.
3. **The engine is stopped or unreachable during a poll.** Policies write no stamp, log, and the poll carries on for other rows. Tests in Tasks 3 and 6.
4. **The seeding target changes in settings while the engine runs.** The next poll uses the new target and the engine is not restarted. Test in Task 1.
5. **A season pack with dozens of episodes plus a `Sample/` folder.** Every episode and subtitle is kept, and only the samples and junk are skipped. Test in Task 5.

---

### Task 1: Settings fields, config plumbing, runtime refresh

**Files:**
- Modify: `lib/mydia/config/schema/built_in_torrent.ex`
- Modify: `lib/mydia/config/env/built_in_torrent_env.ex`
- Modify: `lib/mydia/downloads/built_in/settings.ex`
- Modify: `lib/mydia/downloads/built_in/config.ex` (struct, `from_runtime/4`, `restart_key/1`)
- Modify: `lib/mydia/downloads/built_in/manager.ex` (`apply_config/1`)
- Modify: `lib/mydia/downloads/built_in.ex` (`client_configs/0`, new `seeding_target/0`)
- Test: `test/mydia/config/env/built_in_torrent_env_test.exs` (create if absent), `test/mydia/downloads/built_in/settings_test.exs`, `test/mydia/downloads/built_in/config_test.exs`, `test/mydia/downloads/built_in/manager_test.exs`, `test/mydia/downloads/built_in_test.exs`

**Interfaces:**
- Produces: schema fields `seed_ratio :float`, `seed_time :integer` (minutes), `seed_goal_action :string` (default `"pause"`), `download_limit :integer`, `upload_limit :integer`.
- Produces: `%BuiltIn.Config{}` fields `seed_ratio: float | nil`, `seed_time: non_neg_integer | nil` (minutes), `seed_goal_action: :pause | :remove`, `download_limit: non_neg_integer | nil`, `upload_limit: non_neg_integer | nil`.
- Produces: `BuiltIn.seeding_target() :: %{ratio: float | nil, seed_time: non_neg_integer | nil, action: :pause | :remove} | nil`. `seed_time` is in seconds. Nil when there is no runtime or both targets are nil.
- Produces: `BuiltIn.client_configs/0` sets `remove_completed: true` only when `seeding_target()` is non-nil and its action is `:remove`.

- [ ] **Step 1: Write failing tests**

```elixir
# built_in_torrent_env_test.exs
test "reads seeding and limit variables" do
  env = %{"MYDIA_TORRENT_SEED_RATIO" => "1.5", "MYDIA_TORRENT_SEED_TIME" => "4320",
          "MYDIA_TORRENT_SEED_GOAL_ACTION" => "Remove", "MYDIA_TORRENT_DOWNLOAD_LIMIT" => "0",
          "MYDIA_TORRENT_UPLOAD_LIMIT" => "512"}
  assert %{seed_ratio: 1.5, seed_time: 4320, seed_goal_action: "remove",
           download_limit: 0, upload_limit: 512} = BuiltInTorrentEnv.load(&env[&1])
end

test "drops unparseable or out-of-range values" do
  env = %{"MYDIA_TORRENT_SEED_RATIO" => "-1", "MYDIA_TORRENT_SEED_TIME" => "abc",
          "MYDIA_TORRENT_SEED_GOAL_ACTION" => "delete"}
  loaded = BuiltInTorrentEnv.load(&env[&1])
  refute Map.has_key?(loaded, :seed_ratio)
  refute Map.has_key?(loaded, :seed_time)
  refute Map.has_key?(loaded, :seed_goal_action)
end

# settings_test.exs
test "saves and casts back seeding fields" do
  assert :ok = Settings.save(%{"seed_ratio" => "2.0", "seed_time" => "60",
                               "seed_goal_action" => "remove", "upload_limit" => "256"}, opts)
  # assert the stored rows are "2.0", "60", "remove", "256" and the reloaded section casts them back
end

test "rejects a negative ratio and an unknown action" do
  cs = Settings.form_changeset(%{"seed_ratio" => "-0.5", "seed_goal_action" => "delete"}, section)
  assert %{seed_ratio: [_], seed_goal_action: [_]} = errors_on(cs)
end

test "env-set seeding fields are read-only" # MYDIA_TORRENT_SEED_RATIO set: a submitted value is ignored

# config_test.exs
test "seeding and limit fields do not change restart_key" do
  base = Config.from_runtime(%BuiltInTorrent{}, %{}, [])
  changed = Config.from_runtime(%BuiltInTorrent{seed_ratio: 2.0, seed_time: 60,
              seed_goal_action: "remove", download_limit: 100, upload_limit: 50}, %{}, [])
  assert Config.restart_key(base) == Config.restart_key(changed)
  assert changed.seed_goal_action == :remove
end

# manager_test.exs (Review Focus 4)
test "a seeding-only reload refreshes the runtime without restarting the engine"
# Start the manager as the existing tests do, record the instance pid, change seed_ratio
# in the runtime config and broadcast a reload. Assert the same instance pid is still running
# and BuiltIn.runtime().config.seed_ratio == the new value.

# built_in_test.exs
test "seeding_target/0 converts minutes to seconds and is nil with no targets"
# put_runtime with config seed_ratio: nil, seed_time: 90 -> %{ratio: nil, seed_time: 5400, action: :pause}
# put_runtime with both nil -> nil; seed_ratio: 0.0 -> %{ratio: 0.0, ...} (0 is a target)

test "client_configs/0 sets remove_completed only for a remove target"
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `./dev mix test test/mydia/config/env/built_in_torrent_env_test.exs test/mydia/downloads/built_in/settings_test.exs test/mydia/downloads/built_in/config_test.exs test/mydia/downloads/built_in/manager_test.exs test/mydia/downloads/built_in_test.exs`
Expected: FAIL (unknown fields, undefined `seeding_target/0`).

- [ ] **Step 3: Implement**

- Schema: add the five fields and their `@env_vars` entries. In `changeset/2`: `validate_number` >= 0 for the four numeric fields, and `validate_inclusion(:seed_goal_action, ~w(pause remove))`.
- Env: a float clause for `:seed_ratio` (`Float.parse`, >= 0). A non-negative integer clause for `:seed_time`, `:download_limit` and `:upload_limit`, separate from the 1..65535 port fields. `:seed_goal_action` is downcased and kept only when in `~w(pause remove)`.
- Settings: add `@floats [:seed_ratio]` (type `:float`), add the three integer fields to `@integers`, add `:seed_goal_action` to the choice validation, add an `encode/2` clause for floats (`Float.to_string/1`), and `validate_number` >= 0 for the numeric fields. Keep the new fields out of `@text_fields`.
- Config: add the five struct fields, filled in `from_runtime/4` (`seed_goal_action` as an atom, default `:pause`). `restart_key/1` drops them at the top level and drops the same five keys from `vpn_section`, whatever the VPN state.
- Manager: in `apply_config/1`, on the `unchanged?` branch, when `BuiltIn.runtime()` is non-nil, call `BuiltIn.put_runtime(%{runtime | config: config})` and set `state.current` to `config`. Task 7 hooks the limits push onto this branch.
- BuiltIn: `seeding_target/0` and `remove_completed` as specified in Interfaces.

- [ ] **Step 4: Run the tests and confirm they pass** (same command)

- [ ] **Step 5: Commit**: `feat(built-in): seeding target and speed limit settings`

---

### Task 2: Effective seeding goal

**Files:**
- Modify: `lib/mydia/downloads/seeding_goal.ex`
- Modify: `lib/mydia/downloads/client_removal.ex` (`terms_met?/2`, `remove_when_ready/3`)
- Modify: `lib/mydia/downloads/observed_seed_time.ex` (`tracked?/1`)
- Test: `test/mydia/downloads/seeding_goal_test.exs`, `test/mydia/downloads/client_removal_test.exs`, `test/mydia/downloads/observed_seed_time_test.exs`

**Interfaces:**
- Consumes: `BuiltIn.seeding_target/0`, `BuiltIn.name/0`.
- Produces: `SeedingGoal.effective_terms(TrackerTerms.t() | nil, %{ratio: float | nil, seed_time: non_neg_integer | nil} | nil) :: TrackerTerms.t() | nil`. `seed_time` is in seconds here. The target's `:action` key is ignored.
- Produces: `SeedingGoal.goal_terms(download :: map(), opts :: keyword()) :: TrackerTerms.t() | nil`. Equals `effective_terms(terms(download), target)`, where `target` is `opts[:target]` when given, else `BuiltIn.seeding_target()` when `download.download_client == BuiltIn.name()`, else nil.
- Changed: `for_download/2`, `ClientRemoval.terms_met?/2`, the `guarded?` check in `remove_when_ready/3`, and `ObservedSeedTime.tracked?/1` all call `goal_terms/1` instead of `terms/1`. `for_download/2` accepts `opts` (`:target`, `:now`) and keeps its `(download, now)` arity working for existing callers.

- [ ] **Step 1: Write failing tests**

```elixir
describe "effective_terms/2" do
  test "operator target alone" do
    assert %TrackerTerms{minimum_ratio: 1.0, minimum_seed_time: 3600} =
             SeedingGoal.effective_terms(nil, %{ratio: 1.0, seed_time: 3600})
  end

  test "max per dimension, private carried" do
    tracker = %TrackerTerms{private?: true, minimum_ratio: 2.0, minimum_seed_time: 600}
    assert %TrackerTerms{private?: true, minimum_ratio: 2.0, minimum_seed_time: 3600} =
             SeedingGoal.effective_terms(tracker, %{ratio: 1.0, seed_time: 3600})
  end

  test "nil target returns the tracker terms unchanged"
  test "ratio 0.0 is a real target", do: assert SeedingGoal.met?(SeedingGoal.effective_terms(nil, %{ratio: 0.0, seed_time: nil}), 0.0, 0)

  # Review Focus 1
  test "private tracker with unknown terms stays unmet under an operator target" do
    terms = SeedingGoal.effective_terms(%TrackerTerms{private?: true}, %{ratio: nil, seed_time: nil})
    refute SeedingGoal.met?(terms, 50.0, 10_000_000)
  end
end

describe "goal_terms/2" do
  test "applies the target only to the built-in client"
  # download_client: "Built-in" with target: %{ratio: 1.0, seed_time: nil} -> minimum_ratio 1.0
  # download_client: "qBit" with the same target -> terms(download) unchanged
end

# client_removal_test.exs, in "seeding guard"
test "the operator target guards built-in removal"
# rqbit client named BuiltIn.name(), remove_completed: true, no tracker terms, runtime target ratio 1.0:
# ratio 0.4 -> :still_seeding; ratio 1.2 -> :removed. Needs a runtime: async: false + put_runtime.

# observed_seed_time_test.exs
test "tracks a built-in row with only an operator target"
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `./dev mix test test/mydia/downloads/seeding_goal_test.exs test/mydia/downloads/client_removal_test.exs test/mydia/downloads/observed_seed_time_test.exs`

- [ ] **Step 3: Implement** the two functions and switch the four call sites. `effective_terms/2` builds a `TrackerTerms` when the tracker terms are nil, and returns nil only when both inputs set nothing.

- [ ] **Step 4: Run the tests and confirm they pass**, plus `./dev mix test test/mydia_web/components` (SeedingComponents callers).

- [ ] **Step 5: Commit**: `feat(seeding): merge the built-in seeding target into the goal`

---

### Task 3: Metadata stamp helper, SeedingPolicy, monitor hook

**Files:**
- Create: `lib/mydia/downloads/metadata_key.ex`
- Create: `lib/mydia/downloads/built_in/policies.ex`
- Create: `lib/mydia/downloads/built_in/seeding_policy.ex`
- Modify: `lib/mydia/jobs/download_monitor.ex` (one call after `ObservedSeedTime.record/2`)
- Test: `test/mydia/downloads/metadata_key_test.exs`, `test/mydia/downloads/built_in/seeding_policy_test.exs`

**Interfaces:**
- Consumes: `SeedingGoal.for_download/2` (Task 2), `BuiltIn.seeding_target/0` (Task 1), `Queue.resolve_adapter/1`, `Client.pause_torrent/3`.
- Produces: `MetadataKey.put(download_id :: binary(), key :: String.t(), value :: term()) :: :ok | {:error, term()}`. It reads, merges and writes `metadata` in one transaction, row-locked on PostgreSQL (copy `ObservedSeedTime.write/3`'s pattern), with `Repo.update_all` so no Downloads broadcast fires. Returns `:ok` for a missing row.
- Produces: `BuiltIn.Policies.run(rows :: [EnrichedDownload.t()], now :: DateTime.t()) :: :ok`. It filters to `row.download_client == BuiltIn.name()` and runs each policy per row inside a rescue that logs and continues. In this task it calls only `SeedingPolicy.apply/2`; Task 6 adds the file selection pass before it.
- Produces: `SeedingPolicy.apply(row :: EnrichedDownload.t(), now :: DateTime.t()) :: :paused | :left_to_removal | :noop | {:error, term()}`.

**Rule (from the spec):** act only when `BuiltIn.seeding_target()` is non-nil, `SeedingGoal.currently_seeding?(row)` holds, `row.metadata["seeding_goal_reached_at"]` is absent, and `SeedingGoal.for_download(row, now: now)` is `%{met?: true}`. Then:
- If the action is `:remove` and `row.imported_at` is set, return `:left_to_removal` with no call.
- Otherwise call `pause_torrent`. On `:ok`, stamp `"seeding_goal_reached_at"` with `DateTime.to_iso8601(now)` and return `:paused`.

A failed pause returns `{:error, reason}` with no stamp.

- [ ] **Step 1: Write failing tests** (a `StubAdapter`-style rqbit config or Bypass, plus `put_runtime`, `async: false`)

```elixir
test "MetadataKey.put merges without dropping other keys" # metadata %{"tracker_terms" => ...} keeps it
test "pauses a seeding row whose goal is met and stamps it" # ratio 1.2 vs target 1.0 -> :paused, stamp present, pause called once
test "does nothing below the goal" # ratio 0.5 -> :noop, no call
test "never pauses a stamped row again" # Review Focus 2: stamped + seeding + met -> :noop
test "remove mode leaves imported rows to removal" # imported_at set -> :left_to_removal, no pause call
test "remove mode pauses an unimported row" # imported_at nil -> :paused
test "no target means no action" # seeding_target nil, tracker terms met -> :noop
test "a failed pause leaves no stamp" # Review Focus 3: adapter returns {:error, connection_failed} -> {:error, _}, no stamp
test "Policies.run skips other clients and survives a raising row"
```

- [ ] **Step 2: Run them and confirm they fail**: `./dev mix test test/mydia/downloads/metadata_key_test.exs test/mydia/downloads/built_in/seeding_policy_test.exs`
- [ ] **Step 3: Implement** the three modules, and in `DownloadMonitor.perform/1` add `Mydia.Downloads.BuiltIn.Policies.run(downloads, now)` right after `ObservedSeedTime.record(downloads, now)`.
- [ ] **Step 4: Run the tests and confirm they pass**, plus `./dev mix test test/mydia/jobs/download_monitor_test.exs test/mydia/jobs/download_monitor_client_removal_test.exs`
- [ ] **Step 5: Commit**: `feat(built-in): pause or hand off torrents at the seeding target`

---

### Task 4: rqbit file and limit endpoints behind adapter callbacks

**Files:**
- Create: `lib/mydia/downloads/structs/torrent_file.ex`
- Modify: `lib/mydia/downloads/client.ex` (callbacks, `@optional_callbacks`, wrappers)
- Modify: `lib/mydia/downloads/client/rqbit.ex`
- Test: `test/mydia/downloads/client/rqbit_test.exs`, `test/mydia/downloads/client/list_files_test.exs` (wrapper `:unsupported` case)

**Interfaces:**
- Produces: `%TorrentFile{index: non_neg_integer, path: String.t(), size: non_neg_integer, included?: boolean, downloaded: non_neg_integer}`. `path` is relative: `name`, else `Path.join(components)`.
- Produces callbacks: `torrent_files(config, client_id) :: {:ok, [TorrentFile.t()]} | {:error, Error.t()}` and `set_file_selection(config, client_id, [non_neg_integer]) :: :ok | {:error, Error.t()}`. Both are added to `@optional_callbacks`.
- Produces wrappers: `Client.torrent_files/3`, `Client.set_file_selection/4`, and `Client.supports_file_selection?(adapter) :: boolean`. They follow the `set_share_limits/4` shape (nil adapter clause, `{:error, :unsupported}`).
- Produces: `Rqbit.set_session_limits(config, %{download_bps: pos_integer | nil, upload_bps: pos_integer | nil}) :: :ok | {:error, Error.t()}`. This is a public function, not a callback.

- [ ] **Step 1: Write failing Bypass tests**

```elixir
test "torrent_files joins details and file_progress by index" do
  # GET /torrents/#{@hash} -> files: [%{"name" => "Show.S01E01.mkv", "length" => 100, "included" => true},
  #                                   %{"name" => "Sample/s.mkv", "length" => 10, "included" => false}]
  # GET /torrents/#{@hash}/stats/v1 -> %{"file_progress" => [40, 0]}
  assert {:ok, [%TorrentFile{index: 0, path: "Show.S01E01.mkv", size: 100, included?: true, downloaded: 40},
                %TorrentFile{index: 1, included?: false, downloaded: 0}]} = Rqbit.torrent_files(config, @hash)
end

test "set_file_selection posts the index list as JSON" do
  # assert conn path /torrents/#{@hash}/update_only_files and Jason body == %{"only_files" => [0, 2]}
end

test "set_file_selection maps a 404 to not_found"

test "set_session_limits always sends both keys, null for unlimited" do
  # body == %{"download_bps" => nil, "upload_bps" => 524_288}
end

test "Client.torrent_files returns :unsupported for an adapter without it" # e.g. Transmission
```

- [ ] **Step 2: Run them and confirm they fail**: `./dev mix test test/mydia/downloads/client/rqbit_test.exs test/mydia/downloads/client/list_files_test.exs`
- [ ] **Step 3: Implement.** Reuse `fetch_details/2`, `fetch_stats/2`, `api_error_from/1` and `guarded/2`. Post JSON with `HTTP.post(req, path, json: ...)`, checking `Mydia.Downloads.Client.HTTP` for the exact option it forwards to Req.
- [ ] **Step 4: Run the tests and confirm they pass**
- [ ] **Step 5: Commit**: `feat(rqbit): file selection and session speed limit endpoints`

---

### Task 5: FileSelection rules

**Files:**
- Create: `lib/mydia/downloads/file_selection.ex`
- Test: `test/mydia/downloads/file_selection_test.exs` (`async: true`)

**Interfaces:**
- Consumes: `%TorrentFile{}` (Task 4), `ImportCandidates.importable?/2`, `SampleDetector.detect/1`, `SampleDetector.excluded?/1`.
- Produces: `FileSelection.importable?(path :: String.t()) :: boolean`, meaning `ImportCandidates.importable?(%{name: Path.basename(path)}, :series)` and not `SampleDetector.excluded?(SampleDetector.detect(path))`.
- Produces: `FileSelection.subtitle?(path) :: boolean`, using the Global Constraints extension list, case-insensitive.
- Produces: `FileSelection.keep([TorrentFile.t()]) :: [non_neg_integer]`, the sorted indices of files that are `importable?` or `subtitle?`. When that set is empty it returns every index.

- [ ] **Step 1: Write failing tests** with invented titles

```elixir
test "season pack keeps every episode and subtitle, skips samples and junk" do # Review Focus 5
  files = for(n <- 1..24, do: "Glass Harbor S02/Glass.Harbor.S02E#{pad(n)}.mkv") ++
          ["Glass Harbor S02/Sample/sample.mkv", "Glass Harbor S02/Glass.Harbor.S02E01.en.srt",
           "Glass Harbor S02/release.nfo", "Glass Harbor S02/cover.jpg"]
  kept = FileSelection.keep(to_files(files))
  assert length(kept) == 25
  refute index_of(files, "Glass Harbor S02/Sample/sample.mkv") in kept
end

test "trailer and .exe are skipped"
test "subtitle detection is case-insensitive" # .SRT, .Idx
test "all-junk torrent keeps every index" # ["setup.exe", "readme.txt"] -> [0, 1]
```

- [ ] **Step 2: Run it and confirm it fails**: `./dev mix test test/mydia/downloads/file_selection_test.exs`
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run it and confirm it passes**
- [ ] **Step 5: Commit**: `feat(downloads): rules for skipping non-media torrent files`

---

### Task 6: Automatic file selection policy

**Files:**
- Create: `lib/mydia/downloads/built_in/file_selection_policy.ex`
- Modify: `lib/mydia/downloads/built_in/policies.ex` (run it before `SeedingPolicy`)
- Test: `test/mydia/downloads/built_in/file_selection_policy_test.exs`

**Interfaces:**
- Consumes: `Client.torrent_files/3`, `Client.set_file_selection/4` (Task 4), `FileSelection.keep/1` (Task 5), `MetadataKey.put/3` (Task 3), `Queue.resolve_adapter/1`.
- Produces: `FileSelectionPolicy.apply(row :: EnrichedDownload.t()) :: :applied | :nothing_to_skip | :waiting | :done | {:error, term()}`.

**Rule:**
- `:done` when `row.metadata["file_selection"]["source"]` is in `~w(auto manual auto_failed)`.
- `:waiting` when `row.status` is `"checking"`, or `torrent_files` returns `{:ok, []}`.
- Otherwise compute `keep/1`. When it equals every index, stamp `%{"source" => "auto", "skipped" => 0}` and return `:nothing_to_skip`. When it doesn't, call `set_file_selection`; on `:ok`, stamp `%{"source" => "auto", "skipped" => n}` and return `:applied`.
- On any error, stamp `%{"source" => "auto_pending", "attempts" => n}`. At the third failure, stamp `%{"source" => "auto_failed", "attempts" => 3}` instead. Return `{:error, reason}`.
- Imported rows (`imported_at` set) are `:done` without a call.

- [ ] **Step 1: Write failing tests**

```elixir
test "waits while the file list is empty (magnet without metadata)"
test "skips junk once and stamps auto with the count"
test "stamps nothing_to_skip without calling set_file_selection"
test "never overrides a manual selection" # source manual -> :done, no calls
test "gives up after three failures" # Review Focus 3: three polls of {:error, _} -> auto_failed, fourth poll :done
```

- [ ] **Step 2: Run it and confirm it fails**: `./dev mix test test/mydia/downloads/built_in/file_selection_policy_test.exs`
- [ ] **Step 3: Implement** and wire it into `Policies.run/2` ahead of `SeedingPolicy.apply/2` for rows not yet seeding.
- [ ] **Step 4: Run it and confirm it passes**, plus `./dev mix test test/mydia/downloads/built_in/seeding_policy_test.exs test/mydia/jobs/download_monitor_test.exs`
- [ ] **Step 5: Commit**: `feat(built-in): skip junk files once a torrent's file list is known`

---

### Task 7: Speed limits pushed to the engine

**Files:**
- Create: `lib/mydia/downloads/built_in/limits.ex`
- Modify: `lib/mydia/downloads/built_in/supervisor.ex` (add `{Limits, config: config}` after `engine` in `base`)
- Modify: `lib/mydia/downloads/built_in/status.ex` (`describe/1` clause for `{:limits_failed, message}`)
- Modify: `lib/mydia/downloads/built_in/manager.ex` (call `Limits.push/1` on the Task 1 refresh branch when the limits changed)
- Test: `test/mydia/downloads/built_in/limits_test.exs`, `test/mydia/downloads/built_in/supervisor_test.exs`, `test/mydia/downloads/built_in/manager_test.exs`

**Interfaces:**
- Consumes: `Rqbit.set_session_limits/2` (Task 4), `Queue.resolve_adapter/1`, `Status.put/3`, `Status.topic/0`.
- Produces: `BuiltIn.Limits`, a GenServer with default name `__MODULE__`, started with `config: %Config{}`. On init it subscribes to `Status.topic/0`. On each `{:built_in_status, %Status{engine: :running}}` that follows a non-running state, it pushes its config's limits.
- Produces: `Limits.push(server \\ __MODULE__, %Config{}) :: :ok` (cast). It stores the config and pushes. A push converts KiB/s to bytes/s, with 0 or nil becoming nil.
- On failure it adds `{:limits_failed, message}` to `Status.warnings`, replacing any previous one. On success it removes it.
- Copy for `Status.describe({:limits_failed, message})`: `"Could not apply the speed limits: #{message}"`.

- [ ] **Step 1: Write failing tests** (Bypass standing in for rqbit, a test Status with its own topic)

```elixir
test "pushes limits when the engine becomes running" # body %{"download_bps" => 102_400, "upload_bps" => nil}
test "does not push again on a running -> running status change"
test "push/2 sends new limits immediately"
test "a failed push records a warning and a later success clears it"
test "supervisor children include Limits after Engine" # supervisor_test
test "a limits-only reload pushes without restarting the instance" # manager_test
```

- [ ] **Step 2: Run them and confirm they fail**: `./dev mix test test/mydia/downloads/built_in/limits_test.exs test/mydia/downloads/built_in/supervisor_test.exs test/mydia/downloads/built_in/manager_test.exs`
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run them and confirm they pass**
- [ ] **Step 5: Commit**: `feat(built-in): apply download and upload speed limits`

---

### Task 8: Settings modal fields

**Files:**
- Create: `lib/mydia_web/live/admin_download_clients_live/built_in_seeding_components.ex` (`built_in_form_components.ex` is already over 500 lines)
- Modify: `lib/mydia_web/live/admin_download_clients_live/built_in_form_components.ex` (render `<.seeding_fields ...>` after the ports group)
- Test: `test/mydia_web/live/admin_download_clients_live/built_in_settings_test.exs`

**Interfaces:**
- Consumes: the existing `field_row/1`, `text_field/1` and `choice/1` from `BuiltInFieldComponents`, the `sources` map, and the form assign the modal already uses.
- Produces: `seeding_fields(assigns)`, with attrs `form` and `sources`. It renders a "Seeding" group (`seed_ratio`, `seed_time` labelled in minutes, `seed_goal_action` as a pause/remove choice) and a "Speed limits" group (`download_limit` and `upload_limit` in KiB/s, hint "0 or blank for unlimited"). DOM ids are `built-in-seed-ratio`, `built-in-seed-time`, `built-in-seed-goal-action`, `built-in-download-limit` and `built-in-upload-limit`. Env-locked fields show the existing ENV badge through `field_row/1`.

- [ ] **Step 1: Write failing LiveView tests**: the fields render; submitting `seed_ratio=1.5` and `seed_goal_action=remove` saves (assert the `config_settings` rows); `seed_ratio=-1` shows an error; with `MYDIA_TORRENT_UPLOAD_LIMIT` set, the field is disabled. Use the existing getenv injection in that test file.
- [ ] **Step 2: Run it and confirm it fails**: `./dev mix test test/mydia_web/live/admin_download_clients_live/built_in_settings_test.exs`
- [ ] **Step 3: Implement**, wrapping every label and hint in `gettext`.
- [ ] **Step 4: Run it and confirm it passes**, then `./dev mix gettext.extract --merge` and check the catalog per `lib/mydia_web/gettext/README.md`.
- [ ] **Step 5: Commit**: `feat(admin): seeding target and speed limit fields for the built-in client`

---

### Task 9: Files panel in the Downloads drawer

**Files:**
- Create: `lib/mydia/downloads/torrent_files.ex` (context)
- Create: `lib/mydia_web/live/downloads_live/files_panel.ex` (LiveComponent: it handles its own events)
- Modify: `lib/mydia_web/live/downloads_live/detail_drawer.ex` (render the panel after `download-detail-client`)
- Test: `test/mydia/downloads/torrent_files_test.exs`, `test/mydia_web/live/downloads_live/files_panel_test.exs`

**Interfaces:**
- Consumes: `Client.supports_file_selection?/1`, `Client.torrent_files/3`, `Client.set_file_selection/4` (Task 4), `FileSelection.importable?/1` (Task 5), `MetadataKey.put/3` (Task 3), `Queue.resolve_adapter/1`.
- Produces: `TorrentFiles.supported?(download) :: boolean`, true when the download's adapter supports selection and the download has a `download_client_id`.
- Produces: `TorrentFiles.list(download) :: {:ok, [TorrentFile.t()]} | {:error, term()}`.
- Produces: `TorrentFiles.editable?(download) :: boolean`, meaning `is_nil(download.imported_at)`.
- Produces: `TorrentFiles.save(download, [non_neg_integer]) :: :ok | {:error, :imported | :no_importable_file | term()}`. It refuses when imported, and refuses when no selected index is a file that is `importable?` (it re-lists the files to check). Otherwise it calls the adapter and on `:ok` stamps `"file_selection" => %{"source" => "manual"}`.
- Produces: `FilesPanel` with id `download-files-panel`. It loads the list in `update/2` only when `TorrentFiles.supported?/1`, and renders nothing otherwise. The form is `download-files-form` with one checkbox per file, `name="files[]" value={index}`, plus size (existing `Format` helpers) and progress. The save button is `download-files-save`. The inline error copy is `gettext("Keep at least one video file.")`. When not editable, the checkboxes are disabled and the button hidden. A failed save puts a flash error and reloads the list.

- [ ] **Step 1: Write failing tests**

```elixir
# torrent_files_test.exs (StubAdapter or Bypass rqbit)
test "save stamps manual and calls the adapter with the indices"
test "save refuses a selection with no importable file" # only the .srt -> {:error, :no_importable_file}, no call
test "save refuses after import" # imported_at set -> {:error, :imported}

# files_panel_test.exs (Downloads LiveView, built-in download row, drawer opened)
test "lists files with checkboxes", do: assert has_element?(view, "#download-files-form input[type=checkbox]")
test "saving submits the selection" # render_submit on #download-files-form with files: ["0"]
test "shows the inline error when no video file is kept"
test "is read-only after import" # checkboxes disabled, no #download-files-save
test "is absent for a client without file selection" # refute has_element?(view, "#download-files-panel")
```

- [ ] **Step 2: Run them and confirm they fail**: `./dev mix test test/mydia/downloads/torrent_files_test.exs test/mydia_web/live/downloads_live/files_panel_test.exs`
- [ ] **Step 3: Implement**, with daisyUI `checkbox checkbox-sm` and `progress` and every string in `gettext`. Then run `./dev mix gettext.extract --merge`.
- [ ] **Step 4: Run them and confirm they pass**
- [ ] **Step 5: Commit**: `feat(downloads): choose which files a built-in torrent downloads`

---

### Task 10: Docs and full verification

**Files:**
- Modify: `lib/mydia/downloads/README.md` ("Seeding guard and share limits": the operator target, `goal_terms/2`, pause/remove, the stamp; "Built-in client": file selection policy and stamps, speed limits, the five env vars)
- Modify: `docs/` page for built-in torrent env vars if one lists `MYDIA_TORRENT_*` (find it with `grep -rl MYDIA_TORRENT_PORT docs`)

- [ ] **Step 1: Update the docs.** No em dashes.
- [ ] **Step 2: Run `./dev mix precommit`** in foreground chunks if it nears the 600s cap (see `test/README.md`). Expected: format, credo, compile warnings and tests all clean.
- [ ] **Step 3: Check the diff against `origin/master`**: `git diff --stat origin/master...HEAD`. Every file should be one this plan names.
- [ ] **Step 4: Commit**: `docs(downloads): built-in seeding targets, file selection, speed limits`
