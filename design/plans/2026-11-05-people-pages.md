# People Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking an actor anywhere on the web UI opens a person popup (photo, bio, Movies and Shows with library badges), and Discover can search people.

**Architecture:** Cast entries gain a TMDB person id (parsed, persisted, backfilled). metadata-relay gains two TMDB person routes. `Mydia.Metadata.People` fetches and parses people through the relay, cached. A shared `person_modal` function component plus a `PersonModal` host helper (mirroring `DetailModal`) is wired into Discover, the Dashboard and the media show page; filmography posters open the existing `TrendingDetailModal` over it.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, daisyUI 5, Req via `Mydia.Metadata.Provider.HTTP`, Bypass (mydia tests), `TMDBHelpers` mock adapter (relay tests).

**Spec:** `design/specs/2026-11-05-people-pages-design.md`

## Global Constraints

- Web UI only. No GraphQL, no Flutter changes.
- Every TMDB call goes through metadata-relay. No API keys in mydia.
- Structs, not maps, for parsed person data.
- Cast clickability is opt-in per `TrendingDetailModal` host (`person_event` assign, default nil). Off on `AdminRequestsLive` and `MyRequestsLive`.
- Discover People is a search scope only, shown while a query is active. The page-wide `type` param keeps its two values; no `/person/popular`.
- Filmography sections show the first 12 posters, then "Show all N".
- Every new user-facing string goes through `gettext`.
- Tests and fixtures use invented names and titles. No real people or titles.
- No migration files. No em dashes in docs or comments.
- Each component file stays under ~500 LOC.
- Commit each task inside the devenv shell (`git commit -F <msgfile>`), stage everything first, verify with `git show --stat`.

## Review Focus

1. **Same TMDB id in Movies and Shows.** TMDB numbers movies and TV separately, so a person can have movie 500 and show 500. Library badges and click resolution must key on `{media_type, id}`. Test in Task 5.
2. **Old relay (404 on the new routes) or relay down.** The popup must still open with the clicked name and photo and show an inline error with Retry, never a spinner forever or a crash. Tests in Tasks 4 and 6.
3. **Restricted scopes.** A user with an age or category restriction must not see filmography titles Discover would hide them from. Filmography goes through `Mydia.Media.RemoteFilter.filter/2`. Test in Task 5.
4. **Adding a show from a movie's page.** The media show page's add/request path assumes the viewed item's type. A TV title opened from an actor on a movie page must be added as a TV show. Test in Task 9.
5. **Prolific actors.** Hundreds of credits, many of them talk-show and news appearances. Talk (genre 10767) and News (10763) TV credits are dropped, duplicates collapse, and only 12 posters per section render until "Show all". Tests in Tasks 4 and 5.

---

### Task 1: Persist a TMDB person id on cast members

**Files:**
- Modify: `lib/mydia/metadata/structs/cast_member.ex`
- Modify: `lib/mydia/metadata/structs/media_metadata.ex` (`@schema_version`, version comment, `parse_cast/1`)
- Modify: `lib/mydia/media/metadata_type.ex` (`parse_cast_list/1`)
- Modify: `lib/mydia/jobs/metadata_backfill.ex` (`@required_versions`, its comment)
- Test: `test/mydia/metadata/structs/media_metadata_test.exs`, `test/mydia/media/metadata_type_test.exs` (create if absent), `test/mydia/jobs/metadata_backfill_test.exs`

**Interfaces:**
- Produces: `%CastMember{tmdb_person_id: integer() | nil}`; `MediaMetadata.schema_version() == 2`.

- [ ] **Step 1: Write the failing tests**
  - `media_metadata_test.exs`, "parses the TMDB person id onto cast": `from_api_response` on a TMDB movie body whose `credits.cast` is `[%{"id" => 4242, "name" => "Odhran Pike", "character" => "Captain Reyes", "order" => 0}]` yields `[%CastMember{tmdb_person_id: 4242, name: "Odhran Pike"}]`, and `metadata.schema_version == 2`.
  - `metadata_type_test.exs`, "round-trips tmdb_person_id": `dump` then `load` of a `MediaMetadata` with that cast member keeps `tmdb_person_id: 4242`; loading a stored map with no `tmdb_person_id` key gives `nil`.
  - `metadata_backfill_test.exs`: a TMDB movie and a TMDB TV show stored with `schema_version: 1` are each enqueued for refresh; the same items at version 2 are not; a TVDB show at version 1 is enqueued.
