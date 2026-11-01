# Components, daisyUI and CSS

Two rules run through everything here. Check a component's `attr` declarations
before assuming the HEEx idiom applies, and measure daisyUI behaviour in a
browser against the built stylesheet before asserting what a rule does.

## The vendored daisyUI file is not what ships

`assets/css/app.css` line 21 reads `@plugin "daisyui"`, which resolves to
`assets/node_modules/daisyui`, not to the checked-in `assets/vendor/daisyui.js`
sitting two lines above it under a comment telling you to `curl` the latest
release there.

Measured 2026-08-23: the vendored file reports `version = "5.5.18"` while the
built CSS reports `/*! 🌼 daisyUI 5.7.7 */`, and they disagree on real rules. The
`.filter` component is the example that bit. Vendored 5.5.18 collapses every
unchecked option when any option is checked, which would make the subtitle
dialog's multi-select language chips vanish after the first pick. Shipping 5.7.7
excludes checkboxes from that trigger
(`:has(:checked:not(.filter-reset, [type="checkbox"]))`), so multi-select works.
Reading the vendored file produced a confident and wrong bug report.

Never answer a daisyUI CSS question from `assets/vendor/daisyui.js`. Build the
real stylesheet and grep that:

```
./_build/tailwind-linux-x64-4.3.3 --input=assets/css/app.css --output=/tmp/app.css
```

It takes about 200ms and needs no devenv. `priv/static/assets/css/app.css` is a
gitignored build artifact and is absent in a fresh worktree, so build to a temp
path rather than assuming it exists. Grepping the built CSS for a rule and its
enclosing `@layer` line is the fastest way to settle any "why is my daisyUI
override ignored" question.

## A checked .btn input is always primary

A checkbox or radio styled as a button (`<input type="radio" class="btn">`, the
daisyUI filter/chip pattern CLAUDE.md prescribes) renders its `aria-label` as
visible text via
`.btn:is([type="checkbox"],[type="radio"])[aria-label]::after { content: attr(aria-label) }`.
That is how you get a self-labelling chip, and it works.

You cannot recolour the checked state with a colour class. daisyUI 5.7.7 emits

```css
@layer utilities { @layer daisyui.l1 {
  .btn:where(:checked:not(.filter [type="radio"].btn)) {
    --btn-color: var(--color-primary);
    --btn-fg: var(--color-primary-content);
  }
}}
```

directly in `daisyui.l1`, while `btn-error` and Tailwind's generated
`checked:btn-error` land in the nested `daisyui.l1.l2`. Rules declared directly
in a layer beat that layer's nested sublayers, and cascade layers beat specificity
outright, so the primary colour wins no matter how specific your selector.
Tailwind does generate `.checked\:btn-error:checked`; it just never applies, and
the failure is silent.

Set the variables that rule writes, using arbitrary properties, which land
outside daisyUI's layers:

```heex
class={[
  "join-item btn btn-xs",
  @destructive? && "[--btn-color:var(--color-error)] [--btn-fg:var(--color-error-content)]"
]}
```

Apply it conditionally from Elixir rather than through the `checked:` variant, so
the unchecked state keeps daisyUI's default outline. Verified by building
`priv/static/assets/css/app.css` and screenshotting the rendered page in headless
chromium in both themes. Live at
`lib/mydia_web/live/admin_duplicates_live/components.ex`.

## Inactive segments must not be btn-ghost

daisyUI defines `btn-ghost` as `--btn-bg: #0000` and `--btn-border: #0000`, so
a `btn-ghost` button computes to `alpha=0` and paints whatever is behind it.
That is fine for an action strip, and wrong for one option of a segmented
control, because the option ends up with no body at all.

Measured on the `mydia-dark` theme, against the built stylesheet:

| Surface | sRGB | vs page | vs inactive |
| --- | --- | --- | --- |
| page, `base-100` | `29,35,42` | | |
| inactive segment as `btn-ghost` | `alpha=0` | 1.000 | |
| inactive segment as plain `.btn` | `42,49,58` | 1.206 | |
| active segment, `btn-primary` | `0,125,255` | 4.055 | 3.363 |

`btn-active` is not a usable selection marker either. daisyUI sets it to
`color-mix(in oklab, base-200, #000 5%)`, which measures `38,45,53`, a
contrast of 1.059 against a plain button and darker than it. On a dark theme
the selected option reads as recessed rather than chosen.

