# Background Episode Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A TV show add returns as soon as its `media_items` row exists, and an Oban job fetches its episodes afterwards (#1380).

**Architecture:** A new `Mydia.Jobs.EpisodeFetch` worker wraps `Media.fetch_episodes_for_new_show/2` and chains search-on-add after it. `Media.create_media_item/3` replaces `:skip_episode_refresh` with `:episodes` (`:background` default, `:inline`, `:skip`). `Mydia.Media.Add` takes over search-on-add so the search ordering lives in one place. The show page shows a placeholder while the job is pending and reloads on the existing `media_item.episodes_refreshed` event.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Oban (Basic/Lite engines), Ecto on SQLite and PostgreSQL, Bypass.

**Spec:** `design/specs/2026-11-11-background-episode-fetch-design.md`

## Global Constraints

- Run every command through `./dev` (`./dev mix test <file>`). Commit with plain `git commit -F <msgfile>` from the worktree with direnv loaded; verify each commit with `git show --stat HEAD`.
- Insert jobs with singular `Oban.insert/1`, never `Oban.insert_all/1` (uniqueness is only checked on the singular path).
- `EpisodeFetch`: queue `:media`, `max_attempts: 3`, `unique: [period: :infinity, keys: [:media_item_id], states: [:available, :scheduled, :executing, :retryable]]`.
- Job args keys are strings: `"media_item_id"`, `"season_monitoring"` (default `"all"`), `"search_on_add"` (default `false`).
- Event actor for the job: `Events.episodes_refreshed(item, count, :job, "episode_fetch")`.
- `:skip_episode_refresh` is removed with no alias. Any other value of `:episodes` than `:background | :inline | :skip` raises `ArgumentError`.
- `:config` present and `:episodes` absent means `:inline`.
- TV flash copy: `"%{title} has been added. Episodes are being fetched in the background."` via `gettext`. Placeholder copy: `"Fetching episodes..."`.
- No em dashes in code comments or copy. No real movie or TV titles in tests; invent them.
- Oban in test is `testing: :manual, engine: false`: jobs are inserted, never run. Use `use Oban.Testing, repo: Mydia.Repo` with `assert_enqueued`/`refute_enqueued`/`perform_job`.

## Review Focus

1. **Same show added twice in quick succession** (double click, two tabs): expect one `EpisodeFetch` row. Test in Task 1 (`enqueue/2` twice).
2. **Approval rolled back after the item insert**: expect no orphan `EpisodeFetch` row. Test in Task 3.
3. **Show page opened after the job failed for good**: expect the normal empty state, not a spinner forever. Test in Task 4 (discarded job does not count as pending).
4. **TV add with `search_on_add` and `:inline`** (match dialog path, Bypass tests): search must still be queued, directly. Test in Task 3.
5. **Plugin page write rolled back**: the job row rolls back with it, and `after_commit/4` no longer fetches. Test in Task 3 (`page_actions_test`).

---

### Task 1: `EpisodeFetch` job

**Files:**
- Create: `lib/mydia/jobs/episode_fetch.ex`
- Modify: `lib/mydia/media/items.ex` (`fetch_episodes_for_new_show/2`, ~line 487)
- Test: `test/mydia/jobs/episode_fetch_test.exs`

**Interfaces:**
- Produces:
  - `Mydia.Media.fetch_episodes_for_new_show(MediaItem.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}` (was `:ok`). Still logs. Season monitoring is applied only on `{:ok, _}`.
  - `Mydia.Jobs.EpisodeFetch.enqueue(MediaItem.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}`. Opts: `:season_monitoring` (string), `:search_on_add` (boolean).
  - `Mydia.Jobs.EpisodeFetch.pending?(media_item_id :: String.t()) :: boolean()`. True when a job for that id is in `available | scheduled | executing | retryable`.
  - `Mydia.Jobs.EpisodeFetch.run(Args.t(), config :: map() | nil) :: :ok | {:discard, :not_found} | {:error, term()}`. `perform/1` is `run(Args.parse(job.args), nil)`. `run/2` exists so tests inject a Bypass relay config; `test/README.md` ("Tests must not mutate global env") forbids pointing `:metadata_relay_url` at Bypass instead.

