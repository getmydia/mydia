# Discover People tab and searchable unlinked cast

Issue: #1350. Builds on `2026-11-05-people-pages-design.md` (#1346) and
reverses its surface 2.

## Intent

The issue reported three failures and one suggestion.

- Two of the failures (People search on Discover, the person popup) were the
  production relay running 0.21.0, which predates the person routes. Tagging
  `metadata-relay-v0.22.0` fixed both; nothing in this spec is needed for them.
- The third, "No linked profile yet" on a cast member, is real and stays:
  cast stored before 18.beta.3 waits for the nightly `MetadataBackfill`, and
  some cast never links at all (a TVDB show with no TMDB cross-reference, a
  name TMDB spells differently, a name shared by two cast members). Those
  entries are dimmed and unclickable, and the tooltip promises a link that may
  never come.
- The suggestion: give People its own Discover tab beside Movies and TV Shows,
  with a browse grid of popular people, because people often remember a face
  before a name.

Maintainer's decisions:

- **Reverse the earlier call.** The people-pages spec made People a search
  scope only, with no browse list and no `/person/popular` route. People
  becomes a third Discover type instead, and the Titles/People scope toggle
  goes away.
- **Popular only.** One infinite-scroll grid of TMDB popular people. No
  trending list and no category tabs on People.
- **Unlinked cast opens a name search.** Clicking an unlinked cast member opens
  the People tab searching that name. The user picks the person; Mydia never
  guesses.
- **One way to build it:** People is a value of Discover's existing `type`
  param inside the existing LiveView, not a separate LiveView.

Web UI (LiveView) only. The Flutter player and the GraphQL schema are out of
scope.

## What the user sees

- Discover's Movies / TV Shows control gains a third option, **People**.
- With People selected and no query: a grid of popular people (photo, name,
  known-for line), paging in as the user scrolls.
- With a query: the people matching it, paging the same way.
- Clicking a person opens the existing person popup.
- On People, the category tabs, the filter panel, the grid density toggle and
  "hide owned" are hidden: none of them mean anything for people. The search
  box stays, with a "Search people" placeholder.
- On a movie or show page, and in the title preview on Discover and the
  dashboard, a cast member without a TMDB person id is now a link. Its tooltip
  reads "Search for {name}" and it carries a small search glyph, so it reads
  differently from a linked member, which opens the popup in place.

## How it works

### metadata-relay

- `GET /tmdb/person/popular` proxies TMDB `/person/popular`, passing `page`
  and `language` through. Declared before `get "/tmdb/person/:id"`, as
  `/tmdb/person/search` already is, and handled by a new
  `MetadataRelay.Tmdb.Handler.popular_people/1`.
- `/tmdb/person/search` already forwards every query param, so paging search
  needs no relay change.

### `Mydia.Metadata.People`

- `search_people/3` and `search_people_cached/3` take a `:page` option and
  return `{:ok, %PersonPage{results: [PersonSearchResult.t()], page: integer,
  total_pages: integer}}` (a new struct in `Mydia.Metadata.Structs`) instead of
  a bare list. Discover is the only caller.
- New `popular_people/2` and `popular_people_cached/2`, same options and return
  shape, relay-only like the rest of the module.
- TMDB popular entries carry the same `id`, `name`, `profile_path`,
  `known_for_department` and `known_for` fields as search results, so
  `PersonSearchResult.from_api_response/1` reads both.
- Cached in ETS for 24 hours, keyed by `popular` or the query, plus page and
  language.
- A missing `total_pages` is treated as the current page, so paging stops
  rather than looping.

### Discover

URL:

- `UrlParams.parse_media_type("person")` returns `:person`. Browse is
  `/discover?type=person`, search is `/discover?type=person&q=...`.
- `scope` is removed: `parse_search_scope/2`, the `:search_scope` assign, the
  `switch_search_scope` event and the Titles/People toggle all go.
- A link from 18.beta.3, `?q=...&scope=people`, is patched to
  `?type=person&q=...` in `handle_params`, so shared links keep working.
