# Manual search: full release titles, filters on demand

Issue: #1341

## Problem

Since `d0ffd8aea` ("responsive manual search dialog", 2026-10-29) the manual
search dialog truncates release names from `lg`. Before it, each result was a
card whose title used the full dialog width at `line-clamp-2 wrap-anywhere`,
so the release group at the end of the name was visible. Now, from `lg`, the
title shares one line (`lg:line-clamp-1`) with a 16rem filter sidebar and
about 26rem of fixed columns, inside a dialog capped at `lg:max-w-6xl`
(1152px) on every screen size. Users who pick releases by group have to hover
each row. This is a regression, not a polish request.

A second defect from the same issue: the `lg` Seeds column is `4.5rem`, and a
count of 10,000 or more plus the arrow icon overflows its badge.

## Goals

- The full release name is always visible, at every breakpoint.
- Filters take no space until the user asks for them.
- Large screens give the results more width.
- Seeder counts fit their column at any magnitude.
- The dialog chrome uses daisyUI components instead of hand-rolled toggles.

## Non-goals

- A collapsible rail or remembered open/closed preference for the filter
  panel. It opens closed every time.
- `MydiaWeb.Live.Components.ManualSearchModalComponent`, the unrelated
  metadata-match dialog.
- Changing the filter form's contents, which already use daisyUI
  (`fieldset`, `filter`, `menu`, `range`, `checkbox`).

## Design

### 1. Filters as a daisyUI drawer, closed by default

`lib/mydia_web/live/media_live/show/modals.ex` and
`lib/mydia_web/live/media_live/show/manual_search_filters.ex`.

Today the panel is a hand-rolled bottom sheet below `lg` (toggled by
`ManualSearchFilters.toggle_sheet/1` with `JS.toggle_class`, plus a custom
`#manual-search-filter-backdrop`) and a permanent grid column from `lg`
(`lg:grid-cols-[16rem_minmax(0,1fr)]`).

Replace both with one daisyUI `drawer drawer-end` inside the dialog body:

- `input#manual-search-filter-toggle.drawer-toggle` with
  `phx-update="ignore"`, the same pattern as `#main-drawer` in
  `layouts.ex`, so LiveView patches never reset the open state.
- `drawer-content` holds the results pane (`#manual-search-results-pane`).
- `drawer-side` holds a `label.drawer-overlay` for the toggle and the existing
  `<aside id="manual-search-filter-sheet">` form, now a fixed-width side panel
  (`w-80 max-w-[85%]`) at every breakpoint. The bottom-sheet classes and the
  grab handle go away. The "Show N results" footer
  (`#manual-search-show-results`) stays at every breakpoint, becoming a
  `label.btn.btn-primary.btn-block` for the toggle; it and the overlay close
  the panel.
- `toggle_sheet/1` and `#manual-search-filter-backdrop` are deleted.

The drawer is closed at every breakpoint, so the results always get the full
dialog width. Phones get a side drawer instead of the bottom sheet, which keeps
one behaviour across sizes.

**Containment check (do first).** `.drawer-side` is `position: fixed`. It must
anchor to the dialog, not the viewport. Verify in a browser that it is clipped
to the `modal-box` (its transform makes it the containing block for fixed
descendants; adding `contain-layout` or a `transform` utility to the drawer
root is acceptable to force that). If it cannot be contained reliably, keep the
current JS toggle and absolute positioning, restyled as a side panel, and note
the reason in the module doc.

### 2. One toolbar at every breakpoint

`ManualSearchFilters.chip_bar/1` drops `lg:hidden` and becomes the only place
filters are summarised:

- A `btn btn-sm btn-primary` "Filters" button that clicks the drawer's
  `#manual-search-filter-toggle` checkbox (a button rather than a bare
  `label for`, so it stays keyboard-operable). The active filter count is an
  inline `badge badge-sm` inside the button, shown when it is non-zero. A
  daisyUI `indicator` badge would sit outside the button's box, and the
  toolbar's `overflow-x-auto` would clip it.
- The removable active chips after it, as now.

The second chip copy rendered from `lg` under the indexer status card
(`id_prefix="manual-search-lg-chip"`, `modals.ex` around line 1006) is
removed, along with the `id_prefix` attribute on `active_chips/1`. The toolbar
keeps `data-scroll-rail` for the mobile layout sweep.

### 3. Wider dialog on large screens

`modals.ex` `manual_search_modal/1`: keep `sm:max-w-4xl lg:max-w-6xl` and add
`xl:max-w-[min(120rem,92vw)]`. A 1920px viewport gets about 1766px, a 2560px
one 1920px. Nothing changes below `xl`. The title column is `minmax(0,1fr)` in
`@row_grid`, so all added width goes to titles.

### 4. Full titles

`manual_search_components.ex`, the title element (currently
`line-clamp-2 lg:line-clamp-1`): remove the clamp and use `wrap-anywhere`. The
whole name always shows; it breaks only when longer than the column, so on
wide screens rows stay one line. The existing `title` hover attribute stays.

### 5. Compact seeder counts

New `format_seeders/1` in `manual_search_components.ex`:

| input | output |
| --- | --- |
| `nil` | unchanged (`—` / "Usenet" handling stays at the call sites) |
| `< 10_000` | exact, e.g. `9999` |
| `10_000..999_999` | one decimal `k`, trailing `.0` dropped: `12.3k`, `123k` |
| `>= 1_000_000` | one decimal `M`, same rule: `1.2M` |

Values at or above 100k drop the decimal (`123k`, not `123.4k`) so the
string is at most five characters (`12.3k`). Used at all three render sites: the
no-profile score badge, the mobile badge and the `lg` Seeds column. Each
badge gets a `title` with the exact count via the existing
`ngettext("%{count} seeder", ...)`. `seeder_tone/1` keeps using the raw
integer. The column stays `4.5rem`.

## Testing

- `format_seeders/1` unit tests: `nil`, `9999`, `10_000`, `12_345`,
  `99_999`, `123_456`, `1_000_000`, `1_250_000`.
- LiveView tests (`modals_test.exs`, `manual_search_filters_test.exs`):
  the drawer toggle exists and is unchecked on open; the Filters label targets
  it; the indicator badge shows the active count; there is one set of chips;
  a 123,456-seeder row renders `123k` with the exact count in `title`.
  Drop assertions on `toggle_sheet`, the backdrop and the `lg` chip copy.
- `test/mydia_web/features/manual_search_layout_test.exs` (real browser):
  - at 2560px the dialog is wider than 1152px;
  - the filter panel is not visible on open; clicking Filters shows it, and
    its bounding box lies inside the `modal-box`; clicking the overlay closes
    it;
  - at `lg` (1143px) a long fictional release name is fully visible
    (no clamp: `scrollHeight <= clientHeight` and `scrollWidth <= clientWidth`
    on the title element);
  - at `lg` a 99,999-seeder badge fits inside its cell.
- Re-run the mobile layout sweep (`test/support/mobile_layout_manifest.ex`
  drives the `manual-search` state) since the chip bar and filter panel move.

## Risks

- Drawer containment inside the modal (section 1) is the one unproven piece;
  it has a stated fallback.
- `phx-update="ignore"` on the toggle means the server cannot close the
  drawer. Nothing needs it to: closing the dialog removes the drawer.
