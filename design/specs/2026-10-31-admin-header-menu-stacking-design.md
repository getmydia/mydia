# Admin header menus paint under the hub tabs (#1317)

## Problem

On Settings > Library Paths, the Export menu's JSON item is clickable only at its
top edge and CSV only at its bottom edge. Files (CSV) works.

`admin_page/1` in `lib/mydia_web/components/admin_components.ex` renders the
page header (`#admin-page-header`, holding the `<:actions>` slot) and then the hub
tab strip `#admin-page-tabs` with `relative z-10`. The Export menu's
`dropdown-content` is also `z-10`, and its `.dropdown` wrapper is
`position: relative` with no z-index, so it forms no stacking context. Both
compete in the same context at the same z-index, and the tab strip wins because it
comes later in the DOM. The strip is a band about 40px tall below the header; it
covers the middle of the open menu and takes the clicks there.

Below `xl` the strip is hidden and the page switcher (`dropdown z-20`) takes its
place, with the same effect.

Every dropdown passed through `<:actions>` has this problem. Indexers' header
menu (`z-[1]`) is another one.

## Design

Give `#admin-page-header` in `admin_page/1` `relative z-[25]`. The header becomes
a stacking context above the tab strip (10) and the switcher (20), and stays below
the sticky mobile header (30), the sidebar (40), the dock (50), `.modal` (999) and
flash toasts (1000). The header contains only the title and actions, so nothing in
it needs to sit lower than that.

Per-menu z classes inside the header (`z-10`, `z-[1]`) now only order a menu within
the header and can stay as they are.

`page_header/1` (the variant without tabs) is unchanged: nothing follows it at a
positive z-index.

### Rejected

- Raising each header `.dropdown` wrapper to `z-[25]`: it touches every page, and
  the next header menu would regress.
- Dropping the tabs to `z-[1]`: it fixes `xl` and up only; the switcher stays
  at `z-20`.

## Testing

A feature test, `test/mydia_web/features/admin_header_menu_stacking_test.exs`,
modelled on `media_file_menu_stacking_test.exs`:

- Visit the Library Paths admin page, open `#library-export-menu`, and for each
  of `#library-export-json`, `#library-export-csv` and `#library-export-files-csv`
  assert that `document.elementFromPoint` at the item's centre is the item or a
  descendant of it.
- Run it at a viewport of at least `xl` (tab strip visible) and one below `xl`
  (switcher visible).
- The test must fail before the fix. That is the browser confirmation of the cause.

Class-presence assertions are not enough; `components/README.md` records them
passing with the bug present.

## Docs

Add the admin page header (25) to the z-index table in
`lib/mydia_web/components/README.md`, with one sentence saying header action
menus rely on it to clear the hub tabs and switcher.