- [ ] **Step 2: Run them, expect failures**
  Run: `./dev mix test test/mydia/metadata/structs/media_metadata_test.exs test/mydia/media/metadata_type_test.exs test/mydia/jobs/metadata_backfill_test.exs`
  Expected: FAIL (unknown key `tmdb_person_id`, version 1, items not selected).
- [ ] **Step 3: Implement**
  - Add `:tmdb_person_id` to `CastMember`'s struct and type.
  - `parse_cast/1`: `tmdb_person_id: member["id"]` (integer or nil).
  - `@schema_version 2`, with comment line `# 2: cast carries tmdb_person_id (people pages, #1346).`
  - `parse_cast_list/1` in `MetadataType`: `tmdb_person_id: member[:tmdb_person_id]`.
  - `@required_versions %{{:tvdb, "tv_show"} => 2, {:tmdb, "tv_show"} => 2, {:tmdb, "movie"} => 2}` and update the comment above it.
- [ ] **Step 4: Run the tests, expect PASS** (same command). Also run any test that hard-codes schema version 1: `grep -rn "schema_version" test/` and fix expectations that meant "current version".
- [ ] **Step 5: Commit** `feat(metadata): keep the TMDB person id on cast members`

### Task 2: Link TVDB cast to TMDB people

**Files:**
- Modify: `lib/mydia/metadata/provider/relay.ex` (`perform_tvdb_fetch/4` and new private helpers next to `tmdb_rating_for_tvdb/2`)
- Test: `test/mydia/metadata/provider/relay_tvdb_cast_test.exs`

**Interfaces:**
- Consumes: Task 1's `CastMember.tmdb_person_id`.
- Produces: TVDB-sourced `MediaMetadata.cast` entries carry `tmdb_person_id` when matched.

