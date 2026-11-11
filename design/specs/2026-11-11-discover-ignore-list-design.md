# Discover ignore list

Issue: #1379. Mockup: https://claude.ai/artifact/JN3wp2oTT3tRoEAu5e8Mw1

## Goal

Let a user mark Discover titles they will never want, so browsing surfaces new
titles instead of the same uninteresting ones every visit.

Success means an ignored title no longer appears in Discover's browse grid or
regional rows, the grid still fills a full page, and the user can always find
the title again and undo the ignore.

## Decisions

- **Per user.** Like `discover_hide_owned`, ignores belong to the user who made
  them. An admin's ignores never hide titles from a requester.
- **Browsing only.** Ignored titles are hidden from the category grid and the
  regional rows. Search results, the recommendations rail in the detail modal,
  and the person modal's titles still show them, badged, so a deliberate search
  can always reach one.
- **Undo through a toggle, not a page.** A "Show ignored (N)" toggle next to
  "Hide in library" puts ignored titles back in the grid, dimmed, with an
  Unignore action. The toggle is a persisted user preference.
- **Ignore from the card and from the detail modal.**
- **A dedicated table**, not a list inside the preferences JSON. The preferences
  blob would grow without bound and rewrite on every ignore, and two tabs would
  lose writes.

Out of scope: the Flutter player (its GraphQL "discovery" queries are about the
library, not TMDB Discover), the Dashboard, a management page, and storing
title snapshots.

## Data

Migration (real timestamp, checked for collisions across remote branches)
creating `discover_ignored_titles`:

| column        | type                                                   |
| ------------- | ------------------------------------------------------ |
| `id`          | primary key                                            |
| `user_id`     | references `users`, `on_delete: :delete_all`, not null |
| `media_type`  | `:text`, not null, `"movie"` or `"tv_show"`            |
| `provider`    | `:text`, not null, `"tmdb"` or `"tvdb"`                |
| `provider_id` | `:integer`, not null                                   |
| `inserted_at` | `:utc_datetime`                                        |

Unique index on `(user_id, media_type, provider, provider_id)`. `media_type` is
part of the key because TMDB numbers movies and TV separately: the same id can
name one of each. Portable on SQLite and PostgreSQL; no `:string` columns.

No title, year or poster is stored. Every ignored title a user sees comes from a
live provider page, so there is nothing to render from a snapshot.

## Context

Schema `Mydia.Accounts.IgnoredDiscoverTitle`, with a changeset that checks
`media_type` and `provider` against allowlists.

In `Mydia.Accounts`, next to the other per-user Discover state:

- `ignore_discover_title(user, %SearchResult{})` builds the key from
  `Mydia.Metadata.Ref.from_search_result/1` and `media_type`, then inserts with
  `on_conflict: :nothing`. Idempotent, so a double click or a second tab is
  harmless.
- `unignore_discover_title(user, ref, media_type)` deletes by key. Also
  idempotent.
- `ignored_discover_keys(user)` returns a `MapSet` of `{media_type, ref}`.

`Mydia.Accounts.UserPreference` gains `discover_show_ignored` (default `false`,
boolean validation, accessor `discover_show_ignored/1`), handled the same way as
`discover_hide_owned`.

## Discover LiveView

`index.ex` is already 1,331 lines, past the ~500 LOC guideline. The new event
handlers and helpers live in `lib/mydia_web/live/discover_live/ignores.ex`, the
same split `People` uses; `index.ex` only delegates.

Assigns:

- `ignored_keys`: the MapSet, loaded at mount. Empty with no `current_user`, and
  then no ignore UI renders at all.
- `show_ignored`: from the preference.
- `ignore_toast`: the last ignored title, or nil.

Filtering:

- `assign_visible_items/1` also drops ignored items when not in search mode and
  `show_ignored` is off.
- `filtering?/1` also counts "has ignores and is hiding them", so
  `maybe_auto_advance/3` keeps fetching pages until the grid holds a full page,
  as it does for "Hide in library".
- `regional_rows` takes one shared predicate (owned-and-hidden or
  ignored-and-hidden) in place of its inline `hide_owned` reject, so the grid
  and the rows cannot disagree.

Events, all of which check the ref with `Ref.parse/1` and the type against an
allowlist, so a forged param does nothing:

- `ignore_title`: write, add to `ignored_keys`, recompute visible items,
  auto-advance, set the toast. If it came from the detail modal, close the
  modal.
- `unignore_title`: delete, remove from `ignored_keys`, recompute, clear the
  toast if it named this title.
- `toggle_show_ignored`: persist through `persist_preference/3`, then recompute.
- A rejected write leaves the grid as it was and shows an error flash, matching
  `toggle_hide_owned`.

The toast reads "Ignored *Title* · Undo", where Undo sends `unignore_title`. A
newer ignore replaces it, and it clears after 8 seconds through
`Process.send_after/3`, tagged with the title so a stale timer cannot clear a
newer toast.

## Components

- `trending_card/1` gains an optional `ignore_event` attr and an `ignored`
  attr. Only Discover passes them, so the Dashboard and the other callers
  render exactly as now.
  - With `ignore_event` set and the item not in the library: an eye-slash icon
    button with `aria-label` in the top-right corner, shown on hover or focus
    on desktop and always on touch. Owned cards keep the in-library badge
    there and get no button: ignoring an owned title is pointless.
  - With `ignored` true: an "Ignored" badge in the top-left corner (where the
    rating badge usually sits), the poster dimmed, and an Unignore button in
    place of Add.
  - Stable ids: `discover-ignore-<ref param>` and
    `discover-unignore-<ref param>`.
- `TrendingDetailModal` gains an Ignore or Unignore button beside Add, which
  sends the event to the parent LiveView.
- The toolbar gains `#discover-show-ignored`, a daisyUI `toggle toggle-sm`
  labelled "Show ignored (N)", rendered only when N > 0 and the media type is
  not People.
- All new copy goes through gettext.

## Testing

- `test/mydia/accounts/ignored_discover_titles_test.exs`:
  - Ignoring twice keeps one row.
  - Unignoring a title that isn't ignored is a no-op.
  - The same TMDB id as a movie and as a TV show gives two keys.
  - One user's ignores don't appear in another user's set.
  - Deleting a user cascades to their rows.
  - A bad provider or media type is rejected.
- A `UserPreference` test that `discover_show_ignored` defaults to false and
  rejects non-booleans.
- `test/mydia_web/live/discover_live/ignore_test.exs`, using the existing
  Discover stubs (as `hide_owned_test.exs` does) and fictional titles:
  - Ignoring removes the card and shows the toast.
  - Undo restores the card.
  - An ignored title stays hidden after a remount.
  - The grid auto-advances when ignoring empties most of a page.
  - Regional rows drop ignored titles.
  - Search shows an ignored title with its badge and Unignore.
  - Show ignored dims ignored cards and survives a remount.
  - A forged ref param changes nothing.
  - The modal's Ignore button closes the modal and hides the card.
- Manual: button visibility at phone width and on hover, in the running app.