- [ ] **Step 1: Write the failing tests** in `test/mydia/jobs/episode_fetch_test.exs` (`use Mydia.DataCase`, `use Oban.Testing, repo: Mydia.Repo`). Build the Bypass stubs and the `%{type: :metadata_relay, base_url: "http://localhost:#{bypass.port}", options: %{}}` config the way `test/mydia/jobs/metadata_refresh_episodes_test.exs` does, and call `EpisodeFetch.run(EpisodeFetch.Args.parse(args), config)` for every test that reaches the relay.
  - `test "creates episodes and records the event"`: tv_show created with `episodes: :skip`, `run(Args.parse(%{"media_item_id" => item.id}), config)` returns `:ok`; `Episodes.list_episodes(Scope.system(), item.id)` is non-empty; an event with `type: "media_item.episodes_refreshed"` and `resource_id: item.id` exists.
  - `test "applies season_monitoring first"`: args include `"season_monitoring" => "first"`; only season 1 episodes are `monitored: true`.
  - `test "queues TVShowSearch only when search_on_add"`: with `"search_on_add" => true`, `assert_enqueued(worker: Mydia.Jobs.TVShowSearch, args: %{"mode" => "show", "media_item_id" => item.id})`; with it absent, `refute_enqueued(worker: Mydia.Jobs.TVShowSearch)`.
  - `test "relay failure returns error and queues no search"`: Bypass returns 500; result matches `{:error, _}`; `refute_enqueued(worker: Mydia.Jobs.TVShowSearch)` even with `"search_on_add" => true`.
  - `test "discards a deleted item"`: `perform_job(EpisodeFetch, %{"media_item_id" => Ecto.UUID.generate()})` gives `{:discard, :not_found}` (no relay call, so `perform_job` is safe here); a movie item id also gives `{:discard, :not_found}`.
  - `test "enqueue is unique per media item"`: `enqueue(item, [])` twice; `all_enqueued(worker: EpisodeFetch)` has length 1.
  - `test "pending? tracks job state"`: false before enqueue, true after; after `Repo.update_all` sets the job `state: "discarded"`, false.

- [ ] **Step 2: Run to confirm failure**
  Run: `./dev mix test test/mydia/jobs/episode_fetch_test.exs`
  Expected: compile error, `Mydia.Jobs.EpisodeFetch` undefined.

- [ ] **Step 3: Change `fetch_episodes_for_new_show/2`** to return `{:ok, count}` / `{:error, reason}`. Update its `@spec` and `@doc` ("Failures are logged and returned"). Callers that ignore the result keep working; `create_media_item/3` ignores it until Task 2.

- [ ] **Step 4: Implement `Mydia.Jobs.EpisodeFetch`** with an `Args` struct parsed from string keys (pattern from `Mydia.Jobs.MetadataRefresh.Args`). `run/2`: load the item under `Scope.system()` with whichever non-raising getter `Mydia.Media` exposes; non-`"tv_show"` or nil gives `{:discard, :not_found}`; call `fetch_episodes_for_new_show(item, season_monitoring: args.season_monitoring, config: config)` (the function already drops a nil `:config`); `{:ok, count}` records the event, then `Mydia.Search.maybe_queue_search(item, args.search_on_add)`, then `:ok`; `{:error, reason}` is returned as is. `pending?/1` queries `Oban.Job` with `worker == "Mydia.Jobs.EpisodeFetch"`, the four states, and a portable args match: filter in Elixir over the rows for that worker and state, since json path operators differ between SQLite and PostgreSQL.

- [ ] **Step 5: Run tests**
  Run: `./dev mix test test/mydia/jobs/episode_fetch_test.exs`
  Expected: all pass.

- [ ] **Step 6: Commit** `feat(media): add EpisodeFetch job for new shows (#1380)`.

---

### Task 2: `:episodes` option on `create_media_item/3`

**Files:**
- Modify: `lib/mydia/media/items.ex` (`create_media_item/3`, docs ~line 385-450)
- Modify: `lib/mydia/media/add.ex` (`@create_opt_keys`, `from_attrs/4` doc about the network call)
- Modify, `skip_episode_refresh: true` to `episodes: :skip`: `lib/mydia/demo/library.ex`, `lib/mydia/import_candidates/local_shows.ex`, `lib/mydia/library/metadata_enricher.ex`, `lib/mydia/plugins/page_writes.ex` (temporarily; Task 3 removes it), `lib/mydia_web/schema/README.md`, `test/support/fixtures/media_fixtures.ex`, `test/support/plex_plugin_case.ex`, and every other file `grep -rln skip_episode_refresh test` lists (about 30)
- Test: `test/mydia/media/create_media_item_episodes_test.exs` (create)

