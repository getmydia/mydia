# People pages: browse by actor

Issue: #1346

## Intent

Users want to browse movies and TV shows by the people in them, as other media
managers allow. Two uses carry equal weight (maintainer's answer): wandering
from something already owned to an actor's other work, and finding titles to
add to the library. So a person view has two jobs: show what you already have
from that person, and let you add what you don't.

Web UI (LiveView) only. The Flutter player and the GraphQL schema are out of
scope.

## What the user sees

The approved mockup has three surfaces.

### 1. Person preview popup

A modal in the same style and with the same host mechanics as
`MydiaWeb.Live.Components.TrendingDetailModal`.

- Header: profile photo, name, known-for department, birth year and place when
  TMDB has them, credit count, and an "N in your library" badge.
- Biography, clamped to about four lines with a "Read more" toggle.
- Two sections, **Movies** and **Shows**, each a poster grid. Every poster
  carries the title, year and character name (shows: the episode count when TMDB
  gives one). A title already in the library carries a check badge.
- Movies has an All / In library toggle (my call, shown in the mockup and not
  objected to). Shows gets the same toggle.
- Each section shows the first 12 posters with a "Show all N" button that
  expands the grid in place.
- Clicking a poster opens that title's existing preview popup (Add to Library,
  Request for guests, Go to movie/show), so every add, request and permission
  rule stays in the one place it already lives. Closing or backing out of that
  title popup returns to the person popup.

### 2. People search on Discover

