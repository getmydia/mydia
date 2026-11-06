# Discover People Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Discover a People type with a popular-people grid and paged people search, and turn unlinked cast members into a name search.

**Architecture:** One new relay route (`/tmdb/person/popular`). `Mydia.Metadata.People` gains paging and a popular list, both returning a `PersonPage` struct. Discover treats `?type=person` as a third media type; everything people-specific lives in `MydiaWeb.DiscoverLive.People` (renamed from `PeopleSearch`), and `index.ex` only dispatches to it. The Titles/People scope toggle and `?scope=` are removed.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Plug (relay), Bypass, LazyHTML.

**Spec:** `design/specs/2026-11-06-discover-people-tab-design.md`

## Global Constraints

- All TMDB access goes through metadata-relay; never call TMDB from Mydia.
- No real movie, TV or person names in code, tests or fixtures; invent them.
- No em dashes in code comments, copy or docs.
- User-facing strings go through `gettext`.
- Run Mix through `./dev mix ...`; commit with `git commit -F <file>` from the direnv-loaded worktree (unique `/tmp/msg-people-tab-<n>.txt` filenames), stage every intended path first, and check `git show --stat` after each commit.
- The relay is a separate Mix project: its tests run with `cd metadata-relay && mix test ...` inside the devenv shell (`./dev bash` then the command), not `./dev mix`.

## Review Focus

1. **Popular list shifting between pages.** TMDB's popular ranking moves, so page 2 can repeat a person from page 1. Expected: no duplicate cards and no duplicate DOM ids. Pinned in Task 4 (`load_more drops people already shown`).
2. **A result landing after the user left People.** Switching to Movies while a people page is in flight must not write people into the titles view or flip `:loading`. Pinned in Task 4 (`a people result after switching to Movies is ignored`).
3. **A name with characters that need URL encoding** (`&`, `#`, accents) on an unlinked cast link. Expected: the search box shows the exact name. Pinned in Task 5.
4. **A beta.3 link `?q=x&scope=people`.** Expected: lands on `?type=person&q=x`, not on a titles search. Pinned in Task 4.
5. **Relay without the popular route (404).** Expected: People shows the error with Try again, not a crash or an empty "No people found". Pinned in Tasks 2 and 4.

---

### Task 1: Relay route for popular people

**Files:**
- Modify: `metadata-relay/lib/metadata_relay/router.ex` (beside `get "/tmdb/person/search"`, ~line 200)
- Modify: `metadata-relay/lib/metadata_relay/tmdb/handler.ex` (beside `search_people/1`, ~line 198)
- Modify: `metadata-relay/mix.exs` (`version: "0.21.0"` to `"0.23.0"`)
- Test: `metadata-relay/test/metadata_relay/tmdb/handler_test.exs`, `metadata-relay/test/metadata_relay/cache_test.exs`

**Interfaces:**
- Produces: `GET /tmdb/person/popular`, query params passed through verbatim to TMDB `/3/person/popular`; body returned verbatim (`page`, `results`, `total_pages`, `total_results`).

- [ ] **Step 1: Write the failing tests** in a new `describe "GET /tmdb/person/popular"` after the person search block, reusing `person_search_fixture/0` and `TMDBHelpers` exactly as the search tests do:
  - `"dispatches to the handler and returns the TMDB body verbatim"`: route `"/3/person/popular" => {200, fixture}`, `GET /tmdb/person/popular`, assert 200 and body == fixture.
  - `"forwards language and page to TMDB"`: capture the request as the search forwarding test does; `GET /tmdb/person/popular?language=fr-FR&page=3`; assert `url.path == "/3/person/popular"` and the query contains `language=fr-FR` and `page=3`.
  - In `cache_test.exs`: `assert MetadataRelay.Cache.ttl_for("GET:/tmdb/person/popular:page=1") == :timer.hours(24 * 3)` (the existing `/tmdb/person/` rule; no cache change needed).

- [ ] **Step 2: Run to verify failure**
  Run: `./dev bash` then `cd metadata-relay && mix test test/metadata_relay/tmdb/handler_test.exs test/metadata_relay/cache_test.exs`
  Expected: the popular tests FAIL with 404 / no route; cache test passes already.

