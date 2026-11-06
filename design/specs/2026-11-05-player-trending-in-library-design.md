# Player: trending in your library

## Intent

Good titles sit in a library unseen because nothing brings them back up. The
player's Home should surface titles the viewer already owns and has not watched,
picked by what is popular in the wider world right now (TMDB trending and
popular). It is a rediscovery row, not a shopping list.

## Goals

- Two new Home rows in the player: **Trending movies** and **Trending shows**
  (split like Recently Added), each listing only titles the viewer can play
  from a server in scope.
- Each server supplies its own list. Mydia does in this change; Plex and
  Jellyfin can join later if they have a native equivalent.
- Rows stay useful on small libraries: the server digs past the first page of
  trending into popular lists until it has enough owned matches.

## Non-goals

- Requesting, adding or downloading titles from these rows. Tapping a card
  behaves exactly like any other Home card (opens the item / plays).
- Personalised recommendations ("because you watched X"). This is world
  popularity intersected with the library, nothing more.
- Aggregating popularity across Mydia installs, or within one server's users.
- Changes to the web dashboard's existing trending rails.

## Anti-goals

- Showing a title the viewer cannot play (not owned, no files, outside their
  library access or certification ceiling).
- Showing a title this viewer has already fully watched.
- A row of one or two stragglers on Home.
- The player calling metadata-relay or TMDB directly. The server does it.

## Decided (by the user)

- Source of "popular": the wider world (TMDB trending/popular), not usage on
  Mydia servers.
- Owned titles only.
- Fully watched titles are hidden.
- When trending alone yields too few owned matches, dig deeper into more
  trending pages and TMDB popular.
- Each server provides its own list; the player treats it as an optional
  per-source capability. Plex/Jellyfin supported if and when they have one.
- Movies and shows are separate rows.
- Matching is by TMDB id only. Shows sourced from TVDB get their TMDB id from
  TVDB's cross-references; on the production instance (2026-11-05) 71 of 76
  shows and 371 of 372 movies have one, and the 5 shows without are obscure
  older children's series that would never trend. No TVDB/IMDb matching, no
  relay changes.

## Server (Mydia)

- New GraphQL query, e.g. `trendingInLibrary(type: MediaType!, first: Int)`,
  returning `[RecentlyAddedItem]` (the item shape Home already consumes, with
  `watchStatus`, artwork and external ids). Final naming is the builder's.
- Built from what `Mydia.Metadata` already fetches through metadata-relay:
  `fetch_curated_list(:trending, ...)` then `:popular`, page by page, for the
  requested media type. Results are TMDB ids, matched to `media_items` by
  `tmdb_id` through the request's `current_scope` (so library access and
  certification restrictions apply exactly as for `unwatched`), with files.
- Drop items this user has fully watched (same source as the `unwatched`
  resolver: `Playback.list_user_progress(user.id, watched: true)`). For shows,
  "fully watched" means every episode with files is watched.
- Order: TMDB rank (trending before popular, then position in list). Each
  item carries that rank in a new field (e.g. `trendingRank: Int`) so the
  player can order a merged multi-server row globally. Every Mydia server
  reads the same relay lists, so ranks are comparable across servers.
- Stops when it has `first` matches (default 20) or hits a page cap.
- Relay failure: return an error the player can treat as "this row is
  unavailable", never a crash of the Home query set.
- Any new GraphQL field passes the Rust SDL parity gate
  (`lib/mydia_web/schema/README.md`).

## Player

- New optional capability in `player/lib/core/sources/capabilities.dart`,
  e.g. `abstract interface class Trending { Future<List<ItemSummary>>
  trending(MediaKind kind); }`, plus a matching `SourceCapability` value. Mydia
  implements it via the new query; Plex, Jellyfin and Stash do not list it.
- Mydia servers too old to have the query: Mydia's capability set is a
  `const` (`mydia_source.dart`), so keep listing the capability and treat the
  "Cannot query field" downgrade (`schema_downgrade.dart`) as an empty list.
  The row is then hidden, as it is for any too-short list.
- Home (`home_rows.dart`, `home_rows_provider.dart`): two new rows fed per
  server like Recently Added. Across servers, sort by `trendingRank`
  (a new merge helper; `mergeNewest`/`mergeAlphabetical` don't fit), and
  otherwise follow the existing merge rules (duplicates collapse to one card
  with `extraCopies`, cards name their server when 2+ servers are in scope). A server that fails the trending call
  just contributes nothing; it never marks the server unavailable or blocks
  Home loading.
- Strings localised in all shipped ARB files.

## Builder's calls (mine, not the user's; adjust freely)

- Multi-server ordering via a `trendingRank` field on each item (one schema
  field plus SDL parity stubs) rather than interleaving servers by position.
- Row size target 20 per type; hide a row with fewer than 5 cards after
  merging.
- Page cap: up to 3 pages of trending (week window) then up to 5 of popular
  per type, reusing `Mydia.Metadata.Cache`'s 30-minute curated-list TTL. Cache
  the per-user intersection briefly or not at all; correctness over speed.
- In-progress titles stay in the row (they are not "forgotten" but they are
  not watched either).
- Placement: after Continue Watching and Recently Added, before Favorites and
  library rows.
- Row titles: "Trending movies" and "Trending shows" (the player only shows
  owned titles anywhere, so "in your library" is implied).
- Plex and Jellyfin get no implementation in this change. As far as I can
  tell, Plex's trending lives in its Discover cloud catalogue, not on the
  server, and Jellyfin has no trending list; revisit if that proves wrong.

## Constraints

- Metadata always via metadata-relay; no TMDB keys in the server or player.
- SQLite and PostgreSQL both supported; no new migration is expected.
- Never use real movie/TV titles in tests or fixtures.