**Interfaces:**
- Consumes: `EpisodeFetch.enqueue/2`, `fetch_episodes_for_new_show/2` (Task 1).
- Produces: `create_media_item(scope, attrs, opts)` accepts `episodes: :background | :inline | :skip`. With `:background` and a `tv_show`, it calls `EpisodeFetch.enqueue(item, season_monitoring: opts[:season_monitoring] || "all", search_on_add: opts[:search_on_add] || false)`. `:search_on_add` is also a create opt now, consumed only by this enqueue. `Add`'s `@create_opt_keys` gains `:episodes` and `:search_on_add`.

- [ ] **Step 1: Write the failing tests** in `create_media_item_episodes_test.exs` (`use Oban.Testing`):
  - `test "default enqueues EpisodeFetch and creates no episodes"`: tv_show attrs with no `:config`; `assert_enqueued(worker: Mydia.Jobs.EpisodeFetch, args: %{"media_item_id" => item.id, "season_monitoring" => "all", "search_on_add" => false})`; episode count is 0.
  - `test "forwards season_monitoring and search_on_add"`: opts `season_monitoring: "latest", search_on_add: true`; args carry `"latest"` and `true`.
  - `test ":skip enqueues nothing"`: `refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)`.
  - `test ":inline fetches before returning"`: Bypass relay, `episodes: :inline, config: config`; episodes exist on return; nothing enqueued.
  - `test ":config without :episodes stays inline"`: same as above without `:episodes`.
  - `test "movies never enqueue"`.
  - `test "unknown value raises"`: `assert_raise ArgumentError, fn -> create_media_item(scope, attrs, episodes: :later) end`.
  - `test "skip_episode_refresh is no longer honoured"`: passing `skip_episode_refresh: true` alone still enqueues (proves the clean break).

- [ ] **Step 2: Run to confirm failure**
  Run: `./dev mix test test/mydia/media/create_media_item_episodes_test.exs`
  Expected: failures on enqueue assertions.

- [ ] **Step 3: Implement** a private `episodes_mode(opts) :: :background | :inline | :skip` (raises on anything else; `:config` without `:episodes` gives `:inline`) and branch after auto-approve in `create_media_item/3`. If the enqueue returns `{:error, reason}`, log a warning and still return `{:ok, item}`; the scheduled `MetadataRefresh` recovers it. Rewrite the `## Options` doc entry.

- [ ] **Step 4: Replace every `skip_episode_refresh: true`** with `episodes: :skip` in lib, tests and the schema README. Afterwards `grep -rn skip_episode_refresh lib test` returns only the Step 1 clean-break test.

- [ ] **Step 5: Run the affected suites**
  Run: `./dev mix test test/mydia/media test/mydia/jobs/episode_fetch_test.exs test/mydia/media_requests_test.exs test/mydia/import_lists_test.exs test/mydia/library test/mydia/plugins`
  Expected: all pass. A test that asserted episodes right after a non-`:config` add now fails; give it `episodes: :inline` plus its Bypass config, or assert the enqueue instead, whichever matches what it is testing.

- [ ] **Step 6: Commit** `feat(media): fetch new show episodes in the background by default (#1380)`.

---

### Task 3: Search-on-add ownership and inline callers

**Files:**
- Modify: `lib/mydia/media/add.ex` (`from_provider/5`, `from_attrs/4`)
- Modify: `lib/mydia_web/live/helpers/media_add_helpers.ex` (`handle_add_media_to_library/6`)
- Modify: `lib/mydia_web/library_schema/resolvers/library_writes.ex` (`add/4`, `added/2`, moduledoc)
- Modify: `lib/mydia/plugins/page_writes.ex` (`execute("media_add", ...)`, delete the `"media_add"` clause of `after_commit/4`, keep the catch-all and its doc minus the episode sentence)
- Modify: `lib/mydia_web/live/downloads_live/match_dialog.ex` (`add_opts/0` adds `episodes: :inline`)
- Test: `test/mydia/media/add_test.exs`, `test/mydia_web/live/helpers/media_add_helpers_test.exs`, `test/mydia/plugins/page_writes_test.exs`, `test/mydia/plugins/page_actions_test.exs` (lines ~427 and ~456), `test/mydia_web/live/downloads_live/match_dialog_test.exs`, `test/mydia/media_requests_test.exs`

