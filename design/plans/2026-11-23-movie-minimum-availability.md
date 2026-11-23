# Movie Minimum Availability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatic movie searches wait until a movie could plausibly be available, by a global threshold with a per-movie override.

**Architecture:** TMDB digital and physical release dates join `MediaMetadata`. A pure `Mydia.Media.MinimumAvailability` module turns an item plus a level into an eligible date. `Mydia.Jobs.MovieSearch` is the single enforcement point; only the movie page's search button bypasses it.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto (SQLite and PostgreSQL), Oban.

**Spec:** `design/specs/2026-11-23-movie-minimum-availability-design.md`

## Global Constraints

- Levels are exactly the strings `"announced"`, `"in_cinemas"`, `"released"`.
- Global key `media.minimum_availability`, schema default `"released"`, env var `MINIMUM_AVAILABILITY`.
- Per-movie column `media_items.minimum_availability`, `:text`, nullable; nil means follow the global value.
- `released` fallback when TMDB has neither date: theatrical `release_date` + 90 days.
- No usable date at any level: eligible now.
- Migration filename uses a real timestamp, checked for collisions across remote branches (AGENTS.md, Git Guidelines).
- Fixtures use invented titles only.
- No em dashes in docs, comments or UI copy. All UI copy through `gettext`.
- Run `./dev mix ...` for every mix command; commit with plain `git commit` inside the direnv-loaded worktree, then `git show --stat HEAD`.

## Review Focus

- A movie whose stored metadata predates schema version 3 (no digital/physical keys): must fall back, not crash. Test in Task 3.
- A movie with `metadata: nil`: eligible now. Test in Task 3.
- The grab-delay recheck (`recheck: true`) for a movie that became unavailable after an override change: skipped like any `specific` job. Test in Task 4.
- An existing install whose DB has only TV shows: no `announced` row (it has no movies to protect). Test in Task 2.
- An override set to the same value as the global: still stored, still honoured if the global later changes. Test in Task 5.

---

### Task 1: Parse and store digital and physical release dates

**Files:**
- Modify: `lib/mydia/metadata/structs/media_metadata.ex` (struct fields, type, `from_api_response/3`, `@schema_version` 2 -> 3 with a history comment line "3: movie digital/physical release dates (minimum availability).")
- Modify: `lib/mydia/media/metadata_type.ex:108` (load the two fields with `parse_date/1`)
- Modify: `lib/mydia/jobs/metadata_backfill.ex` (`{:tmdb, "movie"} => 3`, comment line for 3)
- Test: `test/mydia/metadata/structs/media_metadata_test.exs`, `test/mydia/jobs/metadata_backfill_test.exs`, a MetadataType round-trip test next to the existing ones (`grep -rl MetadataType test/`)

**Interfaces:**
- Produces: `%MediaMetadata{digital_release_date: Date.t() | nil, physical_release_date: Date.t() | nil}`, populated for `:movie`, nil for `:tv_show`; survives a DB round trip through `Mydia.Media.MetadataType` as `Date`.

- [ ] **Step 1: Write failing tests**

In `media_metadata_test.exs`, `describe "release availability dates"`:
- `test "takes the earliest digital and physical dates across regions"`: data with `"release_dates" => %{"results" => [%{"iso_3166_1" => "US", "release_dates" => [%{"type" => 3, "release_date" => "2031-03-01T00:00:00.000Z"}, %{"type" => 4, "release_date" => "2031-05-20T00:00:00.000Z"}]}, %{"iso_3166_1" => "GB", "release_dates" => [%{"type" => 4, "release_date" => "2031-05-12T00:00:00.000Z"}, %{"type" => 5, "release_date" => "2031-07-01T00:00:00.000Z"}]}]}`; assert `digital_release_date == ~D[2031-05-12]`, `physical_release_date == ~D[2031-07-01]`.
- `test "nil when the types are absent or malformed"`: only type 3, plus one type 4 entry with `"release_date" => "garbage"`; both nil.
- `test "nil for tv shows"`.
In the backfill test: a TMDB movie stored at `schema_version: 2` is selected for refresh; one at 3 is not.
MetadataType: a movie blob with `"digital_release_date" => "2031-05-12"` loads as `~D[2031-05-12]`; a blob without the key loads as nil.