- [ ] **Step 3: Implement**
  - Handler: `def popular_people(params), do: Client.get("/person/popular", params: params)` with a `@doc` matching its neighbours.
  - Router: `get "/tmdb/person/popular"` using `extract_query_params/1` and `handle_tmdb_request/2`, placed directly after the search route and before `/tmdb/person/:id`; update the comment above search to say both must precede `:id`.
  - Bump `mix.exs` version to `0.23.0`.

- [ ] **Step 4: Run to verify pass** (same command). Expected: all PASS.

- [ ] **Step 5: Commit** `feat(relay): proxy TMDB popular people` with the four files.

---

### Task 2: Paged people search and popular people in `Mydia.Metadata.People`

**Files:**
- Create: `lib/mydia/metadata/structs/person_page.ex`
- Modify: `lib/mydia/metadata/people.ex`
- Test: `test/mydia/metadata/people_test.exs`

**Interfaces:**
- Produces:
  - `%Mydia.Metadata.Structs.PersonPage{results: [PersonSearchResult.t()], page: pos_integer(), total_pages: pos_integer()}` with `@type t`, plus `PersonPage.more?(page) :: boolean` (`page.page < page.total_pages`).
  - `People.search_people(config, query, opts) :: {:ok, PersonPage.t()} | {:error, Error.t()}` and `People.search_people_cached/3` (same return). Opts: `:page` (default 1), `:language`.
  - `People.popular_people(config, opts) :: {:ok, PersonPage.t()} | {:error, Error.t()}` and `People.popular_people_cached/2`. Same opts. Relay-only: non-relay config returns `{:error, relay_only(type)}`.
  - Cache keys: `"person_search:metadata_relay:#{query}:#{language}:#{page}"` and `"person_popular:metadata_relay:#{language}:#{page}"`, both `ttl: :timer.hours(24)`. Errors are not cached (as today).

- [ ] **Step 1: Write the failing tests** in `people_test.exs` (update the existing `"search parses known_for titles"` to the new key and return shape: `{:ok, %PersonPage{results: [%PersonSearchResult{} = result], page: 1, total_pages: 1}}`):
  - `"search passes page and reads total_pages"`: Bypass asserts `params["page"] == "2"`, replies `%{"page" => 2, "total_pages" => 5, "results" => [...]}`; assert `page: 2, total_pages: 5` and `PersonPage.more?/1` is true.
  - `"popular people parse like search results"`: Bypass `GET /tmdb/person/popular`, asserts `params["page"] == "1"` and `params["language"] == "en-US"`; one result with `known_for`; assert the parsed `tmdb_id`, `known_for` and `total_pages`.
  - `"a missing total_pages ends paging"`: reply without `total_pages` for page 3; assert `total_pages == 3` and `more?` false.
  - `"popular 404 is an error and is not cached"`: counter as in the existing person 404 test, two calls, counter == 2.
  - Extend `"non-relay config is rejected"` with `People.popular_people_cached(%{type: :tvdb})`.
  - Each test deletes its cache keys in `on_exit`, using unique queries/pages like the existing tests.

- [ ] **Step 2: Run to verify failure**
  Run: `./dev mix test test/mydia/metadata/people_test.exs`
  Expected: FAIL (undefined `PersonPage`, `popular_people_cached`).

- [ ] **Step 3: Implement**
  - `PersonPage` struct and `more?/1`.
  - In `People`, one private `fetch_page(config, path, params)` used by both `search_people/3` (`/tmdb/person/search`, params `query`, `language`, `include_adult: false`, `page`) and `popular_people/2` (`/tmdb/person/popular`, params `language`, `page`): the existing result filtering and `PersonSearchResult.from_api_response/1` mapping, `page` from the body falling back to the requested page, `total_pages` from the body falling back to the page. A 200 without a `results` list is an empty page; non-200 is `Error.api_error/2` as today.

- [ ] **Step 4: Run to verify pass** (same command). Expected: PASS. Then keep Discover working until Task 4 replaces it: in `DiscoverLive.PeopleSearch.put_result/2`, match `{:ok, %PersonPage{results: people}}`, and run `./dev mix test test/mydia_web/live/discover_live/people_search_test.exs` (update its two cache keys to the new `...:#{language}:1` form). Expected: PASS.

- [ ] **Step 5: Commit** `feat(metadata): page people search and fetch popular people` with the struct, `people.ex`, `people_search.ex` and both test files.

---

### Task 3: Shared load-more sentinel component