**Interfaces:**
- Consumes: `create_media_item` opts `:episodes`, `:search_on_add` (Task 2).
- Produces: `Add.from_provider/5` and `Add.from_attrs/4` accept `search_on_add: boolean()`. After a successful insert, `Add` calls `Mydia.Search.maybe_queue_search(item, true)` itself unless the item is a `tv_show` whose effective mode is `:background` (then the flag rode in the job args). `{:already_in_library, _}` never queues a search, matching today. Callers stop calling `maybe_queue_search/2` after an add. `MediaAddHelpers.handle_add_media_to_library/6` keeps its signature; it passes `:search_on_add` through instead of popping it.

- [ ] **Step 1: Write the failing tests**
  - `add_test.exs`, `test "tv add with search_on_add defers the search to EpisodeFetch"`: `Add.from_attrs(scope, tv_attrs, nil, search_on_add: true)`; `assert_enqueued(worker: Mydia.Jobs.EpisodeFetch, args: %{"search_on_add" => true})`; `refute_enqueued(worker: Mydia.Jobs.TVShowSearch)`.
  - `add_test.exs`, `test "inline tv add with search_on_add queues the search directly"`: Bypass config, `episodes: :inline, search_on_add: true`; `assert_enqueued(worker: Mydia.Jobs.TVShowSearch, args: %{"mode" => "show"})`.
  - `add_test.exs`, `test "movie add with search_on_add queues MovieSearch"`.
  - `media_add_helpers_test.exs`: update the existing search-on-add test so a TV add asserts the `EpisodeFetch` args and no `TVShowSearch`.
  - `media_requests_test.exs`, `test "rolled back approval leaves no EpisodeFetch job"`: force the rollback the same way the file's existing rollback test does (a request whose later step fails); `refute_enqueued(worker: Mydia.Jobs.EpisodeFetch)`.
  - `page_writes_test.exs`: a `media_add` for a tv show enqueues `EpisodeFetch` with the defaults' `season_monitoring` and `search_on_add`.
  - `page_actions_test.exs`: replace the two `after_commit("media_add", ...)` fetch assertions with `assert :ok = PageWrites.after_commit("media_add", result, user, prepared)` and no episodes created, no relay call.
  - `match_dialog_test.exs`, `test "adding a new show offers its episodes"`: `add_external/2` then `select/2` returns `{:episodes, dialog}` with a non-empty episode list (Bypass relay).

- [ ] **Step 2: Run to confirm failure**
  Run: `./dev mix test test/mydia/media/add_test.exs test/mydia_web/live/helpers/media_add_helpers_test.exs test/mydia/plugins/page_writes_test.exs test/mydia/plugins/page_actions_test.exs test/mydia_web/live/downloads_live/match_dialog_test.exs test/mydia/media_requests_test.exs`
  Expected: the new assertions fail.

- [ ] **Step 3: Implement.** In `Add`, compute the effective mode with the same rule as Task 2. Expose that rule from `Mydia.Media.Items` as `@doc false def episodes_mode/1` instead of duplicating it. Pass `search_on_add` through `@create_opt_keys`. Remove the post-add `maybe_queue_search/2` calls from `MediaAddHelpers`, `LibraryWrites` (pass `search_on_add: input[:search_now] == true` into `add_opts`) and `PageWrites`. Drop `episodes: :skip` from `PageWrites.execute/5`.

- [ ] **Step 4: Run the Step 2 command.** Expected: all pass.

- [ ] **Step 5: Commit** `feat(media): chain search-on-add after the episode fetch (#1380)`.

---

### Task 4: UI feedback

