# Smart Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trash watched TV automatically after a grace period (Smart Space), and add a manual "Delete season files" action (#1537).

**Architecture:** A pure `Mydia.SmartSpace.Evaluator` turns rules, episodes, keeps and per-user watch records into a list of cleanups. A `Loader` builds its inputs from the database; a daily Oban job and a preview page both call Loader + Evaluator. Every removal goes through one new primitive, `Mydia.Library.trash_episode_files/2`, which the manual season dialog also uses.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Ecto (SQLite + PostgreSQL), Oban, daisyUI 5.

**Spec:** `design/specs/2026-11-27-smart-space-design.md`

## Global Constraints

- Migrations: `:text` never `:string`; a real timestamp filename; check every remote branch for version collisions (loop in `AGENTS.md`, "Migration filenames") before committing a migration.
- Portable SQL only; tests must pass on SQLite and the Postgres CI lane.
- The automation only ever trashes (`reason: :smart_space`), never permanently deletes.
- `smart_space.enabled` defaults to `false`; `unit` `"season"`; `grace_days` `7`; `watched_by` `"all_started"`; `selected_users` `[]`.
- Per-run cap: 200 files.
- Season 0 never eligible.
- No `String.to_atom/1` on input; enum env vars use a fixed-value parser mapping unknown strings to `:invalid`, never `Loader.parse_atom/1`.
- All user-facing strings through gettext. New interactive elements get stable DOM IDs.
- Fixtures use invented show titles only.
- No em dashes in copy, docs or comments.
- Run tests with `./dev mix test <path>`; commit with `direnv exec . git commit -F <msgfile>` after `git add` of every intended path; verify with `git show --stat`.

## Review Focus

1. **A selected user is deleted or renamed after being chosen.** Expect: rule resolves to `:misconfigured`, nothing is trashed, one warning event. Test in Task 6 (Loader) and Task 7 (job).
2. **An episode with no `air_date` under the season unit.** Expect: treated as unaired, so the season is not eligible. Test in Task 5.
3. **A season where some aired episodes have no live files** (deleted earlier by hand, never downloaded). Expect: those episodes do not need to be watched; the season is eligible once every episode *with files* is done, and the cleanup holds only the remaining files. Test in Task 5. (Spec clarification, applied in Task 11.)
4. **An episode with two files where one fails to trash.** Expect: the other file is trashed, the episode stays monitored, the next run retries the failed file. Test in Task 7.
5. **A season-pack download (`episode_id` nil, `media_item_id` set) in flight.** Expect: the whole show counts as in flight and nothing in it is cleaned up that run. Test in Task 6.

---

### Task 1: Episode file primitives and the `:smart_space` trash reason

**Files:**
- Modify: `lib/mydia/library/trash.ex` (add two functions)
- Modify: `lib/mydia/library.ex` (delegates, next to `trash_media_file` at line 48)
- Modify: `lib/mydia/library/media_file.ex:119-120` (add `:smart_space` to `trashed_reason` values and the `@type`)
- Modify: `lib/mydia_web/live/admin_trash_live/` reason label (find where `:manual` is labelled; add `:smart_space` => gettext("Smart Space"), plus a note that restoring does not re-monitor)
- Test: `test/mydia/library/trash_episode_files_test.exs`

**Interfaces:**
- Produces:
  - `Mydia.Library.trash_episode_files(episode_ids :: [binary()], opts :: keyword()) :: {:ok, %{trashed: [MediaFile.t()], failed: [{MediaFile.t(), term()}], bytes: non_neg_integer()}}` where `opts[:reason]` is passed to `trash_media_file/2`.
  - `Mydia.Library.delete_episode_files(episode_ids, delete_files: boolean()) :: {:ok, %{deleted: [MediaFile.t()], failed: [{MediaFile.t(), term()}], bytes: non_neg_integer()}}`. A `{:ok, file, :file_delete_failed}` result counts as `failed`.
  - Both act on every non-trashed media file whose `episode_id` is in the list (all versions), and never stop on one failure.

