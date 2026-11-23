# Movie minimum availability

## Problem

An import list added an unreleased sequel seven weeks before its theatrical
date. The hourly `all_monitored` sweep searched it within the hour and, after
three stalled attempts, grabbed a release named like a 1080p WEBRip of the new
film. No such release can exist before the film opens. The file was the
previous film in the series, relabelled: its duration matched the earlier film
to within two seconds and missed the new film's TMDB runtime by sixteen
minutes.

Nothing in Mydia stops an automatic search for a movie that cannot have been
released yet. `Mydia.Jobs.MovieSearch` never consults a release date, so a
pre-release movie is searched like any other, and fakes are the only thing
that can match.

## Goal

A movie is not searched automatically until it could plausibly be available,
by a threshold the operator chooses globally and can override per movie. A
search the user starts by hand still runs.

Out of scope: TV shows, and verifying an imported file's duration against the
metadata runtime (a separate defence against the same fake).

## Setting

`minimum_availability` takes one of three values:

| Value | A movie is eligible on or after |
| --- | --- |
| `announced` | always (today's behaviour) |
| `in_cinemas` | its theatrical release date |
| `released` | its earliest digital or physical release date |

### Global

`media.minimum_availability` in `Mydia.Config.Schema`, an `Ecto.Enum`, schema
default `:released`. It follows the layered config like every other media
field: schema default, YAML, the settings UI (DB overlay), then the
`MINIMUM_AVAILABILITY` env var, parsed in `Mydia.Config.Loader` next to
`AUTO_SEARCH_ON_ADD`. The admin settings page shows it as a select beside the
other media search defaults.

### Per movie

A nullable `media_items.minimum_availability` column (`:text`; nil means "use
the global value"), cast and validated against the three values in
`MediaItem`'s changeset. The movie page gets an override control modelled on
the existing download-audio-language override (global value shown as the
default option), plus the date the movie becomes eligible under the effective
value.

### Upgrade behaviour

Existing installs keep today's behaviour. The migration that adds the column
also inserts a `media.minimum_availability = announced` row into
`config_settings` when `media_items` already holds at least one movie, using
the pattern of `20260911131949_move_remote_access_enabled_to_config_settings`
(`ON CONFLICT (key) DO NOTHING`, binary UUID on Postgres, text on SQLite). A
fresh install has no movies at migration time, gets no row, and so uses the
`released` schema default. `down/0` removes the row and the column. The
release notes tell existing operators the setting exists and that `released`
is the recommended value.

## Release dates

TMDB `release_dates` is already requested on every movie metadata fetch
(`Mydia.Metadata.default_append_to_response(:movie)`) and today feeds only
certification. `Mydia.Metadata.Structs.MediaMetadata` gains two fields:

- `digital_release_date`: the earliest type 4 date across all regions
- `physical_release_date`: the earliest type 5 date across all regions

Both are `Date.t() | nil`, parsed from the ISO timestamps TMDB sends. The
struct's `schema_version` goes from 2 to 3. Earliest across regions is
deliberate: a digital release anywhere means real releases exist on trackers.

Movies pick the new dates up on their next scheduled metadata refresh. Until
then, and for movies TMDB has no digital or physical date for, the fallback
below applies.

## Eligibility rule

A new pure module, `Mydia.Media.MinimumAvailability`:

- `effective(item, global)`: the item's override, else the global value.
- `eligible_on(item, level)`: the `Date` the item becomes eligible, or nil for
  "eligible now, no date to wait for".
  - `announced`: nil.
  - `in_cinemas`: the theatrical `release_date`.
  - `released`: the earlier of `digital_release_date` and
    `physical_release_date`; when both are nil, theatrical `release_date` plus
    90 days (Radarr's rule, so long-released films without TMDB digital dates
    stay searchable).
  - Any level with no usable date at all: nil. A movie with no dates is never
    silently stuck.
- `available?(item, today)`: `eligible_on` is nil or not after `today`, using
  the global value from `Mydia.Config.get()`.

Search, the skip event and the movie page all call this module, so the rule
lives in one place.

## Enforcement

All enforcement is in `Mydia.Jobs.MovieSearch`:

- **`all_monitored`**: `load_monitored_movies_without_files/0` drops movies
  that are not `available?`, alongside the existing backoff and recheck
  filters. They are not searched, so they do not accrue search backoff.
- **`specific`**: before searching, an unavailable movie returns `:ok` without
  touching indexers and records a `search.skipped_unavailable` event carrying
  the effective level and the eligible date, so the event log explains the
  wait. This covers search on add, the bulk Search action, import lists,
  GraphQL, the grab-delay recheck and the client-selection requeue.
- **`upgrade`**: unchanged. The movie already has a file.

A new job arg, `ignore_availability: true`, parsed in `MovieSearch.Args`,
skips the check. Only the movie page's automatic search button
(`MydiaWeb.MediaLive.Show.SearchEvents.auto_search_download/2`) sets it.
Interactive search on the movie page does not go through the job and is
unaffected.

`Mydia.Search.queue_auto_searches/1` keeps `bypass_delay: true` and does not
set `ignore_availability`: search on add is gated.

## Testing

- `MinimumAvailability`: table tests for each level, the 90-day fallback,
  digital earlier than physical and the reverse, no dates at all, and an
  override beating the global value.
- `MediaMetadata`: parsing `release_dates` fixtures (fictional titles) with
  multiple regions and types, missing types, and malformed dates.
- `MovieSearch`: the sweep skips an unavailable movie; a `specific` job for one
  makes no indexer call and records the event; `ignore_availability` searches
  anyway; `upgrade` is unaffected.
- Migration: with movies present the `announced` row is written; on an empty
  database it is not.
- Config: the env var and YAML value resolve through the loader.
- LiveView: the admin select persists the global value; the movie page
  override persists and shows the eligible date.