- [ ] **Step 1: Write the failing tests** (Bypass, following the file's existing setup)
  - "copies TMDB person ids onto TVDB cast by name": TVDB extended body has `remoteIds` with TheMovieDB.com id `"77"` and characters for "Marisol Ventura" and "Bram Okafor"; Bypass serves `GET /tmdb/tv/shows/77` with `append_to_response` containing `aggregate_credits` returning `aggregate_credits.cast` `[%{"id" => 501, "name" => "Marisol Ventura"}]`. Assert Ventura has `tmdb_person_id: 501`, Okafor `nil`.
  - "matches ignoring case and accents": TVDB name "Ines Duval", TMDB "Inés Duval" → matched.
  - "leaves an ambiguous name unlinked": two TMDB cast entries named the same with different ids → `nil`.
  - "a failing TMDB lookup leaves the cast unlinked and the fetch succeeds": Bypass returns 500 → `{:ok, metadata}`, all ids `nil`.
  - "no TMDB cross-reference makes no extra request": no `remoteIds` → no call to `/tmdb/tv/shows/*` (Bypass would fail on an unexpected request).
- [ ] **Step 2: Run, expect FAIL**: `./dev mix test test/mydia/metadata/provider/relay_tvdb_cast_test.exs`
- [ ] **Step 3: Implement** `defp link_tvdb_cast(config, data, cast) :: [CastMember.t()]`, applied in `perform_tvdb_fetch/4` alongside `videos`/`content_rating`. It fetches `/tmdb/tv/shows/#{tmdb_id}` with `append_to_response: "aggregate_credits"` through `HTTP.get`, wrapped in `Cache.fetch("tvdb_tmdb_people:#{tmdb_id}", ..., ttl: :timer.hours(24))` returning `{:ok, %{normalized_name => id}}`. Names that occur twice map to nothing. Normalize with `:unicode.characters_to_nfd_binary/1`, strip `~r/\p{Mn}/u`, `String.downcase/1`, `String.trim/1`. Any error degrades to the unlinked cast (and is not cached, like the rating fallback).
- [ ] **Step 4: Run, expect PASS** (same command plus `test/mydia/metadata/provider/relay_tvdb_*`).
- [ ] **Step 5: Commit** `feat(metadata): link TVDB cast to TMDB people through the cross-reference`

### Task 3: metadata-relay person routes

**Files:**
- Modify: `metadata-relay/lib/metadata_relay/tmdb/handler.ex`
- Modify: `metadata-relay/lib/metadata_relay/router.ex` (next to `/tmdb/collections/:id`)
- Test: `metadata-relay/test/metadata_relay/tmdb/handler_test.exs`

**Interfaces:**
- Produces: `GET /tmdb/person/search?query=&language=&page=&include_adult=` → TMDB `/search/person` body verbatim. `GET /tmdb/person/:id?language=&append_to_response=` → TMDB `/person/{id}` body verbatim.
- Handler: `search_people(params)`, `get_person(id, params)`.

- [ ] **Step 1: Write the failing tests**, copying the `describe "GET /tmdb/collections/:id"` block's shape: for each route, whole-body equality against a fixture via `TMDBHelpers.mock_adapter_with_routes(%{"/3/search/person" => ...})` / `"/3/person/31"`; the query params (`language`, `append_to_response=combined_credits`) reach TMDB; a TMDB 404 propagates with its status.
- [ ] **Step 2: Run, expect FAIL**: `cd metadata-relay && mix test test/metadata_relay/tmdb/handler_test.exs` (use the relay's own dev shell / `./dev` equivalent if the root one doesn't cover it).
- [ ] **Step 3: Implement** both handler functions as `Client.get("/search/person", params: params)` and `Client.get("/person/#{id}", params: params)`, and both routes with `handle_tmdb_request/2`. `/tmdb/person/search` must be declared before `/tmdb/person/:id`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(relay): proxy TMDB person search and person details`

### Task 4: `Mydia.Metadata.People`: fetch, search, parse

**Files:**
- Create: `lib/mydia/metadata/structs/person.ex`, `lib/mydia/metadata/structs/person_credit.ex`, `lib/mydia/metadata/structs/person_search_result.ex`
- Create: `lib/mydia/metadata/people.ex`
- Modify: `lib/mydia/metadata.ex` (two cached facade functions)
- Test: `test/mydia/metadata/people_test.exs`

**Interfaces:**
- Produces:
  - `%Person{tmdb_id: integer, name: String.t, biography: String.t | nil, birthday: Date.t | nil, place_of_birth: String.t | nil, known_for_department: String.t | nil, profile_path: String.t | nil, movie_credits: [PersonCredit.t], tv_credits: [PersonCredit.t]}`
  - `%PersonCredit{tmdb_id: integer, media_type: :movie | :tv_show, title: String.t, year: integer | nil, date: Date.t | nil, character: String.t | nil, episode_count: integer | nil, poster_path, backdrop_path, overview, genre_ids: [integer], origin_country: [String.t], original_language, vote_average}`
  - `PersonCredit.to_search_result(PersonCredit.t) :: SearchResult.t` with `provider: :tmdb`, `provider_id: Integer.to_string(id)`, `media_type`, `title`, `year`, `poster_path`, `backdrop_path`, `overview`, `genre_ids`, `origin_country`, `original_language`, `vote_average`, and `release_date` or `first_air_date` as an ISO string.
  - `%PersonSearchResult{tmdb_id: integer, name: String.t, profile_path: String.t | nil, known_for_department: String.t | nil, known_for: [String.t]}`
  - `Mydia.Metadata.fetch_person_cached(config, tmdb_id :: integer, opts \\ []) :: {:ok, Person.t} | {:error, Provider.Error.t}`
  - `Mydia.Metadata.search_people_cached(config, query :: String.t, opts \\ []) :: {:ok, [PersonSearchResult.t]} | {:error, Provider.Error.t}`
  - Both relay-only, with the same non-relay `invalid_config` clause as `fetch_collection_cached/3`. Cache keys `"person:metadata_relay:#{id}:#{language}"` and `"person_search:metadata_relay:#{query}:#{language}"`, `ttl: :timer.hours(24)`.

- [ ] **Step 1: Write the failing tests** (Bypass, setup copied from `collection_fetch_test.exs`, `on_exit` deleting the cache keys)
  - "parses a person with split, sorted filmography": `/tmdb/person/31` (assert `append_to_response=combined_credits` and `language=en-US` in the query) returns invented `combined_credits.cast` with movies dated 2015, 2023, undated, and TV with `first_air_date` 2016. Assert `movie_credits` titles in order 2023, 2015, undated; `tv_credits` has `media_type: :tv_show`, `title` from `"name"`, `episode_count` carried; `birthday == ~D[1979-03-02]`.
  - "collapses a title repeated per character into one credit with joined characters": two entries for movie id 9 with characters "Inés" and "Inés (voice)" → one credit, `character == "Inés / Inés (voice)"`.
  - "drops talk and news TV credits and untitled entries": TV credits with `genre_ids: [10767]` and `[10763]` and one with no `"name"` are absent.
  - "a movie and a show with the same TMDB id stay separate": movie id 500 and TV id 500 both present, one in each list.
  - "search parses known_for titles": `/tmdb/person/search` returns a result whose `known_for` holds one movie (`"title"`) and one show (`"name"`) → `known_for == ["The Salt Ledger", "Harbour Lights"]`.
  - "relay 404 is an error and is not cached": first call 404 → `{:error, _}`; a second call reaches Bypass again.
  - "to_search_result builds a TMDB SearchResult": asserts the fields listed above.
- [ ] **Step 2: Run, expect FAIL**: `./dev mix test test/mydia/metadata/people_test.exs`
- [ ] **Step 3: Implement** `Mydia.Metadata.People.fetch_person(config, tmdb_id, opts)` and `search_people(config, query, opts)` using `HTTP.new_request(config)` / `HTTP.get/3` like `Relay.search_tmdb/3`, with `include_adult: false` on search; parsing lives in `Person.from_api_response/1` and `PersonSearchResult.from_api_response/1`. The facade in `Mydia.Metadata` wraps them in `Cache.fetch/3`. Status 404 → `Error.not_found/1`, other non-200 → `Error.api_error/2`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(metadata): fetch and search people through the relay`

### Task 5: Person modal component and host helper

**Files:**
- Create: `lib/mydia_web/components/person_components.ex` (`MydiaWeb.PersonComponents`)
- Create: `lib/mydia_web/live/helpers/person_modal.ex` (`MydiaWeb.Live.Helpers.PersonModal`)
- Test: `test/mydia_web/components/person_components_test.exs`, `test/mydia_web/live/helpers/person_modal_test.exs`

**Interfaces:**
- Consumes: Task 4's `Person`, `PersonCredit.to_search_result/1`, `Metadata.fetch_person_cached/3`.
- Produces:
  - `PersonModal.init(socket)` assigns `:selected_person` (nil), `:person_stub` (nil, a `%{id, name, profile_path}` from the click), `:person_loading` (false), `:person_error` (nil), `:person_titles` ([]).
  - `PersonModal.open(socket, %{"id" => id, "name" => name, "profile_path" => path})` parses the id (an unparsable id returns the socket unchanged), assigns the stub and loading, and `start_async(socket, :load_person, fn -> Metadata.fetch_person_cached(config, id) end)` using `socket.assigns.metadata_config`. (Hosts without that assign get it added in their task.)
  - `PersonModal.retry(socket)` re-runs the fetch for `:person_stub`.
  - `PersonModal.handle_result(socket, async_result)` for `{:ok, {:ok, person}}`, `{:ok, {:error, _}}`, `{:exit, _}`: stores `:selected_person` and `:person_titles = enrich_titles(person, scope)`, or sets `:person_error` and logs.
  - `PersonModal.enrich_titles(Person.t, Scope.t) :: [SearchResult.t]`: movie then TV credits through `to_search_result/1`, `RemoteFilter.filter(scope)`, then `MediaAddHelpers.enrich_with_library_status/2` with `Map.merge(library_status_for_tmdb_ids(scope, movie_ids, "movie"), library_status_for_tmdb_ids(scope, tv_ids, "tv_show"))`, then `MediaRequestHelpers.enrich_with_request_status(MediaRequestHelpers.request_status_map())`.
  - `PersonModal.close(socket)` resets to `init` values.
  - `PersonModal.titles(socket)` returns `:person_titles`, for hosts' selectable lists.
  - `PersonComponents.person_modal/1` attrs: `id` (string), `person` (Person or nil), `stub` (map or nil), `titles` ([SearchResult]), `loading` (bool), `error` (term or nil), `escape_enabled` (bool, required: false whenever the title dialog or the configure dialog is open). Emits `close_person`, `retry_person`, and `show_details` with `phx-value-id` / `phx-value-type` (`"movie"`/`"tv_show"`) per poster.
  - Element ids: `#person-modal`, `#person-modal-error`, `#person-modal-retry`, `#person-movies`, `#person-shows`, `#person-owned-count`, poster `#person-credit-movie-<id>` / `#person-credit-tv_show-<id>`, `#person-movies-show-all`, `#person-shows-show-all`.

- [ ] **Step 1: Write the failing tests**
  - Component (`rendered_to_string` + `LazyHTML`): renders name, bio, `#person-owned-count` text "2 in your library" when two titles have `in_library: true`; an owned poster carries the check badge, an unowned one doesn't; with 30 movie credits, exactly 12 posters are visible and `#person-movies-show-all` reads "Show all 30"; a person with no TV credits has no `#person-shows`; no biography renders no bio block; `error` set renders `#person-modal-error` with `#person-modal-retry` and the stub's name.
  - Helper: `enrich_titles/2` marks movie 500 in library and leaves TV 500 not in library when only the movie row exists (Review Focus 1); for a scope with `max_content_age` set, a title `RemoteFilter` refuses is absent (use the fixtures RemoteFilter's own tests use) (Review Focus 3).
- [ ] **Step 2: Run, expect FAIL**: `./dev mix test test/mydia_web/components/person_components_test.exs test/mydia_web/live/helpers/person_modal_test.exs`
- [ ] **Step 3: Implement.** Layout per the approved mockup: a `<dialog class="modal">` at `z-[998]` (below `TrendingDetailModal`'s 999 so a title opened from a person stacks on top), header with photo, name, department/birth line, owned badge, bio clamped to 4 lines with a client-side "Read more" (`Phoenix.LiveView.JS.toggle_class`). The All / In library toggle and "Show all" are client-side (`JS`), no server round trip. `phx-window-keydown="close_person"` only when `escape_enabled`. Images via `ImageUrl.profile_url/1` and the poster helper the dashboard cards use.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(web): person popup component and host state`

### Task 6: Clickable cast in `TrendingDetailModal` (opt-in)

**Files:**
- Modify: `lib/mydia_web/live/components/trending_detail_modal.ex` (cast block, moduledoc Events section)
- Test: `test/mydia_web/live/components/trending_detail_modal_test.exs` (create or extend)

**Interfaces:**
- Produces: assign `person_event` (read with `Map.get(assigns, :person_event)`, default nil). When set, a cast member with `tmdb_person_id` renders as `<button id={"cast-person-#{id}"} phx-click={@person_event} phx-value-id phx-value-name phx-value-profile_path>` with a hover ring; one without an id renders greyed (`opacity-60`) with a daisyUI tooltip "Refresh metadata to link this person". When nil, the cast renders exactly as today.

- [ ] **Step 1: Write the failing tests**: with `person_event: "show_person"` a linked member renders `#cast-person-4242` with `phx-click="show_person"`; an unlinked member renders no button; without `person_event` no `[id^=cast-person-]` exists.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**, and document `person_event` in the moduledoc's Events section, including that a host passing it must handle that event.
- [ ] **Step 4: Run, expect PASS**, plus `./dev mix test test/mydia_web/live/admin_requests_live* test/mydia_web/live/my_requests_live*` unchanged.
- [ ] **Step 5: Commit** `feat(web): opt-in clickable cast in the title preview`

### Task 7: Wire the person popup into Discover

**Files:**
- Modify: `lib/mydia_web/live/discover_live/index.ex`, `lib/mydia_web/live/discover_live/index.html.heex`
- Test: `test/mydia_web/live/discover_live/person_modal_test.exs`

**Interfaces:**
- Consumes: Tasks 5 and 6.
- Produces: events `show_person`, `close_person`, `retry_person`; `handle_async(:load_person, ...)`; `selectable_lists/1` gains `PersonModal.titles(socket)` (as a list built from assigns: `assigns.person_titles`).

- [ ] **Step 1: Write the failing tests** (Bypass relay, as other Discover tests do): open a title, click `#cast-person-<id>` → `#person-modal` visible and `#trending-detail-modal` closed; posters render; clicking a poster opens `#trending-detail-modal` while `#person-modal` stays rendered; `close_details` leaves `#person-modal` open; adding from that title dialog marks the poster owned after the add lands; relay returns 404 → `#person-modal-error` with the clicked name, `#person-modal-retry` refetches (Review Focus 2).
- [ ] **Step 2: Run, expect FAIL**: `./dev mix test test/mydia_web/live/discover_live/person_modal_test.exs`
- [ ] **Step 3: Implement.** `show_person` calls `DetailModal.close/1` then `PersonModal.open/2` (opening a person replaces the title dialog; opening a title stacks over the person). Pass `person_event="show_person"` to `TrendingDetailModal`. `escape_enabled={is_nil(@selected_item) and not @add_config_open}` (use whatever assign Discover already passes as `config_open`). After an add or a request, refresh `:person_titles` the same way the grid is refreshed (re-enrich with the updated status maps), and keep `DetailModal.refresh_selected/2` seeing the person titles through `selectable_lists/1`.
- [ ] **Step 4: Run, expect PASS**, plus the existing `test/mydia_web/live/discover_live/` suite.
- [ ] **Step 5: Commit** `feat(discover): open people from the title preview`

### Task 8: People search scope on Discover

**Files:**
- Modify: `lib/mydia_web/live/discover_live/index.ex`, `lib/mydia_web/live/discover_live/index.html.heex`
- Test: `test/mydia_web/live/discover_live/people_search_test.exs`

**Interfaces:**
- Consumes: `Metadata.search_people_cached/3`, Task 7's `show_person`.
- Produces: URL param `scope=people` (absent means titles), assigns `:search_scope` (`:titles | :people`), `:people_results` ([PersonSearchResult]), `:people_error`. Element ids `#discover-search-scope`, `#discover-scope-titles`, `#discover-scope-people`, `#discover-people-results`, `#discover-person-<id>`.

- [ ] **Step 1: Write the failing tests**: with no query, `#discover-search-scope` is absent; after searching, it shows; choosing People patches to `?q=ventura&scope=people` and renders `#discover-people-results` with `#discover-person-501` showing name and known-for line; the poster grid, category tabs and filters are not rendered in people scope; clicking a person opens `#person-modal`; `clear_search` drops `scope`; loading `?q=ventura&scope=people` directly renders people; `?scope=people` with no `q` renders normal Discover; relay failure renders an inline error.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Parse `scope` in `handle_params` (anything but `"people"` is titles). In people scope `load_data` calls `search_people_cached(config, query)` for page 1 only (no load-more). The scope control is a daisyUI `join` of two buttons beside `#discover-search-chip`, using `push_patch`.
- [ ] **Step 4: Run, expect PASS**, plus the existing Discover suite.
- [ ] **Step 5: Commit** `feat(discover): search people`

### Task 9: Dashboard and media show page

**Files:**
- Modify: `lib/mydia_web/live/dashboard_live/index.ex` and its template (same wiring as Task 7; add the person titles to `rail_lists/1`)
- Modify: `lib/mydia_web/live/media_live/show.ex`, `show.html.heex`, `lib/mydia_web/live/media_live/show/components.ex` (cast panel), `show/helpers.ex` (`get_cast/2` carries `tmdb_person_id`), `show/detail_modal_events.ex` (`item_lists/1` includes person titles; `show_person`/`close_person`/`retry_person` delegates), `show/recommendation_events.ex`
- Test: `test/mydia_web/live/dashboard_live/person_modal_test.exs`, `test/mydia_web/live/media_live/person_modal_test.exs`

**Interfaces:**
- Consumes: Tasks 5 and 6.
- Produces: `RecommendationEvents.add_recommendation/2` and `request_recommendation/2` take the media type from the clicked item (`params["media_type"]` for add, the resolved item's `:media_type` for request), falling back to the viewed item's type. `perform_add/5` takes it via `opts[:media_type]`, default from `media_item.type`.

- [ ] **Step 1: Write the failing tests**
  - Dashboard: same open / stack / close flow as Task 7's first test.
  - Media page: the cast panel's `#cast-person-<id>` opens `#person-modal`; an unlinked actor has no button.
  - Media page, on a **movie**: open a person, open their TV credit, click Add → a `tv_show` media item with that TMDB id exists, not a movie (Review Focus 4). Same for a guest's Request: the request is recorded as `tv_show`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** In the cast panel, use the same button/greyed markup as Task 6 (extract a shared `cast_person/1` function component into `PersonComponents` and use it from both places rather than duplicating it). Make sure the media page assigns `metadata_config` if it doesn't already.
- [ ] **Step 4: Run, expect PASS**, plus `./dev mix test test/mydia_web/live/media_live test/mydia_web/live/dashboard_live`.
- [ ] **Step 5: Commit** `feat(web): people from the dashboard and the movie/show page`

### Task 10: Finish

- [ ] **Step 1:** `./dev mix precommit` (run the suite in chunks if it outruns the Bash timeout) and fix anything it raises, including gettext extraction.
- [ ] **Step 2:** `cd metadata-relay && mix test`.
- [ ] **Step 3:** Drive the real app: open a title on Discover, click a cast member, open a filmography title, add it, search People. Note in the PR that the relay routes need a `metadata-relay-v*` tag before installs can use them.
- [ ] **Step 4:** `git diff --stat origin/master...` lists only files this plan names. Commit any fixes.