Use `MydiaWeb.SegmentedControl` rather than hand-rolling either. It marks the
selected option `btn-primary` and gives unselected options no colour class,
which leaves them as plain opaque `.btn`.

A plain `.btn` is still a weak edge on its own. Its fill and border are both
`base-200`, which `mydia-dark` puts only 1.2 above the page, and Dim, Night,
Sunset, Dracula and Catppuccin put *below* the page, so the button sinks into
it. Toolbar buttons and unselected segments add `border-base-content/20`, a
hairline in the theme's text colour that holds up on every theme.

`test/mydia_web/components/no_ghost_segments_test.exs` fails the build if any
`join` in `lib/mydia_web` pairs `btn-ghost` with `btn-primary`.

## Every hover in Mydia gets darker, including on the dark theme

daisyUI's `.btn:hover` sets `--btn-bg: color-mix(in oklab, base-200, #000 7%)`.
It mixes toward black regardless of theme, so in dark mode a hovered button
moves from `42,49,58` to `37,44,51`. That is a contrast of 1.075, and it is
the wrong direction: the surface recedes instead of lifting.

Segmented controls override it with `dark:hover:bg-base-300` (`65,74,84`, a
1.459 step, lighter). Light mode keeps the daisyUI default, which is already
1.226 there and stronger than `base-300` would be.

The rest of the app still darkens on hover. Fixing that everywhere needs its
own visual pass.

## The dark: variant keys on the color scheme

`app.css` declares Tailwind's `dark:` variant by hand, keyed on the scheme and
not on a theme name:

```css
@custom-variant dark (&:where([data-color-scheme=dark], [data-color-scheme=dark] *));
```

`<html>` carries `data-color-scheme="dark"` for every dark theme (Mydia Dark,
Dracula, Mocha, OLED and the rest), so `dark:` utilities apply to all of them.
Keying on a name such as `mydia-dark` would silently skip the others, and a
wrong selector produces no error, which is why
`test/mydia_web/components/dark_variant_test.exs` guards it.

## Themes

- The catalogue is `Mydia.Accounts.Themes`. Every id in it needs CSS, which
  `test/mydia_web/themes_css_parity_test.exs` enforces.
- Each theme's `base` (used for `theme-color` and the login mirror) must match
  the theme's compiled base-100.
- Resolving the active theme lives in three places that must stay in step:
  `MydiaWeb.Layouts.theme_html_attrs/1` (server render), the inline script in
  `layouts/root.html.heex` (applies the localStorage mirror before paint) and
  `assets/js/theme.mjs` (live changes).
- Plugin frames are told only `mydia-dark` or `mydia-light`, chosen from
  `data-color-scheme` (`assets/js/hooks/plugin_frame_theme.mjs`).

Tailwind utilities beat daisyUI's component rules, so `dark:hover:bg-base-300`
overrides `background-color: var(--btn-bg)`. Tailwind emits utilities directly
in `@layer utilities` while daisyUI's declaration sits in a nested `daisyui.l1`
sublayer, and cascade layers beat specificity outright.

One caution when checking any of this. Tailwind only generates classes it finds
in the `@source` globs, so a class written into a scratch HTML file is never
built and reads as "the rule does not work". Confirm the class is present in
the built CSS before concluding anything:

```
./_build/tailwind-linux-x64-4.3.3 --input=assets/css/app.css --output=/tmp/app.css
```

## No card-level dropdown can win on z-index

Two traps, and the second is the fatal one.

daisyUI ships `.join { > :where(:focus, :has(:focus)) { z-index: 1; } }`. A
`.dropdown` that is a direct child of a `.join` holds the `tabindex="0"` trigger,
so opening the menu is what matches `:has(:focus)`. The wrapper gets
`z-index: 1`, and since `.dropdown` is `position: relative`, that creates a
stacking context confining everything inside, including a `z-50` on the
`dropdown-content`. The z utility therefore has to go on the `.dropdown` wrapper
rather than the menu list. Tailwind's `.z-20` is emitted directly in
`@layer utilities` while daisyUI's rule is in a nested `daisyui.l1.l2` sublayer,
so the utility wins.

Getting that right fixes nothing, because the application chrome outranks any
value a card can claim:

| Layer | z-index |
| --- | --- |
| Card badges | 10 |
| Admin page header (`#admin-page-header`) | 25 |
| Sticky mobile header | 30 |
| Sidebar `div.drawer-side` | 40 |
| Mobile dock `nav#mobile-dock` | 50 |
| daisyUI `.modal` | 999 |
| Flash toasts `#flash-group` | 1000 |

Flash toasts must outrank `.modal`: a connection test inside an edit dialog
raises its result as a flash, and below 999 the backdrop covers it, so the only
way to dismiss it was closing the dialog (#1226). `add_config_modal` in
`add_media_components.ex` also uses `z-[1000]`; ties at 1000 resolve by DOM
order, and `flash_group` renders last in the app layout (`layouts.ex`), so
toasts paint above that modal too.

A card that climbed above 40 and 50 would paint over the sidebar during ordinary
browsing. There is no correct number. Verified in a real browser on
`v0.14.0-beta.1`: with the correct `z-20` on the wrapper, the picker was still
covered by the sidebar on first-column cards at 1920, 1400 and 1100, covered by
the dock below `lg`, ran 34 to 67px off the left edge, and hung up to 191px below
the fold. Seven viewports tested, every one broken.

The fix is structural. Use a page-level `<dialog class="modal">`, which is
`position: fixed; inset: 0; z-index: 999` and is not a descendant of the card.
That also escapes `overflow` clipping, which previously banned the picker from
horizontal rails.

Class-presence tests cannot see any of this. `assert html =~ "z-20"` stayed green
through four rounds, and only `document.elementFromPoint` over the menu rectangle
in a real browser caught it. History: #465, `4f598bbae`, then `a66b1107b`, then
`122b8a741`, all z-index moves, then the dialog rewrite.

The rule is about cards in a poster grid, which sit next to the sidebar and
above the dock. A dropdown in the main content column that opens away from the
sidebar only has to beat the card badges, and `z-20` on its `.dropdown`
wrapper does that while staying under the header, sidebar and dock. Use that
band. The Media Files card's file actions menu was `z-[1]` on the list, so the
franchise rail's rating badges painted through it on phones (#1107). It is now
a native popover with CSS anchor positioning (the `#downloads-more` pattern),
because at the three-column width the show page's main column is its own
scroll container and clipped the anchored menu of a file row near its bottom
edge. The top layer escapes both the clip and every z-index, and
`position-try-fallbacks: flip-block` opens it upward when there is no room
below. The Seasons & Episodes monitoring menu (`monitoring_menu.ex`) sits in
the same column and uses the same pattern for the same reason.
`test/mydia_web/features/media_file_menu_stacking_test.exs` guards it, and
shows the probe trap too: `refute_covered/2`'s 3x3 grid fell between the
25px-tall badges and passed with the bug present, so the test hit-tests the
centre of each overlap instead.

Menus in an admin page's `<:actions>` sit in `#admin-page-header`, which
`admin_page/1` lifts to `z-[25]` so they clear the hub tab strip (`z-10`) and the
page switcher (`z-20`) that follow it in the DOM. Before that, the strip took the
clicks across the middle of the Library Paths Export menu at `xl`, and on phones,
where the menu opens left-aligned, the switcher did (#1317).
`test/mydia_web/features/admin_header_menu_stacking_test.exs` guards it.

## .menu is fit-content, so truncate inflates instead of clipping

daisyUI 5's `.menu` is `flex-flow: column wrap; width: fit-content` and does not
fill its parent. A `truncate` (`white-space: nowrap`) descendant therefore has no
width-constrained ancestor to clip against, so an unbreakable string inflates the
menu, the card and the document instead of ellipsizing.

Measured on the Media Files card (PR #616, 375x812): an 82-character basename
produced a row 712.5px wide against a 351px card, and the whole page gained a
horizontal scrollbar. `labelOverflows` (`scrollWidth > clientWidth`) was false,
which is the tell. The element is not being squeezed, it is growing. The
`break-all` markup it replaced never overflowed, because wrapping cannot
overflow, so switching a long-path label from `break-all` to `truncate` can make
mobile strictly worse unless the ancestors are constrained.

Every other non-popover `.menu` list in mydia already carries `w-full`
(`layouts.ex`, `indexer_components.ex`, `library_components.ex`, and three in
`modals.ex`). The `dropdown-content menu` popovers deliberately do not, since
they are fixed narrow widths (`w-44`, `w-52`). A `.menu` without `w-full` is the
anomaly.

Two more daisyUI rules bite in the same place. `.menu :where(li)` sets
`flex-flow: column wrap`, so the `li` re-wraps and needs `flex-nowrap`. And
`.menu :where(li:not(.menu-title) > :not(ul,menu,details,.menu-title,.btn))` sets
`display: grid; align-items: center` on a plain `div` child of the `li`; utility
`flex flex-col` already beats the `display:grid` half, but `align-items:center`
is live and needs `items-stretch`.

Adding `truncate` inside a daisyUI `.menu` therefore requires `w-full` on the
`ul`, plus `flex-nowrap` and `items-stretch` on the wrapping chain. Confirm by
measuring that `labelOverflows` is true, not merely that the label renders on one
line. One line plus an inflated row is the failure mode, and it looks fine in a
screenshot of the row alone. `flex-wrap` is not inherited, so a nested
`flex flex-wrap` badge row inside is unaffected. This was found only because the
plan required a browser measurement; five clean per-task code reviews all missed
it.

## <.icon> types class as :string

`MydiaWeb.CoreComponents.icon/1` declares `attr :class, :string, default: "size-4"`
(`lib/mydia_web/components/core_components.ex:404`). Passing it a class list
compiles and renders correctly but emits a warning on every build:

```heex
<%!-- warns: class must be a :string --%>
<.icon name="hero-arrow-uturn-left" class={["w-4 h-4", not @thing.active? && "opacity-30"]} />

<%!-- correct --%>
<.icon name="hero-arrow-uturn-left" class={if(@thing.active?, do: "w-4 h-4", else: "w-4 h-4 opacity-30")} />
```

This is a direct exception to CLAUDE.md, which says to always use list syntax for
conditional classes. That rule holds for plain HTML elements and for components
whose `class` attr is `:any`. The rest of the codebase gives `<.icon>` a plain
string, as in the dimmed disabled-action icons at
`admin_library_paths_live/components.ex:449` and `:454`. Tests pass either way, so
this only shows up as build noise.

## <.button> is a passthrough, and raw <button> is the convention

`CoreComponents.button/1` (`lib/mydia_web/components/core_components.ex:48`)
declares `attr :class, :string`, so a conditional class list warns exactly as it
does on `<.icon>`. It also applies its `["btn", variant]` default only via
`assign_new`, so a call site supplying its own full class string gets a bare
passthrough of `<button class={@class} {@rest}>`, with no variant logic, no
defaults and no added behaviour.

Two consequences. Icon-only toolbar buttons with bespoke classes should stay raw
`<button>`, since wrapping them is pure indirection, and any control needing a
conditional class cannot use the component without restructuring into
`if(..., do: "...", else: "...")` string branches. And raw `<button>` is the
actual convention: counted 2026-08-20, `lib/mydia_web/live` holds 463 raw
`<button>` against 20 `<.button>`.

CLAUDE.md says to always use the core components, and CodeRabbit cites that line
to flag raw buttons on any PR touching them. On PR #516 it raised this as Major,
and the reply above (class-attr contract, passthrough, the 463-to-20 convention)
was accepted outright: "You are correct. The conditional class list conflicts with
the current `<.button>` `:class` attribute contract."

The guideline still holds where `<.button>`'s variants and defaults do real work.
Check the component's `attr` declarations before converting, and reply with
specifics rather than complying reflexively or dismissing it.

## The admin page scaffolding standard

Every admin page (`lib/mydia_web/live/admin_*_live/`) is built from the same
components. Before they existed the standard was a list of class strings to
copy, and an audit on 2026-10-07 found only two of 23 pages still matching it.
Convention drift reads as a defect on its own, independent of whether the page
works. `test/mydia_web/admin_page_conventions_test.exs` fails the build on the
drift patterns that audit found, for every LiveView mounted under `/admin`
(dependency LiveViews outside `lib/mydia_web/live`, such as the error tracker
dashboard, are skipped).

**Registered in `MydiaWeb.AdminNav`.** A new admin page needs an entry in
`lib/mydia_web/admin_nav.ex` with its hub (Configuration for acquisition levers,
Administration for work to act on, System for the server itself), label,
one-line description, icon and `~p` path under `/admin/<slug>`. That entry is
the page's sidebar link and its header. `test/mydia_web/admin_nav_test.exs`
fails for a live route under `/admin` that has no entry. Import Lists is the
one admin-only page outside the hubs; it renders `<.admin_header>` directly.

**Thin template shell.** `index.html.heex` contains only
`<Layouts.app {assigns}><.admin_page page={:<key>}>`, one call to the sibling
`<MydiaWeb.Admin<X>Live.Components.<x>_tab ...>`, then each modal behind
`<%= if assigns[:show_<x>_modal] do %>`. All markup lives in a sibling
`components.ex`. Pass the key as a literal: `admin_page/1` declares
`values: AdminNav.keys()`, so a typo fails the build. Sixty lines at most.

**Header.** A list page passes `count={length(@items)}`, and its buttons go in
`<:actions>` through a `header_actions/1` function component in the page's own
`components.ex`, as `btn-sm` buttons (the primary one `btn-primary`). The body
never repeats the page name.

**Hub chrome.** `admin_page/1` titles the page with its hub
(`h1#admin-page-title`); the page itself is named by its active tab. From `xl`
the hub's pages are lifted tabs (`nav#admin-page-tabs`, `tabs-lift`) with their
icons from `2xl`. Configuration's nine tabs need 842px as labels and 1080px with
icons, against 960px beside the sidebar at `xl` and 1216px at `2xl`, and lifted
tabs that wrap look broken. Below `xl`, `nav#admin-page-switcher` is a single
lifted tab naming the current page, with a menu of `<.link navigate>` items
(`#admin-switcher-<key>`). It was a plain `btn` until #1188 reported it blended
into the page in every theme. `#admin-page-count` sits in the active strip tab
and `#admin-switcher-count` in the switcher, since both are always in the DOM.

**Body.** The tabs join `div#admin-page-body`: both the strip and the switcher
overlap its top border by 1px (`-mb-px`). It is a bordered `bg-base-100` panel
(`p-3 sm:p-4 xl:p-6 space-y-4`) whose first child is the page description.
Its top-left corner is always square, since a tab always sits there.
A page's `*_tab` component renders its content directly, with no
padding wrapper of its own; the conventions test flags one. A real subsection
(Needs Attention, Scheduled Jobs) is `<.admin_section title icon count>`. Its
`:actions` slot holds what sits beside the heading: a button, a range picker, a
health badge. One-of-N filters and pickers use `<.segmented_control>` (the
Trash filter, the quality presets, the Dashboard range); `tabs` mean hub
navigation, or switching content panes inside a modal. Colours come from theme
tokens such as `text-base-content/60`, never `text-gray-*`.

**Lists.** `<.admin_list id items>` with a `:row` and an `:empty` slot renders
the `bg-base-200 rounded-box border border-base-300 divide-y divide-base-300`
container (the border is what separates a card from the `base-200` page on
phones), or an `alert alert-info` when empty. Each row is `<.admin_row id>`
with `:title`, `:descriptor` (one truncated `text-xs opacity-60` line),
`:details` (multi-line notes and warnings, not truncated or dimmed), `:badges`
(`badge badge-sm badge-outline`) and `:actions`. `:body` is full width under
the row, for a nested list such as a duplicate group's files. Never a
`card`/`card-body`. Two lists stay hand-rolled on purpose: the Dashboard's
Recent Activity, whose watch rows have no id, and the Settings Language form, a
fixed set of form rows with mixed controls.

**Row actions.** `<.row_actions>` holding `<.row_action icon title ...>`
buttons: icon-only `btn btn-sm btn-ghost join-item`, `title=` doubling as the
accessible name, `destructive` for delete. A row with more than three actions
keeps the common ones in the join and puts maintenance actions in an "Actions"
dropdown beside it, as library paths do; quality profiles keep an Export
dropdown beside the join the same way. The dropdown sits beside the join inside
one `flex items-center gap-2 ml-auto sm:ml-2` wrapper, never inside the join,
and each menu button blurs itself on click so the menu closes.

**Row actions inside a stream.** A click is lost whenever the element under the
press is detached before the mouse comes back up, and a refreshing stream
detaches more than it looks like (issue #1257). `stream(..., reset: true)`
detaches every row. A plain re-insert keeps the row but rebuilds every id-less
function-component root inside it, because LiveView keys those by a
`data-phx-id` the client mints afresh for each insert; keyed buttons are then
moved into the new container. So inside a stream: refresh without resetting
when the order holds (`DownloadsLive.Rows.stream_page/2`), give the action
wrapper and `<.row_actions id=...>` stable ids, and leave button icons to the
`app.css` rule that turns off their pointer events, so the press lands on the
button rather than a span that is about to be replaced.

**Tables.** A page with many rows and several columns (jobs, release
blacklist, users) uses `<.admin_table id rows row_id>` with `:col`, `:action`
and `:empty` slots: the same empty state and the same row actions.
Below `sm` it stacks: each row is a card, each cell a label/value pair labelled
from its column's `label`, and the first column is the card's title. A `:col`
`class` that only makes sense in a table (`truncate`, a `max-w-*`) takes an
`sm:` prefix.

History tables that page by offset keep their Load More or prev/next controls
outside `admin_table`.

**Env-sourced rows.** `Settings.runtime_config?/1` rows show `<.env_lock_badge>`
and their Edit and Delete are `<.row_action disabled disabled_reason=...>`:
visible and disabled, never hidden. Indexers is the one exception: Edit stays
enabled on an env indexer because it offers "Convert to database-managed".
Singletons such as FlareSolverr use one row plus Edit, with no add or delete.
A page that shows where each value came from, such as Settings, uses
`<.config_source_badge source>` instead, which has four states (ENV, DB, YAML
and Default).

**Modals.** `<.admin_modal id icon title subtitle on_close>` renders
`modal modal-open`, a `max-w-2xl` box (`size={:lg}` for `max-w-4xl` browsers
and catalogues), the `w-10 h-10 rounded-xl bg-primary/20` icon tile, the
bordered `modal-action` from its `:actions` slot and a `bg-black/50` backdrop
that fires `on_close`. The `:header_aside` slot sits on the right of the
header (an Enabled toggle, say); a form field there needs
`form="<form-id>"` because it lives outside the `<form>`. The page puts its own
`<.form for={@<x>_form} id="<x>-form" phx-change="validate_<x>" phx-submit="save_<x>">`
inside; a form whose buttons must be inside the `<form>` renders
`<.admin_modal_actions>` itself. `tone={:error}` tints the icon tile for a
destructive confirmation. Whenever `on_close` is set, a header close button
`#<id>-close` (ghost `btn-circle`, `hero-x-mark`, aria-label "Close") sends
the same event as the backdrop; `on_close={nil}` gets neither a working
backdrop nor a button, for content a stray click must not dismiss (a one-time
API key). Below `sm` the box fills the screen and covers the backdrop, which
is why the button matters on phones.
The box is a flex column: the header stays fixed, the content sits in a
scrolling body `#<id>-body` (`px-1 -mx-1` so focus rings are not clipped) and
the action row stays outside the scroller. `admin_modal_actions/1` is sticky
at the bottom, so a form that renders it inside its own `<form>`, which lives
in the body, still keeps its buttons on screen. The body is the scroller, so
content must not add its own `overflow-y-auto` or `max-h` list scroller. A
daisyUI `.tooltip` bubble inside the body is clipped by it and can make it
scroll sideways (measured on the indexer library's verified-engine badges,
which use a native `title` instead). Field labels inside the box wrap, since
daisyUI's `.label` is `nowrap`.

**Filters.** A `<.segmented_control>` option takes an `id` when a test or a
link needs to address it.

**Namespaced events and assigns.** `new_<x>`, `edit_<x>`, `validate_<x>`,
`save_<x>`, `delete_<x>`, `test_<x>`, `filter_<x>` and `close_<x>_modal`,
backed by `show_<x>_modal`, `<x>_form` and `<x>_mode` (`:new` or `:edit`).
Never bare `new`, `edit`, `save`, `cancel`, `close`, `delete`, `remove`,
`test`, `validate` or `filter`. Delete uses `data-confirm` unless there is a
blast radius worth showing, in which case a dedicated confirm modal, as
download clients do.

**One scroller per phone screen.** An admin screen scrolls as the page or as
an open dialog, never a region inside either, so `overflow-x-auto` and
`overflow-y-auto` must be scoped with `sm:` (the conventions test fails on an
unprefixed one); mark a deliberate exception, such as a non-wrapping segmented
control, with `data-scroll-ok="reason"` on the same tag.

Every admin page is built this way now; `admin_storage_backends_live/` is the smallest
complete example.

## The sidebar

`MydiaWeb.Layouts.app/1` composes the sidebar from `MydiaWeb.SidebarComponents`.
A new link is a `<.nav_item>` in the section it belongs to, never hand-written
`<li><.link>` markup.

| Section | Holds | Visible to |
|---|---|---|
| (no heading) | Home, Discover, My Requests | all; My Requests only when `Authorization.can_submit_request?/1` (guests) |
| Library | Movies, TV Shows, pinned sections, Collections, Calendar | all |
| Acquisition | Search, Downloads, Import, Import Lists, Activity | `Authorization.can_update_media?/1` (admin, user); Import Lists also needs `is_admin?/1` and the feature flag |
| Admin | the three `AdminNav` hubs | `Authorization.is_admin?/1` |

Visibility only hides links. Every page still enforces its own authorization.

**Badges mean "needs attention".** `nav_item/1`'s `badge` renders only above
zero (Downloads, Import, Administration). A library total is `count`, a muted
number, never a badge.

**The account menu is the footer.** `account_menu/1` is the aside's last child
and opens upward (`dropdown dropdown-top`). It holds Profile, Integrations,
Devices, the theme switcher, What's new and Send feedback. The aside is
`h-full`, not `min-h-full`, and the nav is `flex-1 min-h-0 overflow-y-auto`.
`.drawer-side` is a viewport-height scroll container, so an aside with
`min-h-full` would grow to its content and the footer would scroll away with
it. Never give `.drawer-side` a viewport-unit `min-height` such as
`min-h-screen`: iOS Safari resolves `100vh` taller than daisyUI's `100dvh`
while its toolbar shows, which pushes the chip under the toolbar.
`dock_nav_test.exs` asserts the drawer has no `min-height`.

## Sidebar sections are pinned collections, and exclusion is page scoped

A section is a `Mydia.Collections.Collection` with `pinned_position` set. It
renders in the sidebar between TV Shows and the Management group and links to
`/sections/:id`, which is `MediaLive.Index` in its `:section` live action,
with the collection's smart rules supplying `:base_query`.

Pins are owner scoped. `Collections.list_pinned_sections/1` filters on
`c.user_id == ^user.id`, so a shared collection pinned by its owner never
shows up in anyone else's sidebar. A section can therefore never become a
fixed section for the whole instance, only a per-user shortcut.

A section marked `exclusive` claims its categories away from `/movies` and
`/tv`, but only for its owner. Only a single `category in [...]` condition
qualifies (`Collections.exclusive_eligible?/1`), because a richer rule set
cannot be cleanly subtracted from those pages. The claimed list is derived
from the rules on every read by `Collections.claimed_categories/1`, never
stored, and returns `[]` for anything it cannot parse: malformed JSON, or
rules that are not exactly one `category in [...]` condition.

The exclusion is applied only on the built-in Movies and TV pages, never on a
section's own page. `MediaLive.Index.build_query_opts/1` passes
`:exclude_categories` only when `assigns[:section]` is `nil`. A section's own
query already filters to `category in [...]`, so subtracting the same
categories again there would empty the section out.

## Mobile layout sweep

`test/mydia_web/features/mobile_layout_sweep_test.exs` visits every `live`
route at 320, 375 and 414px wide, in its default state and in the states
listed for it in `test/support/mobile_layout_manifest.ex`, and fails on six
defects, measured by seven checks:

| Check | Fails when |
|---|---|
| `page_overflow` | the document is wider than the viewport |
| `inner_scroll` | an element scrolls sideways inside the page |
| `escapes_viewport` | a visible element extends past the left or right edge (only the outermost one is reported) |
| `small_target` | a button, link, input, select, summary, `role="button"` or `label[for]` is under 24x24px |
| `overlapping_targets` | two tap targets overlap |
| `clipped_text` | an `overflow: hidden` element cuts its text off without an ellipsis or line clamp |
| `tiny_text` | text renders under 12px |

All comparisons allow 1px. The audit hides scrollbars while it measures, so
layout width equals the window width, as on a phone. After each load the sweep
waits for CSS transitions to finish (a drawer sliding in is measured at rest)
and asserts the browser is still on the visited path, so a redirect with a
flash fails. Before each audit it asserts that the page content and the mobile
dock have a box, so a blank or crashed page fails instead of passing every
check.

Feature tests render with a pinned fontconfig from devenv,
`MYDIA_FEATURE_TEST_FONTCONFIG`, which `scripts/run-feature-tests.sh` exports as
`FONTCONFIG_FILE`. Every sans font resolves to Liberation Sans, with DejaVu
only as glyph fallback and for serif and monospace, so text widths, and so the sweep's results,
match CI; a sweep run outside `./dev feature-test` is not comparable. The
`/changelog` page renders content compiled from `priv/changelog`, so a new
release entry changes what it measures.

The checks skip things that are not defects: links inside running text (by
computed `display: inline`), the body of a closed `<details>`, the off-screen
drawer panel while it is closed, a small control laid over a much larger
one (a select box on a poster card), and whatever an `overflow` ancestor cuts
off (a span in a truncated line, a link scrolled out of its nav). A target inside a `position: fixed` layer
such as the dock does not collide with page content scrolling under it; two
fixed targets, or two flow targets, still can.

A deliberate sideways carousel (poster rails, shelves, the manual search chip
row) carries `data-scroll-rail` on its scrolling element: `poster_rail/1` in
`poster_card_components.ex` and `chip_bar/1` in
`media_live/show/manual_search_filters.ex` set it. The sweep skips
`inner_scroll` and `escapes_viewport` inside it. Nothing else should carry it.

A new `live` route fails `test/mydia_web/mobile_layout_manifest_test.exs`
until it is added to the manifest or excluded with a reason. `/review` (a
redirect), `/plugins/:slug`, `/plugins/:slug/activity`, `/setup`,
`/play/:type/:id` and the ErrorTracker dashboard (`/admin/errors` and its
detail pages) are excluded. Every page must pass at 320px.

A manifest state is a name and steps (reload with a query, click, wait for a
selector). Its results are keyed `route#state`, for example
`/downloads#issues`, in failures and in `@known`. Only three states are swept
today: the Downloads Issues tab, the mobile drawer open on `/`, and the manual
search dialog on `/movies/:id`. Adding states for other pages' tabs and
dialogs is follow-up work.

Selectors in a failure replace database ids, UUIDs and LiveView's `#phx-*`
ids with `*`, so an entry keeps matching between runs whose rows get new ids.

`@known` in the sweep is the list of accepted violations, and it is empty: no
page has an accepted defect. A new page must pass at 320px without an entry, so
fix the layout rather than adding one. The attribute, `Report.diff/2` and the
stale rule stay as the guard. Each entry would be
`{route, widths, check, selector, reason}`, where `widths` is one integer or a
list (such as `[320, 375, 414]`). The failure output prints the entry that would
accept a violation, with one width; adding one is a review decision, not a fix.
An entry that stops matching fails the sweep, so remove it when the page is
fixed. The checker's own tests are in
`test/mydia_web/features/mobile_layout_self_test.exs`.

### What keeps pages passing on phones

- **Phone-only size layer.** `assets/css/app.css` has a block scoped to
  `@media (width < 40rem)` (Tailwind's `sm` breakpoint). Below it, daisyUI's
  `btn-xs` and `badge-xs` text is raised to 12px, and `toggle-sm`, `checkbox-sm`
  and `checkbox-xs` are raised to 24px, so they meet the sweep's `tiny_text` and
  `small_target` thresholds. Desktop sizes are unchanged. Use the daisyUI size
  classes as usual; do not swap them per call site to satisfy the sweep. The
  block is unlayered, so below 640px it also outranks Tailwind text utilities
  on `.badge-xs` and `.btn-xs`; a `text-[10px]` there does nothing on phones.
- **Mobile dock: at most five items.** The dock labels are 12px and five items
  fit at 320px. Player lives in the drawer only. A sixth item would not fit, so
  put it in the drawer instead. The `DockNav` hook re-measures on resize.
- **Library grids** use a letter picker in the toolbar below `sm` instead of the
  A-Z strip.
- **Charts** draw axis labels in HTML (the plays chart), and the `tiny_text`
  check measures SVG text at its rendered size, not its user-space size.
