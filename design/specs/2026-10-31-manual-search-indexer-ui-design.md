# Manual search: indexer badge, merged trackers and filter chips

Issue: #1311. Three defects in the manual search dialog, all reported by the
same tester, fixed together in one PR.

## Problems

1. **Long indexer label overflows into the download button.** From `lg` the
   indexer column is `9rem` (`@row_grid` in
   `lib/mydia_web/live/media_live/show/manual_search_components.ex`). The
   column `div` carries `truncate`, but the badge inside is `inline-flex` with
   no width cap, so its label never truncates and spills into the next column.
   Seen with `TorrentDownload +1`.
2. **Only the winning tracker's page is reachable on a merged release.**
   `Mydia.Indexers.ResultDedup.merge_duplicates/1` keeps the best copy and
   records the other trackers' *names* in `SearchResult.indexers`, discarding
   their `info_url`s. The badge can only link to the winner.
3. **Active filter chips crush the indexer status card.** From `lg`,
   `modals.ex` lays the status card (`min-w-0 flex-1`, flex-basis 0) beside the
   chips container (flex-basis auto). The chips claim their max-content width
   first, so with several filters (one indexer chip joins every selected name)
   the status summary is squeezed to about 80px and its text and badges stack
   unreadably.

## Design

### 1. Badge truncation

In `indexer_badge/1`:

- The badge gets `max-w-full min-w-0`.
- The label is wrapped in `<span class="truncate">`.
- The external-link icon gets `shrink-0` so it stays visible.
- `title` still carries the full tracker list (or the single-tracker "View
  this release on …" text), so the truncated text stays discoverable.

### 2. Per-tracker sources

**Data.** New struct `Mydia.Indexers.SearchResult.Source` in
`lib/mydia/indexers/search_result/source.ex`:

```elixir
defstruct [:indexer, :info_url]
```

`SearchResult` replaces the `indexers: [String.t()]` field with
`sources: [Source.t()]`, default `[]`. This is a clean break: `SearchResult` is
an in-memory struct that is never serialized or persisted.

- `SearchResult.sources/1` returns `sources` when non-empty, otherwise
  `[%Source{indexer: result.indexer, info_url: result.info_url}]`.
- `SearchResult.indexers/1` keeps its signature and returns
  `result |> sources() |> Enum.map(& &1.indexer)`. Its callers (the indexer
  filter and filter options in `search_helpers.ex`, the label helper in
  `manual_search_components.ex`) are unchanged.

**Dedup.** `merge_duplicates/1` builds `sources` from every copy via
`SearchResult.sources/1`, so merging an already-merged result is still
correct. Entries are grouped by `indexer`; per indexer it keeps the first
entry whose `info_url` passes `SearchResult.info_page_url/1`, else the first
entry. The list is sorted by indexer name, matching today's `indexers` order.

`info_page_url/1` currently takes a `SearchResult`. Extract its URL check into
a public `SearchResult.usable_info_url/1` taking a string (or `nil`), and have
`info_page_url/1` delegate to it, so a `Source` URL goes through the same
checks: `http`/`https` with a host, no credentials (`redact_url/1` unchanged),
no feed or download path. This is a security boundary (Cardigann definitions
are external), so no source URL reaches the template without it.

**UI.** `indexer_badge/1` branches on the number of sources:

- **One source:** unchanged. A direct external link when the URL is usable, a
  plain badge otherwise.
- **Several sources:** the badge becomes the trigger of a daisyUI `dropdown
  dropdown-end` (end-anchored so the last grid column does not clip the menu).
  The trigger shows the same truncated label (`Name +N`) with a chevron
  instead of the external-link icon. The menu (`menu dropdown-content`) lists
  one row per source: an external link (`target="_blank"`,
  `rel="noopener noreferrer"`, link icon) when its URL is usable, and the
  indexer name as muted, non-interactive text when it is not. The trigger is a
  `<div tabindex="0" role="button">` per daisyUI's focus dropdown pattern, with
  an `aria-label` naming the trackers.

The badge renders twice per row (inline badge below `lg`, column from `lg`),
so dropdown ids are prefixed by the caller's row id.

### 3. Filter chips below the status card

In `modals.ex`, drop the `lg:flex lg:items-start lg:gap-3` side-by-side
layout. The status card spans the full width; on `lg+` the chips render in
their own row beneath it as `flex flex-wrap gap-2` (left-aligned). Below `lg`
nothing changes: the chip bar (`ManualSearchFilters.chip_bar/1`) already
handles it.

The indexer chip label is capped: with up to two selected indexers it joins
them as today; with three or more it shows the first two then "+N more"
(`ngettext`), with the full list in the chip's `title`. The cap applies to
both chip copies (chip bar and `lg` row). Removing the chip still clears the
whole indexer dimension.

## Error handling

No new failure modes. A source with no usable URL renders as text, never as a
dead link. A result that was never merged behaves exactly as today.

## Testing

- `test/mydia/indexers/result_dedup_test.exs`: merged copies keep each
  tracker's URL; two copies from the same tracker collapse to one source,
  preferring the one with a usable URL; merging a previously merged result
  keeps all its sources.
- `SearchResult` unit tests: `sources/1` and `indexers/1` on merged and
  unmerged results; `usable_info_url/1` on `http`, `https`, `javascript:`,
  hostless, a passkey URL, an `/rss/` path and `nil` (the existing
  `info_page_url/1` cases keep passing through the delegate).
- `test/mydia_web/live/media_live/show/modals_test.exs` (LiveView):
  - a merged result renders one menu link per tracker with a usable URL and
    plain text for one without;
  - a single-source result still renders a direct link;
  - the indexer chip with three or more indexers shows "+N more" and carries
    the full list in `title`.
- Existing fixtures that set `indexers:` move to `sources:`.
- New feature test `test/mydia_web/features/manual_search_layout_test.exs`
  (pattern: `media_file_row_width_test.exs`) at 1024 and 1440px, with all four
  filter dimensions plus four indexers active and a merged row whose winning
  tracker has a long name:
  - the status summary keeps a readable width (not collapsed beside the
    chips);
  - the indexer badge's right edge does not pass the download button's left
    edge;
  - opening the merged badge's dropdown shows a link per tracker, fully
    inside the viewport.
