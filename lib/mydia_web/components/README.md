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
| Sticky mobile header | 30 |
| Sidebar `div.drawer-side` | 40 |
| Mobile dock `nav#mobile-dock` | 50 |
| daisyUI `.modal` | 999 |

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
(`lib/mydia_web/components/core_components.ex:438`). Passing it a class list
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

`CoreComponents.button/1` (`lib/mydia_web/components/core_components.ex:96`)
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

## The /admin/config scaffolding standard

Every page under `/admin/config` (`lib/mydia_web/live/admin_*_live/`) is built
from the same scaffolding, not just the external-service ones. Verified
2026-08-10 against download clients, indexers, media servers, library paths and
quality profiles, which are byte-for-byte consistent on the class strings below.
Convention drift here reads as a defect on its own, independent of whether the
page works.

**Thin template shell.** `index.html.heex` contains only
`<Layouts.app {assigns}><.admin_page active_tab={@active_tab}>`, one call to the
sibling `<MydiaWeb.Admin<X>Live.Components.<x>_tab ...>`, then each modal behind
`<%= if assigns[:show_<x>_modal] do %>`. All markup lives in a sibling
`components.ex`.

**No page `<h1>`.** `<.admin_page>` (`components/admin_components.ex:107`)
already renders the Configuration h1 and the tab bar. Tab content opens with
`<div class="p-4 sm:p-6 space-y-4">` and a section header:
`<h2 class="text-lg font-semibold flex items-center gap-2">` with a leading
`<.icon>`, the title, and `<span class="badge badge-ghost">{length(@items)}</span>`,
with
`<button class="btn btn-sm btn-primary" phx-click="new_<x>"><.icon name="hero-plus" class="w-4 h-4" /> New</button>`
on the right.

**Empty state, then the list.** `<div class="alert alert-info">` with
`hero-information-circle` when empty, otherwise
`<div class="bg-base-200 rounded-box divide-y divide-base-300">` wrapping
`<div class="p-3 sm:p-4">` rows. Not a `card`/`card-body`.

**Row shape.** A `flex-1 min-w-0` block with the name and a
`text-xs opacity-60 truncate` one-line descriptor, then status badges
(`badge badge-sm badge-outline`, enabled and health), then
`<div class="join ml-auto sm:ml-2">` of icon-only
`btn btn-sm btn-ghost join-item` buttons with `title=` tooltips for Test, Edit and
Delete, where delete gets `text-error`. Not labelled text buttons, and not
`<.button>`.

**Edit modal.** `<div class="modal modal-open"><div class="modal-box max-w-2xl">`
containing
`<.form for={@<x>_form} id="<x>-form" phx-change="validate_<x>" phx-submit="save_<x>">`,
a header with a `w-10 h-10 rounded-xl bg-primary/20` icon tile plus title and a
`text-sm text-base-content/60` subtitle, then
`<div class="modal-action mt-6 pt-4 border-t border-base-300">` and
`<div class="modal-backdrop bg-black/50" phx-click="close_<x>_modal">`.

**Namespaced events and assigns.** `new_<x>`, `edit_<x>`, `validate_<x>`,
`save_<x>` and `close_<x>_modal`, backed by `show_<x>_modal`, `<x>_form` and
`<x>_mode` (`:new` or `:edit`). Never bare `new`, `edit`, `save` or `cancel`.
Delete uses `data-confirm` unless there is a blast radius worth showing, in which
case a dedicated confirm modal, as download clients do.

Copy `admin_library_paths_live/` for the smallest complete example, or
`admin_download_clients_live/components.ex:85` (`download_clients_tab`) and `:239`
(`download_client_modal`). Env-sourced fields (`Settings.runtime_config?/1`)
render read-only with an ENV lock badge and disabled Edit and Delete. Singletons
such as FlareSolverr use one row plus Edit, with no add or delete.