- [ ] **Step 1: Write failing tests** in `test/mydia/library/trash_episode_files_test.exs`:
  - `"trashes every live file on the episodes, including extra versions"`: two episodes in S1, one with two files; assert `length(trashed) == 3`, each reloaded row has `trashed_at` set and `trashed_reason == :smart_space`, `bytes` equals the sum of sizes.
  - `"leaves other seasons and episode rows untouched"`: S2 file still live; `Repo.get!(Episode, id)` still exists for S1 episodes.
  - `"skips already-trashed files"`.
  - `"reports a failure and keeps going"`: make one file's path unmovable (same technique as existing `trash_media_file` failure tests in `test/mydia/library/`); assert it is in `failed` and the other file is in `trashed`.
  - `delete_episode_files` with `delete_files: true` removes rows and bytes; with `false` removes rows and keeps bytes.
- [ ] **Step 2: Run** `./dev mix test test/mydia/library/trash_episode_files_test.exs`. Expected: FAIL, undefined function.
- [ ] **Step 3: Implement** both functions in `Mydia.Library.Trash` (one query for live files by `episode_id in ^ids` and `is_nil(trashed_at)`, then `Enum.reduce` over `trash_media_file/2` / `delete_media_file/2`), add delegates, add the enum value and trash-page label.
- [ ] **Step 4: Run** the test file and `./dev mix test test/mydia/library test/mydia_web/live/admin_trash_live`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(library): trash and delete all files on a set of episodes`.

### Task 2: "Delete season files" dialog (#1537)

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/modals.ex` (extract the radio group from `file_delete_confirm_modal/1` into `delete_mode_options/1`; add `season_delete_confirm_modal/1`)
- Modify: `lib/mydia_web/live/media_live/show/file_events.ex` (four handlers)
- Modify: `lib/mydia_web/live/media_live/show.ex` (route events; initial assigns `show_season_delete_confirm: false`, `season_delete: nil`)
- Modify: `lib/mydia_web/live/media_live/show.html.heex` (render the modal when `@show_season_delete_confirm`)
- Modify: `lib/mydia_web/live/media_live/show/season_components.ex` (button in the season action `join`, after subtitles)
- Test: `test/mydia_web/live/media_live/season_delete_files_test.exs`

**Interfaces:**
- Consumes: `Library.trash_episode_files/2`, `Library.delete_episode_files/2` (Task 1); `Mydia.Media.update_season_monitoring(media_item_id, season_number, false)`.
- Produces:
  - `Modals.delete_mode_options(assigns)` with attrs `mode :: :library_only | :trash | :permanent`, `form_id :: String.t()`, `change_event :: String.t()`; radio input name `file_delete_mode` with values `library_only | trash | permanent`.
  - `season_delete` assign: `%{season_number: integer, episode_ids: [binary], file_count: integer, bytes: integer, mode: atom, unmonitor: boolean}`.
  - Events: `show_season_delete_confirm` (`season-number`), `hide_season_delete_confirm`, `change_season_delete` (form params `file_delete_mode`, `unmonitor` "true"/"false"), `delete_season_files`.
  - DOM IDs: `season-N-delete-files` (button), `season-delete-modal`, `season-delete-form`, `season-delete-unmonitor`, `season-delete-confirm`.

- [ ] **Step 1: Write failing LiveView tests:**
  - `"button is hidden when the season has no files"` and `"hidden for a guest"`.
  - `"dialog shows file count and total size"`: S1 with 3 files of 1 GiB each; click `#season-1-delete-files`; assert `#season-delete-modal` text contains `"3 files"` and `format_file_size(3 * 1024**3)`.
  - `"trash is selected and unmonitor is checked by default"`: `has_element?(view, "#season-delete-form input[value=trash][checked]")`, `has_element?(view, "#season-delete-unmonitor[checked]")`.
  - `"confirming trashes the season and unmonitors it"`: click `#season-delete-confirm`; S1 files trashed with `trashed_reason == :manual`, S1 episodes `monitored == false`, S2 untouched.
  - `"unchecking unmonitor keeps the season monitored"`.
  - `"permanent mode deletes rows"`.
  - `"the per-file dialog still works"`: existing per-file test file still passes (run it in Step 4).