Pure extraction; the titles grid behaves exactly as before.

**Files:**
- Modify: `lib/mydia_web/components/discover_components.ex` (new component)
- Modify: `lib/mydia_web/live/discover_live/index.html.heex` (the `discover-load-more` block, ~lines 365-399)
- Test: `test/mydia_web/components/discover_components_test.exs` (create if absent; follow `person_components_test.exs` for `render_component` + `LazyHTML`)

**Interfaces:**
- Produces: `DiscoverComponents.load_more_sentinel/1` with attrs `id :string, required`, `has_more :boolean, required`, `loading_more :boolean, required`, `error? :boolean, required`, `event :string, default "load_more"`. Renders the `LoadMoreSentinel` hook element with `id={@id}`, `data-event={@event}`, `data-has-more={to_string(@has_more and not @loading_more and not @error?)}`; error row id `"#{@id}-error"` with a Retry button id `"#{@id}-retry"` and `phx-click={@event}`; spinner when `@has_more`. Copy unchanged ("Couldn't load more results.", "Retry"). Keep the explanatory HEEx comment.

- [ ] **Step 1: Write the failing tests**:
  - `"has more and idle arms the hook"`: `data-has-more == "true"`, spinner present, no `#x-error`.
  - `"in flight or failed disarms the hook"`: `loading_more: true` gives `"false"`; `error?: true` gives `"false"` and `#x-retry` with `phx-click == "load_more"`.
  - `"custom event is carried on the hook and Retry"`: `event: "more_people"` appears in `data-event` and the retry `phx-click`.

- [ ] **Step 2: Run to verify failure**: `./dev mix test test/mydia_web/components/discover_components_test.exs` (FAIL, undefined function).

- [ ] **Step 3: Implement** the component, then replace the template block with `<.load_more_sentinel id="discover-load-more" has_more={@has_more} loading_more={@loading_more} error?={@load_error != nil} />`.

- [ ] **Step 4: Run** the component test plus `./dev mix test test/mydia_web/live/discover_live/` . Expected: PASS (ids `discover-load-more`, `discover-load-more-error`, `discover-load-more-retry` unchanged).

- [ ] **Step 5: Commit** `refactor(web): share Discover's load-more sentinel`.

---

### Task 4: People as a Discover type

**Files:**
- Rename: `lib/mydia_web/live/discover_live/people_search.ex` to `lib/mydia_web/live/discover_live/people.ex` (`MydiaWeb.DiscoverLive.People`)
- Modify: `lib/mydia_web/live/discover_live/url_params.ex`, `index.ex`, `index.html.heex`
- Modify: `lib/mydia_web/components/discover_components.ex` (`people_results/1` error copy)
- Rename + rewrite: `test/mydia_web/live/discover_live/people_search_test.exs` to `test/mydia_web/live/discover_live/people_test.exs`
- Test: `test/mydia_web/live/discover_live/url_params_test.exs` if it exists, else cover parsing in `people_test.exs`

**Interfaces:**
- Consumes: Task 2 `People.search_people_cached/3`, `People.popular_people_cached/2`, `PersonPage`; Task 3 `load_more_sentinel/1`.
- Produces:
  - `UrlParams.parse_media_type("person") :: :person`. `parse_search_scope/2` is deleted.
  - `DiscoverLive.People`:
    - `reset(socket)`: assigns `people: []`, `people_page: 0`, `people_has_more: false`, `people_loading_more: false`, `people_error: nil` (first-page failure), `people_more_error: nil` (later-page failure).
    - `params(query) :: map`: `%{"type" => "person"}` for `""`, else adds `"q"`.
    - `load(socket)`: page 1, sets `:loading` true, `start_async(:people, fn -> {query, 1, fetch(config, query, 1)} end)`; `fetch` calls `popular_people_cached` for `""`, else `search_people_cached` with `page:`.
    - `load_more(socket)`: no-op unless `people_has_more and not people_loading_more`; else page `people_page + 1`, sets `people_loading_more` true and clears `people_more_error`.
    - `handle_result(socket, async_result)`: ignored unless `media_type == :person` and `search_query` equals the result's query. Page 1 `{:ok, page}` replaces; later pages append, dropping any `tmdb_id` already shown. Sets `people_page`, `people_has_more` (`PersonPage.more?/1`), clears `:loading` / `people_loading_more`. Errors: page 1 sets `people_error`, later pages set `people_more_error`; both log a warning. Restricted viewers get `known_for: []` (existing rule). `{:exit, reason}` is treated as an error for the in-flight page.
  - `index.ex`: `handle_async(:people, result, socket)` delegates; `handle_info(:load_data, %{assigns: %{media_type: :person}})` calls `People.load/1`; `handle_event("load_more", ...)` calls `People.load_more/1` when `media_type == :person`; `"retry_people_search"` calls `People.load/1` when `:person`. `"switch_search_scope"` is deleted. `"search"` with `:person` patches to `People.params(query)`.
  - `handle_params`: if `params["scope"] == "people"` and `q` is non-empty, `push_patch(socket, to: ~p"/discover?#{People.params(q)}", replace: true)` and return. For `media_type == :person`: assign `category: :trending`, `categories: []`, `regional_rows: %{}`, `regional_sources: []`, `source: nil`; skip genre loading and `landing?`; call `People.reset/1`; `send(self(), :load_data)`.