> Superseded by `2026-11-06-discover-people-tab-design.md` (#1350): People is
> now a third Discover type with a popular-people browse grid, and the scope
> toggle described below is removed.

People is a **search scope only** (maintainer's decision). It is not a third
option of Discover's page-wide Movies / TV Shows `segmented_control`
(`discover-media-type`, the `type` URL param), which drives the category tabs,
filters, "Hide in library" and paging. Instead, while a search query is active,
a scope choice beside the search box offers Titles / People, where Titles
follows the page's Movies / TV Shows switch. Choosing People replaces the
poster results with people results (first page of TMDB results only, no load
more); clearing the search
returns Discover to exactly what it showed before. There is no people browse
list and no `/person/popular` route. The scope may be carried in its own URL
param so a people search survives reload; `type` keeps its two values.

Results are round headshots with the person's name and a "known for" line (TMDB's
`known_for` titles, or the department when acting isn't their main job).
Clicking a result opens the person popup.

### 3. Clickable cast

Cast members become buttons that open the person popup, with a hover ring on
the photo, in:

- the title preview popup (`TrendingDetailModal`) on Discover and the
  dashboard;
- the movie/show page cast panel (`MydiaWeb.MediaLive.Show.Components`).

Clickable cast is a per-host opt-in on `TrendingDetailModal` (an attribute,
default off), because the modal's cast markup is shared and an event the host
doesn't handle crashes the LiveView. It stays **off on the admin requests page
and the guest My Requests page** (maintainer's decision): both swap the modal's
actions for their own request buttons through the `:actions` slot, so a title
opened from a person there would show buttons bound to the wrong request.

A cast member with no TMDB person id stays visible but greyed out and
unclickable, with a tooltip saying a metadata refresh will link it (my call).

## Goals

- All three surfaces above, on the web UI.
- Library membership shown on every title in a filmography.
- Existing libraries become clickable without the user doing anything.

## Non-goals

- Player (Flutter) and GraphQL exposure.
- A standalone `/people/:id` page. The popup is the person page. (A URL param
  that opens the popup, like Discover's existing deep links, is fine if it
  falls out naturally.)
- Crew pages (directors, writers). Crew stays as it is today.
- Storing people in the database. Person data is fetched on demand and cached
  like other metadata.
- Following a person or alerting on their new releases.

## Anti-goals

- Any direct TMDB or TVDB call from Mydia. Everything goes through
  metadata-relay.
- A second add/request path. Adds go through the existing title popup.

## How it works

### Data: cast needs a TMDB person id

`Mydia.Metadata.Structs.CastMember` holds `name`, `character`, `order` and
`profile_path` only. TMDB sends each cast entry's person `id`; it is dropped in
`MediaMetadata.parse_cast/1`.

- Add `tmdb_person_id` to `CastMember` and parse it from TMDB credits.
- Bump `MediaMetadata` `@schema_version` to 2 and add the TMDB movie and TV
  entries to `@required_versions` in `Mydia.Jobs.MetadataBackfill`, so stored
  blobs are refreshed over the following days by the existing staggered job.
  No migration: metadata is a JSON blob.

TVDB-sourced shows get their cast from TVDB `characters`, which carry TVDB
people ids, not TMDB ones. TMDB's person lookup by external id does not accept
TVDB ids. My call: when a TVDB show has a TMDB cross-reference (`external_ids`
already carries it), the relay provider also fetches that show's TMDB
`aggregate_credits` and copies person ids onto TVDB cast entries whose names
match exactly (case- and accent-insensitive). Unmatched entries stay
unclickable. The TVDB entry in `@required_versions` moves to 2 as well. If the
extra fetch proves costly, falling back to "TVDB cast is unclickable" is an
acceptable outcome; it should not block the rest.

### metadata-relay

Two new TMDB routes, shipped in the same PR as the feature, following the
existing `get "/tmdb/..."` pattern in `metadata-relay/lib/metadata_relay/router.ex`
and `MetadataRelay.Tmdb.Handler`:

- `GET /tmdb/person/search` proxies `/search/person`.
- `GET /tmdb/person/:id` proxies `/person/{id}`, with the caller passing
  `append_to_response=combined_credits` and `language`.

The relay needs a new tag and deploy before mydia instances can use them.
Older relays return 404; Mydia treats that like any other relay failure (next
section).

### Mydia side

- Provider: person search and person fetch in `Mydia.Metadata.Provider.Relay`,
  with structs for the person and their credits (structs, not maps, per project
  rules), cached through `Mydia.Metadata.Cache` like `search_cached` and
  `fetch_by_ref_cached`, keyed by language.
- Filmography: split `combined_credits.cast` into movies and TV, drop entries
  with no title, de-duplicate by TMDB id within each kind (TMDB repeats a title
  per character; the characters are joined), sort by release date, newest
  first, undated last. Talk (genre 10767) and News (10763) TV credits are
  dropped, since guest spots on those swamp an actor's Shows section (my call).
  Filmography titles go through `Mydia.Media.RemoteFilter.filter/2`, as
  Discover's results do, so restricted users see only what they could see on
  Discover.
- On the media show page, adds and requests from a filmography title use that
  title's own media type. The page's existing recommendation add path assumes
  the viewed item's type, which would add a show as a movie.
- Library badges: `Mydia.Media.library_status_for_tmdb_ids/3` already answers
  "which of these TMDB ids are in this user's library" and is what Discover
  uses. Use it for both sections and for the header count.
- UI: a person modal component beside `TrendingDetailModal`, with host-side
  state in a helper like `MydiaWeb.Live.Helpers.DetailModal`, wired into
  Discover, the dashboard and the media show page. The show page already hosts
  `TrendingDetailModal` for recommendations and franchise titles
  (`MydiaWeb.MediaLive.Show.DetailModalEvents`); the person popup reuses that
  wiring for opening filmography titles.
  Opening a title from the person popup and returning to the person is a small
  stack in that host state.
- Discover: People is a search scope (see surface 2). Its results render as a
  people grid instead of poster cards, and the page-wide media type, tabs and
  filters are untouched.

### Failure handling

- Relay down, rate-limited or too old (404 on the new routes): the person popup
  shows the header from what the cast entry already had (name, photo) and an
  inline error with a retry button. People search shows the same inline error.
- Person with no biography: the section is omitted.
- Person with no credits of one kind: that section is omitted.

## Testing

- Parser tests for `tmdb_person_id` on TMDB cast and for TVDB name matching.
- Backfill test that version-1 blobs are selected.
- Relay router tests for the two routes, matching the existing TMDB route tests.
- LiveView tests by element id: clicking a cast member opens the person popup;
  in-library titles carry the badge; the toggle filters; a cast member without
  an id renders no click target; People search renders results; relay failure
  renders the error state.
- Fixtures use invented names and titles.

## Left to the builder

- Component and module names, file split (keep each under ~500 LOC).
- Exact modal layout details within the mockup's shape and daisyUI.
- Whether "Show all" is a client-side expand or a server re-render.