**Files:**
- Modify: `lib/mydia_web/live/discover_live/index.ex` (success flash, ~line 779), `lib/mydia_web/live/dashboard_live/index.ex` (~line 690), `lib/mydia_web/live/media_live/show/franchise_events.ex`, `lib/mydia_web/live/media_live/show/recommendation_events.ex`
- Modify: `lib/mydia_web/live/helpers/media_add_helpers.ex` (add `added_message/1`)
- Modify: `lib/mydia_web/live/media_live/show.ex` (mount assign, `{:event_created, _}` handler ~line 769)
- Modify: `lib/mydia_web/live/media_live/show/components.ex` (~line 418, season container)
- Modify: `priv/gettext` catalogs per `lib/mydia_web/gettext/README.md`
- Test: `test/mydia_web/live/discover_live/` (existing add test file), `test/mydia_web/live/media_live/show_episode_fetch_test.exs` (create)

**Interfaces:**
- Consumes: `EpisodeFetch.pending?/1` (Task 1); the `media_item.episodes_refreshed` event (Task 1).
- Produces: `MediaAddHelpers.added_message(MediaItem.t()) :: String.t()`. TV gives the background copy from Global Constraints; movie gives the existing `"%{title} has been added to your library"`. New show assign `:fetching_episodes?` (boolean).

- [ ] **Step 1: Write the failing tests**
  - Discover: adding a TV result flashes `"has been added. Episodes are being fetched in the background."`; a movie keeps the old flash.
  - `show_episode_fetch_test.exs`:
    - `test "shows the placeholder while a fetch is pending"`: tv show with no episodes, `EpisodeFetch.enqueue(item, [])`, `live(conn, ~p"/media/#{item.id}")` (use the route the existing show tests use); `assert has_element?(view, "#episodes-fetching")`.
    - `test "episodes_refreshed event replaces the placeholder"`: insert an episode, then `send(view.pid, {:event_created, %{type: "media_item.episodes_refreshed", resource_type: "media_item", resource_id: item.id}})`; `refute has_element?(view, "#episodes-fetching")` and the season section renders.
    - `test "a discarded job shows the normal empty state"`: job state set to `"discarded"`; `refute has_element?(view, "#episodes-fetching")`.
    - `test "unrelated events do not reload"`: an event for another id leaves the placeholder.

- [ ] **Step 2: Run to confirm failure**
  Run: `./dev mix test test/mydia_web/live/media_live/show_episode_fetch_test.exs test/mydia_web/live/discover_live`
  Expected: new tests fail.

- [ ] **Step 3: Implement.** Swap the four success flashes to `MediaAddHelpers.added_message(media_item)`. In `show.ex` mount, assign `:fetching_episodes?` as `media_item.type == "tv_show" and media_item.episodes == [] and EpisodeFetch.pending?(media_item.id)`. In `components.ex`, when `@fetching_episodes?`, render `<div id="episodes-fetching" class="flex items-center gap-2 p-6 text-base-content/70"><span class="loading loading-spinner loading-sm"></span>{gettext("Fetching episodes...")}</div>` in place of the season loop; thread the assign into the component like its siblings. In the `{:event_created, event}` handler, add a first clause for `event.type == "media_item.episodes_refreshed"` on the current id. It reloads with `load_media_item/2`, reassigns `:media_item`, recomputes downloads via `assign_downloads/2` and `default_expanded_seasons/2`, sets `:fetching_episodes?` to false, then falls through to the timeline reload the handler already does.

- [ ] **Step 4: Update gettext catalogs** per `lib/mydia_web/gettext/README.md` (extract and merge; the catalog check must pass).

- [ ] **Step 5: Run the Step 2 command.** Expected: all pass.

- [ ] **Step 6: Commit** `feat(web): show background episode fetch on add and on the show page (#1380)`.

---

### Task 5: Full verification

- [ ] **Step 1:** `grep -rn "skip_episode_refresh\|fetch_episodes_for_new_show" lib test`. Expected: only the Task 2 clean-break test, the job, `items.ex` and its tests.
- [ ] **Step 2:** `./dev mix precommit`, run in foreground chunks if it outruns the Bash timeout (by test directory: `test/mydia`, `test/mydia_web`, the rest). Expected: format, credo, compile warnings and tests clean.
- [ ] **Step 3:** Manual check with `./dev up -d`: on Discover, add three shows with long runs back to back. Each card should flip to "Go to Show" within a few seconds, and each show page should show "Fetching episodes..." and then fill in.
- [ ] **Step 4:** Commit any fixes, then `git log origin/master..HEAD --stat` and confirm that only files named in this plan changed.