- [ ] **Step 1: Write the failing tests** by rewriting the old file as `MydiaWeb.DiscoverLive.PeopleTest`, keeping its setup, Bypass helpers and invented names, and replacing scope tests with:
  - `"People is a third media type"`: `live(conn, ~p"/discover")`, click the `discover-media-type` People option, `assert_patched(view, ~p"/discover?type=person")`, `render_async`, popular grid `#discover-people-results` has `#discover-person-501`.
  - `"People hides title controls"`: on `?type=person`, refute `[role=tablist]`, `#discover-filter-form`, `#discover-density-toggle`, `#discover-hide-owned`, `#discover-search-scope`; search input placeholder is "Search people".
  - `"searching on People pages people"`: submit `#discover-search-form` with `@query`, `assert_patched(view, ~p"/discover?q=#{@query}&type=person")`, results show; Bypass for search asserted `page == "1"`.
  - `"load_more appends the next page and stops at the last"`: popular stub returns page 1 (`total_pages: 2`, person 501) and page 2 (person 502); `render_hook(view, "load_more", %{})` then `render_async`; both cards present; `#discover-people-load-more` has `data-has-more="false"`.
  - `"load_more drops people already shown"`: page 2 repeats 501 plus 503; exactly one `#discover-person-501`.
  - `"a people result after switching to Movies is ignored"`: popular stub blocks on a message from the test (`receive`) before answering; switch to Movies; release the stub; `render_async`; refute `#discover-people-results` and the titles grid renders.
  - `"a failed first page offers Try again"`: adapt the existing relay-failure test to `?type=person` (popular 404 then 200).
  - `"a failed later page keeps people and offers Retry"`: page 2 returns 404; `#discover-people-load-more-retry` present, `#discover-person-501` still present.
  - `"a beta.3 scope link lands on the People type"`: `live(conn, ~p"/discover?q=#{@query}&scope=people")` then `assert_patch(view, ~p"/discover?q=#{@query}&type=person")`.
  - Keep, adapted to `?type=person&q=...`: department fallback, restricted viewer, popup opens, new query replaces results, clearing search returns to the popular grid on `?type=person`.
  - `UrlParams`: `"person"` parses to `:person`; `"bogus"` still `:movie`.

- [ ] **Step 2: Run to verify failure**: `./dev mix test test/mydia_web/live/discover_live/people_test.exs`.

- [ ] **Step 3: Implement** per the Interfaces block. Template changes:
  - Header subtitle and search placeholder/aria-label gain a `:person` case: "Find people and the titles they appear in" and "Search people" (use `case @media_type`).
  - `discover-media-type`: add `<:option value="person" label={gettext("People")} icon="hero-user-group" />`.
  - Every `@search_scope != :people` becomes `@media_type != :person`; delete the `discover-search-scope` join. The category tablist block renders only when `@media_type != :person`; the search chip still renders on People.
  - The results `cond` branch `@search_scope == :people` becomes `@media_type == :person`, rendering `people_results` and, when `@people != []` and `@people_error == nil`, `<.load_more_sentinel id="discover-people-load-more" has_more={@people_has_more} loading_more={@people_loading_more} error?={@people_more_error != nil} />`.
  - `people_results/1` error copy: "Could not load people. The metadata service may be unavailable." (update its `@doc`).
  - Grep `lib/` and `test/` for `search_scope`, `PeopleSearch`, `scope=people`, `switch_search_scope` and remove every remaining use.