- [ ] **Step 2: Run** the new test file. Expected: FAIL.
- [ ] **Step 3: Implement.** Count and size come from the season's live files in `@media_item` (same source as `season_total_size/1` in `season_components.ex`). Handlers authorize with `Authorization.authorize_delete_media/1`. Trash mode passes `reason: :manual`. When the unmonitor box is checked, unmonitor the season after the file operation even if some files failed (the user asked for it and sees the failure count). Flash: `ngettext("Moved %{count} file to trash", "Moved %{count} files to trash", n)` and equivalents for the other modes, plus `ngettext("%{count} file could not be removed", ...)` as `:error` when `failed != []`. Reload `media_item` with `load_media_item/2` as `delete_media_file/2` does.
- [ ] **Step 4: Run** the new test plus `./dev mix test test/mydia_web/live/media_live`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(media): delete all files in a season from the season header (#1537)`.

### Task 3: `smart_space` config section

**Files:**
- Create: `lib/mydia/config/schema/smart_space.ex`
- Create: `lib/mydia/config/env/smart_space_env.ex`
- Modify: `lib/mydia/config/schema.ex` (`embeds_one :smart_space, Mydia.Config.Schema.SmartSpace, on_replace: :update` beside `:ui` at line 327; type at line 61; `cast_embed(:smart_space)` beside line 482; default at line 954)
- Modify: `lib/mydia/config/loader.ex:261` (`smart_space: Mydia.Config.Env.SmartSpaceEnv.load()`)
- Modify: config docs if a list of env vars exists (`grep -rn DEFAULT_UI_LANGUAGE docs/` and add the five vars beside it)
- Test: `test/mydia/config/smart_space_test.exs`

**Interfaces:**
- Produces: `%Mydia.Config.Schema.SmartSpace{enabled: boolean, unit: String.t(), grace_days: integer, watched_by: String.t(), selected_users: [String.t()]}`, read via `Mydia.Config.get().smart_space`. Fields are `:string` / `{:array, :string}` (validated with `validate_inclusion`), not `Ecto.Enum`, matching `minimum_availability`.
- Env vars: `SMART_SPACE_ENABLED` (boolean), `SMART_SPACE_UNIT`, `SMART_SPACE_GRACE_DAYS` (integer), `SMART_SPACE_WATCHED_BY`, `SMART_SPACE_SELECTED_USERS` (comma-separated, trimmed, empties dropped).
- DB overlay keys: `smart_space.enabled`, `smart_space.unit`, `smart_space.grace_days`, `smart_space.watched_by`, `smart_space.selected_users`.

- [ ] **Step 1: Write failing tests:**
  - defaults equal the Global Constraints values.
  - changeset rejects `unit: "show"`, `watched_by: "nobody"`, `grace_days: -1`, and `watched_by: "selected"` with `selected_users: []`.
  - `SmartSpaceEnv.load/0` with `SMART_SPACE_UNIT=Episode` gives `"episode"`; with `SMART_SPACE_UNIT=weekly` gives `:invalid` and the full config fails validation naming `smart_space.unit`; `SMART_SPACE_SELECTED_USERS=" alice, ,bob "` gives `["alice", "bob"]`. Set env with the helper `test/README.md` prescribes (tests must not leak global env).
  - `Paths.cast_overlay("smart_space.selected_users", ["a"])` succeeds.
- [ ] **Step 2: Run** `./dev mix test test/mydia/config/smart_space_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.** Username existence is NOT checked here (the schema must not query the Repo); Task 6 resolves names and Task 8 validates them on save.
- [ ] **Step 4: Run** the test file plus `./dev mix test test/mydia/config`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(config): smart_space section`.

### Task 4: Overrides and keeps tables

**Files:**
- Create: `priv/repo/migrations/<real timestamp>_create_smart_space_tables.exs`
- Create: `lib/mydia/smart_space/override.ex`, `lib/mydia/smart_space/keep.ex` (schemas)
- Create: `lib/mydia/smart_space/rules.ex` (context functions below)
- Test: `test/mydia/smart_space/rules_test.exs`

**Interfaces:**
- Tables per spec "Per-show override" and "Keeps". Unique index on `smart_space_overrides.media_item_id`. Keeps: partial-free uniqueness via three unique indexes is not portable, so enforce in `Rules.keep/2` (query first, inside a transaction) and add a unique index on `(media_item_id, season_number, episode_id)` for the non-null cases.
- Produces (`Mydia.SmartSpace.Rules`):
  - `get_override(media_item_id) :: Override.t() | nil`
  - `put_override(media_item_id, %{mode: "inherit" | "off" | "custom", unit: String.t() | nil, grace_days: integer | nil}) :: {:ok, Override.t()} | {:error, Ecto.Changeset.t()}`; `"inherit"` deletes the row and returns `{:ok, nil}`.
  - `keep(target, user_or_nil) :: {:ok, Keep.t()}` where `target :: {:show, media_item_id} | {:season, media_item_id, season_number} | {:episode, media_item_id, episode_id}`; idempotent.
  - `unkeep(target) :: :ok`
  - `list_keeps(opts) :: [Keep.t()]` preloading `:media_item` and `:episode`; `opts[:media_item_id]` narrows.
  - `list_overrides() :: [Override.t()]`

- [ ] **Step 1: Write failing tests:** override changeset requires `unit` and `grace_days` for `"custom"` and only allows TV items (`media_item.type == "tv_show"`; check the actual type string in `Mydia.Media.MediaItem`); `"inherit"` removes the row; `keep/2` twice returns the same row; a keep with both `season_number` and `episode_id` is rejected; deleting the media item cascades both tables (Review Focus is satisfied by the schema, assert it anyway).
- [ ] **Step 2: Run** `./dev mix test test/mydia/smart_space/rules_test.exs`. Expected: FAIL.
- [ ] **Step 3: Check migration version collisions** with the loop in Global Constraints, then implement migration, schemas and context.
- [ ] **Step 4: Run** the test file and `./dev mix test test/mydia/repo/migrations/no_varchar_columns_test.exs`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(smart-space): per-show overrides and keeps`.

### Task 5: The evaluator

**Files:**
- Create: `lib/mydia/smart_space/inputs.ex` and `lib/mydia/smart_space/inputs/{show,episode,watch,keep_ref}.ex` (one struct module per file; the project forbids nesting modules in one file)
- Create: `lib/mydia/smart_space/cleanup.ex`
- Create: `lib/mydia/smart_space/evaluator.ex`
- Test: `test/mydia/smart_space/evaluator_test.exs`

**Interfaces:**
- Produces:
  - `%Mydia.SmartSpace.Inputs{global: %{enabled: boolean, unit: String.t(), grace_days: integer, watched_by: String.t()}, selected_user_ids: [binary] | :misconfigured, shows: [Inputs.Show.t()]}`
  - `%Inputs.Show{media_item_id, title, override: nil | %{mode: String.t(), unit: String.t() | nil, grace_days: integer | nil}, episodes: [Inputs.Episode.t()], keeps: [Inputs.KeepRef.t()], watches: [Inputs.Watch.t()], in_flight_show?: boolean}`
  - `%Inputs.Episode{id, season_number, episode_number, air_date: Date.t() | nil, files: [{file_id, size}], in_flight?: boolean}`
  - `%Inputs.Watch{user_id, episode_id, watched: boolean, last_watched_at: DateTime.t() | nil}`
  - `%Inputs.KeepRef{level: :show | :season | :episode, season_number: integer | nil, episode_id: binary | nil}`
  - `%Mydia.SmartSpace.Cleanup{media_item_id, title, unit: :season | :episode, season_number, episode_ids: [binary], file_ids: [binary], bytes: integer, eligible_at: DateTime.t()}`
  - `Mydia.SmartSpace.Evaluator.eligible(Inputs.t(), now :: DateTime.t(), today :: Date.t()) :: [Cleanup.t()]`, sorted by `eligible_at` ascending. `today` decides "aired" (`air_date <= today`); passing it keeps the function clock-free.
  - `Mydia.SmartSpace.Evaluator.effective_rule(Inputs.t(), Inputs.Show.t()) :: nil | %{unit: String.t(), grace_days: integer}`
- Rules exactly as spec "Eligibility", with Review Focus 2 and 3 applied: an episode with `air_date == nil` is unaired; under the season unit only episodes with files must be done; a season with no files yields nothing.

- [ ] **Step 1: Write failing table-driven tests.** Build inputs with small helper functions in the test module. One `describe` per area, cases named after the condition:
  - policies: `all_started` (user B started but unfinished blocks; user C never started does not block; nobody started yields `[]`), `any` (one watcher suffices; `eligible_at` from the earliest watched record), `selected` (unstarted selected user blocks), `:misconfigured` yields `[]`.
  - units: season unit returns one cleanup with all file ids and summed bytes; episode unit returns one cleanup per done episode.
  - grace: `now == eligible_at` included; `now == eligible_at - 1s` excluded; a later `last_watched_at` (rewatch) moves `eligible_at`.
  - airing: season with an episode `air_date` tomorrow excluded under season unit, its aired done episodes included under episode unit; `air_date: nil` excluded under season unit.
  - files: aired episode without files not required to be watched (Review Focus 3); season with no files yields nothing.
  - exclusions: season 0; keep at show, season, episode level (an episode keep under the season unit blocks the whole season); `in_flight?` episode blocks its season (season unit) or itself (episode unit); `in_flight_show?` blocks everything in the show.
  - rules: override `"custom"` with global disabled applies; override `"off"` with global enabled skips; no override with global disabled skips.
- [ ] **Step 2: Run** `./dev mix test test/mydia/smart_space/evaluator_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.** No `Repo`, `Mydia.Config` or `DateTime.utc_now/0` calls in the module; `mix xref graph --source lib/mydia/smart_space/evaluator.ex` should show no Repo edge.
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat(smart-space): pure eligibility evaluator`.

### Task 6: The loader

**Files:**
- Create: `lib/mydia/smart_space/loader.ex`
- Test: `test/mydia/smart_space/loader_test.exs`

**Interfaces:**
- Consumes: Task 3 config, Task 4 tables, Task 5 structs; `Mydia.Downloads.Download.occupying/1`; `playback_progress` (`Mydia.Playback.Progress`: `user_id`, `episode_id`, `watched`, `last_watched_at`).
- Produces: `Mydia.SmartSpace.Loader.load(opts :: keyword()) :: Inputs.t()`. `opts[:media_item_id]` narrows to one show; `opts[:config]` overrides `Mydia.Config.get().smart_space` (for tests).
- Show selection: every TV item when the global rule is enabled (minus `"off"` overrides), otherwise only items with a `"custom"` override. Narrowed loads include the show regardless, so the show page can display its effective rule.
- `selected_user_ids`: resolve `selected_users` by username; any missing name gives `:misconfigured`. Only resolved when `watched_by == "selected"`, otherwise `[]`.
- In flight: `Download.occupying()` rows; `episode_id` set marks that episode; `episode_id` nil with `media_item_id` set marks `in_flight_show?`.
- Files: non-trashed `media_files` by `episode_id`, `{id, size}` (nil size counts as 0).
- Query count must not grow with show count: batch each table with `where ... in ^ids`.

- [ ] **Step 1: Write failing tests:** builds correct structs for two fictional shows; trashed files excluded; two versions of one episode both included; a deleted selected username gives `:misconfigured` (Review Focus 1); a season-pack download marks `in_flight_show?` (Review Focus 5); global disabled plus a `"custom"` override loads only that show; `media_item_id:` narrows.
- [ ] **Step 2: Run** `./dev mix test test/mydia/smart_space/loader_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat(smart-space): load evaluator inputs from the database`.

### Task 7: Context, job and cron

**Files:**
- Create: `lib/mydia/smart_space.ex`
- Create: `lib/mydia/jobs/smart_space_cleanup.ex`
- Modify: `config/config.exs:349` crontab (add `{"30 5 * * *", Mydia.Jobs.SmartSpaceCleanup}` after `TrashCleanup`)
- Test: `test/mydia/smart_space_test.exs`, `test/mydia/jobs/smart_space_cleanup_test.exs`

**Interfaces:**
- Consumes: Loader, Evaluator, `Library.trash_episode_files/2`, `Mydia.Media.Monitoring.set_episodes_monitored/2` (takes episode structs), `Mydia.Events.create_event/1`.
- Produces:
  - `Mydia.SmartSpace.upcoming(opts \\ []) :: [Cleanup.t()]`: `opts[:within_days]` default 30, `opts[:media_item_id]`; evaluates at `now + within_days`.
  - `Mydia.SmartSpace.run(opts \\ []) :: {:ok, %{cleanups: non_neg_integer, files: non_neg_integer, failed: non_neg_integer, bytes: non_neg_integer, capped?: boolean}} | {:error, :misconfigured}`; `opts[:now]`, `opts[:cap]` (default 200).
  - `Mydia.SmartSpace.last_run_at() :: DateTime.t() | nil` from the newest event of type `"smart_space.cleanup"` or `"smart_space.run"`.
  - Events: per cleanup `%{category: "media", type: "smart_space.cleanup", actor_type: :job, actor_id: "smart_space", resource_type: "media_item", resource_id: media_item_id, severity: :info, metadata: %{season_number, episode_count, file_count, bytes}}` (match `Event`'s actual metadata field name); one `"smart_space.run"` per run; misconfiguration `"smart_space.misconfigured"` with `severity: :warning`.
  - `Mydia.Jobs.SmartSpaceCleanup` (`use Oban.Worker, queue: <the queue TrashCleanup uses>, unique: [period: 3600]`), `perform/1` calls `SmartSpace.run/0`.
- Cap: take cleanups in `eligible_at` order while the running file total stays <= cap; a single cleanup larger than the cap is skipped and logged, never split.
- Unmonitor only episodes whose files all trashed.

- [ ] **Step 1: Write failing tests:**
  - `run/1` trashes eligible files with `trashed_reason == :smart_space`, sets `monitored: false` on their episodes, writes one `smart_space.cleanup` event per cleanup, returns the counts.
  - second `run/1` is a no-op (idempotent).
  - one failing file of two on an episode: other trashed, episode still monitored, `failed == 1` (Review Focus 4).
  - cap: with `cap: 3` and two 2-file seasons, only the first season is trashed and `capped? == true`.
  - disabled everywhere: `{:ok, %{cleanups: 0}}`, no files trashed, no events.
  - misconfigured: `{:error, :misconfigured}`, a warning event, no files trashed.
  - `upcoming/1` returns a season due in 5 days with `eligible_at` set, and `run/1` at the same moment trashes nothing.
  - job test: `perform_job(Mydia.Jobs.SmartSpaceCleanup, %{})` returns `:ok` (Oban runs in `:manual`/inline per `test/README.md`).
- [ ] **Step 2: Run** both test files. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both test files. Expected: PASS.
- [ ] **Step 5: Commit** `feat(smart-space): daily cleanup job`.

### Task 8: Settings card

**Files:**
- Create: `lib/mydia_web/live/admin_settings_live/smart_space_settings.ex` (modelled on `language_settings.ex`: `current/0`, env-var map, change-to-rows function)
- Create: `lib/mydia_web/live/admin_settings_live/smart_space_components.ex`
- Modify: `lib/mydia_web/live/admin_settings_live/index.ex`, `index.html.heex` (mount, events, render the card in the media section)
- Test: `test/mydia_web/live/admin_settings_live/smart_space_settings_test.exs`

**Interfaces:**
- Consumes: Task 3 keys and env var names.
- Produces: card `#smart-space-settings`; controls `#smart-space-enabled`, `#smart-space-unit`, `#smart-space-grace-days`, `#smart-space-watched-by`, user chips in `#smart-space-selected-users` (daisyUI `filter` of `<input type="checkbox" class="btn">`, one per user, value = username). Saving writes `smart_space.*` rows via the same `Settings` upsert path LanguageSettings uses, then reloads runtime config the same way.
- Save validation: `"selected"` with no users, or a username not in `Mydia.Accounts`, shows an inline error and writes nothing.

- [ ] **Step 1: Write failing tests:** card renders defaults; toggling enabled and setting grace 14 persists (`Mydia.Config.get().smart_space.grace_days == 14` after save); `"selected"` with no user shows an error; a key set by env shows the ENV badge and the control is disabled.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file plus `./dev mix test test/mydia_web/live/admin_settings_live`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(settings): Smart Space settings card`.

### Task 9: `/admin/smart-space` page

**Files:**
- Create: `lib/mydia_web/live/admin_smart_space_live/index.ex`, `index.html.heex`
- Modify: `lib/mydia_web/router.ex` (beside `live "/trash"` in the `/admin` scope: `live "/smart-space", AdminSmartSpaceLive.Index, :index`)
- Modify: `lib/mydia_web/admin_nav.ex` (a `%Page{key: :smart_space, hub: :administration, icon: "hero-sparkles", path: ~p"/admin/smart-space"}` after `:trash`) and wherever `:trash`'s nav label is defined
- Test: `test/mydia_web/live/admin_smart_space_live_test.exs`

**Interfaces:**
- Consumes: `SmartSpace.upcoming/1`, `SmartSpace.last_run_at/0`, `Rules.keep/2`, `Rules.unkeep/1`, `Rules.list_keeps/1`.
- Produces: header `#smart-space-summary` (bytes due in 30 days, last run); tabs `#smart-space-tab-upcoming`, `#smart-space-tab-kept` (`patch` with `?tab=kept`); streams `:upcoming` (`#smart-space-upcoming`, row id from `"#{media_item_id}-#{season_number}-#{hd(episode_ids)}"`) and `:keeps` (`#smart-space-keeps`); buttons `keep-<row id>` (event `keep`, values `media-item-id`, `season-number`, `episode-id`, `unit`) and `unkeep-<keep id>`; empty state `#smart-space-empty` with a link to settings when no rule is enabled anywhere.
- Due label: `"next run"` when `eligible_at <= now`, otherwise `ngettext("in %{count} day", "in %{count} days", days)`.

- [ ] **Step 1: Write failing tests:** admin sees an upcoming row for a fictional show due in 3 days with "in 3 days"; clicking Keep removes the row and a keep appears on the kept tab; Remove on the kept tab brings it back; empty state when disabled; a non-admin is redirected like `/admin/trash`.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file. Expected: PASS.
- [ ] **Step 5: Commit** `feat(smart-space): upcoming cleanups page`.

### Task 10: Show page override, badges and keep toggles

**Files:**
- Create: `lib/mydia_web/live/media_live/show/smart_space_events.ex`
- Create: `lib/mydia_web/live/media_live/show/smart_space_components.ex` (override modal, badge, keep toggle)
- Modify: `lib/mydia_web/live/media_live/show.ex` (assigns `smart_space_rule`, `smart_space_due` map, `show_smart_space_modal`; route events), `show/monitoring_menu.ex` (menu entry), `show/season_components.ex` (badge + toggle in the season header; episode-row toggle when unit is `"episode"`)
- Test: `test/mydia_web/live/media_live/smart_space_test.exs`

**Interfaces:**
- Consumes: `Loader.load(media_item_id: id)`, `Evaluator.effective_rule/2`, `SmartSpace.upcoming(media_item_id: id)`, `Rules.put_override/2`, `Rules.keep/2`, `Rules.unkeep/1`, `Rules.list_keeps(media_item_id: id)`.
- Produces: `smart_space_due :: %{{season_number, episode_id | nil} => DateTime.t()}`; menu entry `#smart-space-menu` showing "Smart Space: Inherit (season, 7 days)" / "Off" / "Custom (episode, 3 days)"; modal `#smart-space-modal` with form `#smart-space-override-form` (`mode`, `unit`, `grace_days`); badge `#season-N-smart-space-due`; toggles `#season-N-keep`, `#episode-<id>-keep`. Editing requires `can_update_media`; keep toggles require `can_delete_media?`. Movies render none of this.
- Data loads once on mount and after each Smart Space event, not on every `load_media_item/2`.

- [ ] **Step 1: Write failing tests:** menu shows the inherited rule; choosing Off persists an override and hides the badges; Custom with episode/3 persists and shows episode toggles; season due in 2 days shows `#season-1-smart-space-due` with "in 2 days"; `#season-1-keep` creates a season keep and hides the badge; clicking again removes it; a movie page has no `#smart-space-menu`.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file plus `./dev mix test test/mydia_web/live/media_live`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(media): Smart Space controls on the show page`.

### Task 11: Spec touch-ups, translations and the full gate

**Files:**
- Modify: `design/specs/2026-11-27-smart-space-design.md`
- Modify: gettext catalogs per `lib/mydia_web/gettext/README.md`
- Modify: `lib/mydia/media/README.md` (a short Smart Space section: trash reason, unmonitor on cleanup, restore does not re-monitor)

- [ ] **Step 1: Update the spec** to match decisions made in this plan: aired episodes without files need not be watched; unaired means `air_date` nil or in the future; username existence is checked at load and on save, not in the config changeset; "pending import candidate" exclusion is replaced by `Download.occupying/1` (candidates carry no episode link), with season-pack downloads blocking the whole show.
- [ ] **Step 2: Extract and check gettext** with the commands in `lib/mydia_web/gettext/README.md`. Expected: catalog check passes.
- [ ] **Step 3: Run** `./dev mix precommit` (split the suite into foreground chunks if it outruns the Bash timeout). Expected: no warnings, no failures, format clean.
- [ ] **Step 4: Commit** `docs(smart-space): align spec with implementation; translations`.
