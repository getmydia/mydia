# Downloading option for the library progress filter

Issue: [#1252](https://github.com/getmydia/mydia/issues/1252)

## Problem

The `/movies` and `/tv` listings filter by progress: Missing, Partial,
Downloaded, Upcoming. An item with an active download and nothing complete on
disk has the availability state `:downloading` (the blue "Downloading" badge),
which none of those options match. `LibraryListing.filter_progress/2` compares
`status.state` to the selected value, so downloading items appear only under
"All Progress".

The requester suggested counting downloading movies as Partial. We are not
doing that: the badge already says Downloading, and for shows Partial means
"some episodes on disk", a different fact.

## Change

1. `MydiaWeb.MediaLive.Index.ListingParams`: add `"downloading" => :downloading`
   to `@progress` and `:downloading` to the `progress` field's type. URL
   parsing, `to_query/1` and the remembered per-user filter (`progress` is in
   `@remembered_keys`) all read this map, so they accept the new value
   without further edits.
2. `lib/mydia_web/live/media_live/index.html.heex`: add
   `pgettext("library progress", "Downloading")` to the progress `<select>`,
   between Partial and Downloaded. Run the gettext extract so the catalogs
   carry the new msgid.

No change to `LibraryListing`, `AvailabilityStatus` or the GraphQL schema,
which already exposes `downloading`.

## Semantics

The filter matches the badge exactly, for movies and shows alike:

- Movie: no version file and an active download. A movie that has a file and
  is downloading an upgrade stays Downloaded, because `for_movie/4` checks
  files first.
- Show: not every expected episode on disk, and at least one active download.

## Tests

- `test/mydia_web/live/media_live/listing_params_test.exs`: `progress=downloading`
  parses to `:downloading` and round-trips through `to_query/1`. Remembered
  filters are restored through `parse/2`, so this also covers a saved
  `downloading` filter.
- `test/mydia_web/live/media_live/index_test.exs`: with one downloading movie
  and one missing movie, choosing Downloading in the filter form (a
  `render_change` with `progress: "downloading"`) renders only the downloading
  movie's card (asserted by element id). URL parsing of the same value is
  covered by the `ListingParams` test above.

## Out of scope

Changing what Partial means, or adding availability states.