- [ ] **Step 4: Run** `./dev mix test test/mydia_web/live/discover_live/ test/mydia/metadata/people_test.exs` and `./dev mix compile --warnings-as-errors`. Expected: PASS, no warnings.

- [ ] **Step 5: Commit** `feat(web): People is a Discover type with a popular grid` (stage the renames with `git add -A lib/mydia_web/live/discover_live test/mydia_web/live/discover_live` plus the components file).

---

### Task 5: Unlinked cast opens a people search

**Files:**
- Modify: `lib/mydia_web/components/person_components.ex` (`cast_person/1`, the `is_nil(@person_id)` branch, ~lines 243-254)
- Test: `test/mydia_web/components/person_components_test.exs`, `test/mydia_web/live/components/trending_detail_modal_test.exs` (~line 353)

**Interfaces:**
- Produces: an unlinked member with a non-nil `event` renders `<.link navigate={~p"/discover?#{%{"type" => "person", "q" => @member.name}}"} id={"#{@id_prefix}-search-#{@index}"}>` with class `[cast_person_class(@layout), "group tooltip"]`, `data-tip={gettext("Search for %{name}", name: @member.name)}`, full opacity, and `cast_person_body ... hover`. The body gains a small `hero-magnifying-glass` glyph (`w-3 h-3`, `aria-hidden`) beside the name only in this branch (pass a `search` boolean attr to `cast_person_body`, default false).

- [ ] **Step 1: Write the failing tests**: replace `"event without an id renders greyed with a tooltip and no button"` with:
  - `"an unlinked member links to a people search"`: `href == "/discover?q=An+Actor&type=person"` (assert on `URI.decode_query(URI.parse(href).query)` equals `%{"q" => "An Actor", "type" => "person"}`), id `cast-person-search-0`, `data-tip == "Search for An Actor"`, no `.opacity-60`, no `button`.
  - `"an unlinked name with reserved characters round-trips"`: name `"Zoë & Ash #2"`; decoded `q` equals the name exactly.
  - In `trending_detail_modal_test.exs`, the linked/unlinked test: `[id^=cast-person-]` count becomes 2 (one button, one `cast-person-search-*` link) and the `.opacity-60` assertion becomes `refute`.

- [ ] **Step 2: Run to verify failure**: `./dev mix test test/mydia_web/components/person_components_test.exs test/mydia_web/live/components/trending_detail_modal_test.exs`.

- [ ] **Step 3: Implement** per the Interfaces block. Remove the now-unused "No linked profile yet" msgid by running `./dev mix gettext.extract --merge` if the repo's gettext README says catalogs are maintained that way (read `lib/mydia_web/gettext/README.md` first).

- [ ] **Step 4: Run** the same tests plus `./dev mix test test/mydia_web/live/dashboard_live/person_modal_test.exs test/mydia_web/live/media_live/`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(web): an unlinked cast member opens a people search`.

---

### Task 6: Full verification and PR

- [ ] **Step 1:** `./dev mix precommit` in foreground chunks if it exceeds the 600 s tool limit (format, compile, credo, the suite). Fix anything in files this branch touched.
- [ ] **Step 2:** Relay suite: `./dev bash`, `cd metadata-relay && mix test`. Expected: PASS.
- [ ] **Step 3:** `git diff --stat origin/master...HEAD`; every file must be one this plan names (plus gettext catalogs). Anything else is a stale-read tell: investigate before continuing.
- [ ] **Step 4:** Drive the real app (`./dev up -d`, then `/discover?type=person` in a browser): popular grid loads, scrolling pages in, a search works, a person opens the popup, and an unlinked cast member on a TVDB show page opens the search. Note that locally the relay is production 0.22.0, so the popular grid shows the error state until 0.23.0 ships; point the dev relay URL at a local relay (`cd metadata-relay && mix run --no-halt`) to see it work.
- [ ] **Step 5:** With the user's go-ahead: push `HEAD:discover-people-tab`, open the PR (`Fixes #1350`), babysit CI and CodeRabbit, merge by hand. After merge, tag `metadata-relay-v0.23.0` on the merge commit and confirm `https://relay.mydia.dev/tmdb/person/popular` returns 200.