- `switch_media_type` and `clear_search` already rebuild the URL from `type`
  alone, so switching to or from People drops filters and categories without
  further handling.

Module:

- `MydiaWeb.DiscoverLive.PeopleSearch` is renamed `MydiaWeb.DiscoverLive.People`
  and owns everything people-specific: the `:people`, `:people_page`,
  `:people_has_more` and `:people_error` assigns, `load/1` (page 1),
  `load_more/1` (next page, appended) and `handle_result/2`.
- Both loads run through `start_async`, as search does today, so a slow relay
  call never blocks switching away. A result is applied only if the socket is
  still on People with the same query it was started for; anything else is
  dropped.
- `index.ex`, already over 1,300 lines, gains only dispatch clauses:
  `:load_data`, `load_more` and `handle_async` route to `People` when
  `media_type == :person`. `landing?/1` and the regional rows never apply to
  People.

Template:

- The People branch renders the existing `people_results` component, followed
  by the load-more sentinel.
- The sentinel block (the `LoadMoreSentinel` hook element, its spinner and its
  "Couldn't load more results" Retry) is extracted into a function component in
  `DiscoverComponents` and used by both the titles grid and the people grid, so
  the two cannot drift.
- A restricted viewer gets people with an empty `known_for`, the rule search
  already applies: those titles are names only, with nothing the remote filter
  can judge them by. The popup filters a person's titles when it opens, as
  today.

Errors:

- A failed first page shows the existing people error state ("The metadata
  service may be unavailable") with Retry. A failed later page shows the
  sentinel's Retry and keeps the people already shown.
- A Mydia release paired with an older relay gets a 404 from
  `/tmdb/person/popular` and lands in that same error state. Nothing crashes,
  and it clears when the relay is updated.

### Unlinked cast

`MydiaWeb.PersonComponents.cast_person/1` has three branches. Only the middle
one changes:

- `event` nil: plain, non-clickable cast, unchanged.
- `tmdb_person_id` nil: was a dimmed `div` with "No linked profile yet"; becomes
  a `<.link navigate={~p"/discover?#{%{"type" => "person", "q" => name}}"}>` with
  the "Search for {name}" tooltip and a search glyph, at full opacity.
- linked: emits `event`, unchanged.

This covers both cast that will never link and cast still waiting for the
backfill, so there is no need to run `MetadataBackfill` sooner.

## Non-goals

- Trending people, or any category tabs on People.
- Filters on People (department, gender): TMDB's popular list has none.
- Guessing a person from a name. The search result list is the disambiguation.
- Changing how or when cast is linked (`TvdbCastLink`, `MetadataBackfill`).
- The Flutter player and GraphQL.

## Testing

- Relay: router test for `/tmdb/person/popular`, including `page` passthrough.
- `People`: Bypass tests for popular and search paging, the `total_pages`
  boundary, a missing `total_pages`, and a 404 from an older relay.
- `UrlParams`: `person` parses, unknown types still fall back to movies.
- Discover LiveView:
  - the People option renders the popular grid;
  - a query on People renders search results;
  - `load_more` appends the next page and stops at the last;
  - first-page failure shows Retry, and Retry reloads;
  - a result for a query or tab the user has left is ignored;
  - category tabs, filters, density and hide-owned are absent on People;
  - a restricted viewer sees no known-for line;
  - `?q=x&scope=people` patches to `?type=person&q=x`.
- `cast_person`: an unlinked member renders the search link with the encoded
  name; linked and event-less members are unchanged.
- Existing tests that drive the Titles/People toggle are rewritten against the
  People type.

## Rollout

One PR carrying the relay route, the Mydia change, and a bump of
`metadata-relay/mix.exs` to 0.23.0 (it still reads 0.21.0; 0.22.0 was tagged
without a bump). Right after it merges, tag `metadata-relay-v0.23.0` on the
merge commit so the relay ships before any Mydia release that uses it.