- [ ] **Step 2: Run to see them fail**

Run: `./dev mix test test/mydia/metadata/structs/media_metadata_test.exs test/mydia/jobs/metadata_backfill_test.exs`
Expected: failures on the new tests (unknown struct key / not selected).

- [ ] **Step 3: Implement**

`parse_release_type_date(data, :movie, type)`: flat-map `data["release_dates"]["results"][*]["release_dates"]`, keep entries with `"type" == type`, take `String.slice(date, 0, 10)` through the existing `parse_date/1`, reject nil, `Enum.min(dates, Date, fn -> nil end)`. Non-movie clause returns nil.

- [ ] **Step 4: Run tests, expect PASS** (same command)

- [ ] **Step 5: Commit** `feat(metadata): keep TMDB digital and physical release dates`

---

### Task 2: Global setting and upgrade migration

**Files:**
- Modify: `lib/mydia/config/schema.ex` (field in `embeds_one :media`, cast and `validate_inclusion` in `media_changeset/2`, public `minimum_availability_levels/0`)
- Modify: `lib/mydia/config/loader.ex` (`load_media_env/0`: `MINIMUM_AVAILABILITY`, downcased like `DEFAULT_SEASON_MONITORING`)
- Modify: `lib/mydia_web/live/admin_settings_live/index.ex` ("Media" list: `type: :select` entry, options helper like `oidc_default_role_options/0`), `lib/mydia_web/live/admin_settings_live/labels.ex` (label "Minimum Availability (automatic movie search)" and a description stating the three levels, the 90-day fallback, and that the movie page's Search button ignores it)
- Modify: `.env.example`, `config/config.example.yml` (commented entry next to `AUTO_SEARCH_ON_ADD` / `auto_search_on_add`)
- Create: `priv/repo/migrations/<real timestamp>_add_minimum_availability.exs`
- Modify: `lib/mydia/media/media_item.ex` (field, cast, `validate_inclusion` against `Mydia.Config.Schema.minimum_availability_levels/0`, empty string normalised to nil)
- Test: `test/mydia/config/` (loader env test file that covers `AUTO_SEARCH_ON_ADD`), `test/mydia_web/live/admin_settings_live_minimum_availability_test.exs` (modelled on `admin_settings_live_oidc_default_role_test.exs`), `test/mydia/repo/migrations/add_minimum_availability_test.exs`, `test/mydia/media/media_item_test.exs`

**Interfaces:**
- Produces: `Mydia.Config.get().media.minimum_availability :: String.t()`; `Mydia.Config.Schema.minimum_availability_levels() :: [String.t()]` returning `["announced", "in_cinemas", "released"]`; `%MediaItem{minimum_availability: String.t() | nil}` castable through `MediaItem.changeset/2`.

- [ ] **Step 1: Write failing tests**
- Schema default is `"released"`; `"sometime"` is rejected by `media_changeset`.
- `MINIMUM_AVAILABILITY=IN_CINEMAS` resolves to `"in_cinemas"` (follow the existing env test's set/restore pattern; never leak env).
- Admin page: `#setting-form-media-minimum_availability` offers three options with `released` selected; choosing `in_cinemas` stores the `config_settings` row and `Mydia.Config.get().media.minimum_availability == "in_cinemas"`.
- `MediaItem.changeset/2` accepts each level and nil, maps `""` to nil, rejects `"soon"`.
- Migration test: run the migration's `up/0` logic against a DB with one movie → a `media.minimum_availability` row valued `announced` exists; with only a TV show, or empty → no row. Use the approach the repo's existing migration tests use (`grep -rl "Ecto.Migrator" test/mydia/repo`).

- [ ] **Step 2: Run to see them fail**

Run: `./dev mix test <the files above>`

- [ ] **Step 3: Implement**

Migration `up/0`: `alter table(:media_items), do: add(:minimum_availability, :text)`; `flush()`; if `SELECT 1 FROM media_items WHERE type = 'movie' LIMIT 1` returns a row, insert the `config_settings` row exactly as `20260911131949_move_remote_access_enabled_to_config_settings.exs` does (binary UUID on Postgres, `ON CONFLICT (key) DO NOTHING`), category `media` (check `Mydia.Settings.ConfigSetting`'s `@categories`; use the one `media.movies_path` rows carry). `down/0` deletes the row and removes the column.

Before naming the file run the duplicate-version check from AGENTS.md.

- [ ] **Step 4: Run tests, expect PASS**; also `./dev mix test test/mydia/repo/migrations/no_varchar_columns_test.exs`

- [ ] **Step 5: Commit** `feat(config): minimum availability setting for movie search`

---

### Task 3: `Mydia.Media.MinimumAvailability`

**Files:**
- Create: `lib/mydia/media/minimum_availability.ex`
- Test: `test/mydia/media/minimum_availability_test.exs`

**Interfaces:**
- Consumes: Task 1 fields, Task 2 config and column.
- Produces:
  - `effective(item :: MediaItem.t(), global :: String.t()) :: String.t()`
  - `eligible_on(item :: MediaItem.t(), level :: String.t()) :: Date.t() | nil`
  - `available?(item :: MediaItem.t(), today :: Date.t() \\ Date.utc_today()) :: boolean()` (reads the global through `Mydia.Config.get().media.minimum_availability`)
  - `status(item, today \\ Date.utc_today()) :: %{level: String.t(), eligible_on: Date.t() | nil, available?: boolean()}` for the event and the movie page.

- [ ] **Step 1: Write failing table tests** (build `%MediaItem{}` structs in memory with `%MediaMetadata{}`; async: true)
- `announced` → nil regardless of dates.
- `in_cinemas` → theatrical date; nil theatrical → nil.
- `released` with digital 2031-05-12 and physical 2031-07-01 → 2031-05-12; physical earlier → physical.
- `released` with neither → theatrical + 90 days (2031-03-01 → 2031-05-30).
- `released` with no dates at all → nil.
- `metadata: nil` → nil at every level.
- `effective/2`: override beats global; nil override follows global.
- `available?/2`: false the day before `eligible_on`, true on it.

- [ ] **Step 2: Run, expect FAIL** `./dev mix test test/mydia/media/minimum_availability_test.exs`
- [ ] **Step 3: Implement**; `@fallback_days 90` with a comment citing the spec.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** `feat(media): minimum availability rule`

---

### Task 4: Enforce in `MovieSearch`

**Files:**
- Modify: `lib/mydia/jobs/movie_search.ex` (`Args`: `ignore_availability: false` parsed like `bypass_delay`; `load_monitored_movies_without_files/0` rejects unavailable movies; the `specific` clause returns `:ok` early for unavailable movies unless `args.ignore_availability`)
- Modify: `lib/mydia/events.ex` (`search_skipped_unavailable(media_item, %{level: _, eligible_on: _})`, type `"search.skipped_unavailable"`, category `"search"`, actor `:job` via `search_actor_id/1`, metadata `"title"`, `"media_type"`, `"level"`, `"eligible_on"` as ISO date or nil)
- Modify: `lib/mydia_web/live/media_live/show/search_events.ex:139` (add `ignore_availability: true` to the movie job args)
- Test: `test/mydia/jobs/movie_search_test.exs`, the existing search_events/auto-search LiveView test for the movie page

**Interfaces:**
- Consumes: `MinimumAvailability.available?/2`, `status/2`.
- Produces: job arg `"ignore_availability" => true` honoured in `specific` mode.

- [ ] **Step 1: Write failing tests** (set the global through runtime config the way existing tests set `downloads.min_seeders`)
- `load_monitored_movies_without_files/0` excludes a monitored, file-less movie whose theatrical date is 30 days ahead under `released`, includes it under `announced`.
- `specific` job for that movie: no indexer call (assert with whatever indexer stub the file already uses), returns `:ok`, and a `search.skipped_unavailable` event with `"level" => "released"` and the expected `"eligible_on"`.
- Same job with `"ignore_availability" => true` searches.
- `"recheck" => true` job for an unavailable movie is skipped too.
- `upgrade` mode is unaffected.
- Movie page auto-search enqueues a job whose args include `"ignore_availability" => true` (`assert_enqueued` or the file's existing pattern).

- [ ] **Step 2: Run, expect FAIL** `./dev mix test test/mydia/jobs/movie_search_test.exs`
- [ ] **Step 3: Implement**; keep the check before any indexer or backoff work so skipped movies never accrue backoff.
- [ ] **Step 4: Run, expect PASS**; also `./dev mix test test/mydia/search_test.exs test/mydia/downloads/queue`
- [ ] **Step 5: Commit** `feat(search): wait for minimum availability before searching movies`

---

### Task 5: Per-movie override on the movie page

**Files:**
- Create: `lib/mydia_web/live/media_live/show/availability_components.ex` (`availability_row/1`, `availability_modal/1`, modelled on `DownloadAudioComponents`)
- Create: `lib/mydia_web/live/media_live/show/availability_events.ex` (`show_availability_modal/2`, `hide_availability_modal/2`, `set_minimum_availability/2`, modelled on `DownloadAudioEvents`, `"default"` stored as nil, malformed params flash an error)
- Modify: `lib/mydia_web/live/media_live/show.ex` (assign `:show_availability_modal` false, three `handle_event` delegations), `show/components.ex` (render the row next to `download_audio_row` for movies only), `show.html.heex` (render the modal)
- Test: `test/mydia_web/live/media_live/show/availability_test.exs` (modelled on `download_audio_test.exs`)

**Interfaces:**
- Consumes: `MinimumAvailability.status/2`, `effective/2`, `Mydia.Config.Schema.minimum_availability_levels/0`.
- Produces: DOM ids `#availability-row`, `#availability-modal`, `#availability-option-default`, `#availability-option-<level>`.

Row copy: label "Search Starts"; value "Now" when available, else "On %{date}" (date formatted like the page's other dates), suffixed with the level name. Modal: "Server default (%{level})" plus the three levels ("Announced", "In cinemas", "Released"), and one sentence: "Automatic search waits until this point. The Search button on this page ignores it."

- [ ] **Step 1: Write failing tests**
- Row renders only for movies, not TV shows.
- Choosing `in_cinemas` persists `minimum_availability == "in_cinemas"` and closes the modal.
- Choosing the server default stores nil.
- Choosing the level equal to the global still stores it; changing the global afterwards leaves the movie on its own level.
- A movie 30 days before its theatrical date under `released` shows the eligible date in `#availability-row`.

- [ ] **Step 2: Run, expect FAIL** `./dev mix test test/mydia_web/live/media_live/show/availability_test.exs`
- [ ] **Step 3: Implement**; authorize with `Authorization.authorize_update_media/1`, persist through `Media.update_media_item/4` with `reason: "Minimum availability updated"`.
- [ ] **Step 4: Run, expect PASS**; then `./dev mix gettext.extract --merge` if the gettext README requires it (read `lib/mydia_web/gettext/README.md`).
- [ ] **Step 5: Commit** `feat(web): per-movie minimum availability override`

---

### Task 6: Finish

- [ ] `./dev mix precommit` in foreground chunks if it nears the Bash timeout; fix everything it reports.
- [ ] `git diff --stat origin/master...` lists only files this plan names plus gettext catalogs.
- [ ] Commit any fixes; push `HEAD:feat/movie-minimum-availability`.
