# Compact indexer search stats

## Problem

#1318 moved the per-indexer search stats on the Indexers page to daisyUI's
`stats` component. Each engine now renders a badge plus a four-cell box with
`text-lg` values, a `stat-desc` line under each and `py-2 px-4` padding, and
indexers with both engines stack two of these. The block dominates every
indexer row.

## Goal

Same stats, much less space. Keep daisyUI `stats`, keep every number
(success %, successes/attempts, p50, p90, avg results, timeouts) and the color
bands, and put all engines of one indexer on a single line.

## Design

All changes are in `stats_strip/1` in
`lib/mydia_web/live/admin_indexers_live/search_stats_components.ex`.

### Per-engine box

- Stays `stats stats-horizontal bg-base-200 rounded-box` and stays the
  `<button>` that opens recent failures. Its `id`, `phx-click`,
  `phx-value-id` and `title` are unchanged.
- Cells use `py-1 px-3`. Titles use `text-[11px]`. Values use
  `text-sm font-semibold`.
- No `stat-desc`. Its numbers move into the value line as a muted
  `text-xs font-normal` suffix:
  - Success: `98%` + `49/50`. Color bands unchanged (`text-success` at 95%+,
    `text-warning` from 80%, `text-error` below, muted for n/a).
  - Latency: `320 ms` + `p90 1.2 s`.
  - Results: `42` (or `n/a`). The "per search" desc is dropped; the title
    already says Results.
  - Timeouts: `0`, `text-warning` when above zero, muted otherwise.
- The engine badge above the box is removed. When `summary.engine` is set,
  the box gets a leading cell with the engine label (`Built-in`/`Prowlarr`)
  in the title style, vertically centered. This replaces both the visible
  badge and the `sr-only` label. When `summary.engine` is nil there is no
  label cell.
- The `-success` and `-timeouts` element ids are unchanged.

### Row layout

- The outer `indexer-stats-<id>` container changes from `flex-col` to
  `flex flex-row flex-wrap gap-2`, so engines sit side by side.
- On narrow screens a box that does not fit wraps to the next line. Each box
  keeps `max-w-full overflow-x-auto` and its `data-scroll-ok` marker as a
  fallback for a single box wider than the phone.
- "No searches yet" is unchanged.

## Testing

- Existing tests in `test/mydia_web/live/admin_indexers_live/search_stats_test.exs`
  (color bands, timeout warning, failures dialog) keep passing unchanged
  because ids are stable.
- New test: an indexer with builtin and prowlarr summaries renders both
  boxes as direct children of the same `indexer-stats-<id>` container, each
  showing its engine label.
- Check in a real browser at 1400px and 375px, light and dark.

## Translations

Regenerate `priv/gettext/default.pot` with `mix gettext.extract`. "per search"
is dropped and `%{ok} of %{attempts}` becomes `%{ok}/%{attempts}`.
`p90 %{p90}` is reused as the latency suffix.

## Out of scope

No change to `SearchStats`, the window toggle, the failures modal or events.
