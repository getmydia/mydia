# Manual Search Full Titles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore full release names in the manual search dialog (#1341): filters move into a closed-by-default daisyUI drawer, the dialog widens on large screens, titles stop clamping, and large seeder counts render compactly.

**Architecture:** All changes are in the media show page's manual search dialog: `Modals.manual_search_modal/1` (layout), `ManualSearchFilters` (toolbar and filter panel), `ManualSearchComponents` (result row), `Formatters` (new seeder formatter). No server state changes; the drawer is a client-side daisyUI checkbox toggle.

**Tech Stack:** Phoenix LiveView 1.2, daisyUI 5 (`drawer`, `badge`, `btn`), Tailwind v4, ExUnit + LazyHTML, Wallaby feature tests.

Spec: `design/specs/2026-11-04-manual-search-full-titles-design.md`.

## Global Constraints

- Every UI string goes through `gettext`/`ngettext`; run `./dev mix gettext.extract` after changing text and commit `priv/gettext/*.pot`. Never edit `.po` files.
- Fictional release and tracker names only in tests (no real titles).
- No em dashes in prose you add (code comments, docs). The existing `—` seeder placeholder glyph stays.
- Feature tests run with `./dev feature-test <path> --only feature`; confirm the output says `Including tags: [:feature]` and a non-zero test count. Rebuild assets after any class change: `devenv shell -- bash -c 'mix assets.setup && mix assets.build'`.
- Commits: `git add <paths>` then `git commit -F <msgfile>` from the worktree (direnv loaded), each commit in its own step, then `git show --stat HEAD` to verify nothing was left unstaged.
- Ids kept stable (tests and the mobile sweep use them): `#manual-search-modal`, `#manual-search-chip-bar`, `#manual-search-filters-button`, `#manual-search-filter-sheet`, `#manual-search-filter-form`, `#manual-search-show-results`, `#manual-search-results-pane`, `#manual-search-chip-<dimension>`.
- New ids: `#manual-search-drawer`, `#manual-search-filter-toggle`, `#manual-search-filter-close`.

---

### Task 1: Compact seeder counts

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/formatters.ex` (add `format_seeders/1`)
- Modify: `lib/mydia_web/live/media_live/show/manual_search_components.ex:146-213,306-319` (three seeder render sites, import)
- Create: `test/mydia_web/live/media_live/show/formatters_test.exs`
- Modify: `test/mydia_web/live/media_live/show/modals_test.exs` (describe `"manual_search_modal/1 row states"`)

**Interfaces:**
- Produces: `MydiaWeb.MediaLive.Show.Formatters.format_seeders(non_neg_integer()) :: String.t()`. Callers handle `nil` themselves.

- [ ] **Step 1: Write the failing unit test**

Create `test/mydia_web/live/media_live/show/formatters_test.exs`:

```elixir
defmodule MydiaWeb.MediaLive.Show.FormattersTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Show.Formatters

  describe "format_seeders/1" do
    test "counts under 10,000 are exact" do
      assert Formatters.format_seeders(0) == "0"
      assert Formatters.format_seeders(9_999) == "9999"
    end

    test "10,000 to 99,999 show one truncated decimal in thousands" do
      assert Formatters.format_seeders(10_000) == "10k"
      assert Formatters.format_seeders(12_345) == "12.3k"
      assert Formatters.format_seeders(99_999) == "99.9k"
    end

    test "100,000 to 999,999 show whole thousands" do
      assert Formatters.format_seeders(123_456) == "123k"
      assert Formatters.format_seeders(999_999) == "999k"
    end

    test "millions show one truncated decimal, then whole millions" do
      assert Formatters.format_seeders(1_000_000) == "1M"
      assert Formatters.format_seeders(1_250_000) == "1.2M"
      assert Formatters.format_seeders(12_345_678) == "12M"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./dev mix test test/mydia_web/live/media_live/show/formatters_test.exs`
Expected: FAIL with `UndefinedFunctionError ... format_seeders/1`.

- [ ] **Step 3: Implement `format_seeders/1`**

Append to `MydiaWeb.MediaLive.Show.Formatters` (integer math, so the label never overstates and is at most four characters):

```elixir
  @doc """
  A seeder count short enough for the manual search Seeds column: exact below
  10,000, then `12.3k`, `123k`, `1.2M`, `12M`. Truncates rather than rounds,
  so the label never claims more peers than the tracker reported. Callers
  render `nil` (no seeder concept, e.g. Usenet) themselves.
  """
  def format_seeders(n) when is_integer(n) and n < 10_000, do: Integer.to_string(n)
  def format_seeders(n) when is_integer(n) and n < 100_000, do: tenths(n, 1_000, "k")
  def format_seeders(n) when is_integer(n) and n < 1_000_000, do: "#{div(n, 1_000)}k"
  def format_seeders(n) when is_integer(n) and n < 10_000_000, do: tenths(n, 1_000_000, "M")
  def format_seeders(n) when is_integer(n), do: "#{div(n, 1_000_000)}M"

  defp tenths(n, unit, suffix) do
    tenths = div(n, div(unit, 10))

    case rem(tenths, 10) do
      0 -> "#{div(tenths, 10)}#{suffix}"
      frac -> "#{div(tenths, 10)}.#{frac}#{suffix}"
    end
  end
```

- [ ] **Step 4: Run the unit test**

Run: `./dev mix test test/mydia_web/live/media_live/show/formatters_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Write the failing render test**

In `modals_test.exs`, inside `describe "manual_search_modal/1 row states"`, next to `"nil seeders render a placeholder, not 0, in the seeds cell"`:

```elixir
    test "large seeder counts render compactly with the exact count on hover" do
      html = modal_html(%{title: "Some.Movie.2020.1080p.ENG.x264", seeders: 123_456})
      doc = LazyHTML.from_fragment(html)

      cell = LazyHTML.query(doc, "[id$='-seeds'] .badge")
      assert cell |> LazyHTML.text() |> String.trim() == "123k"
      assert LazyHTML.attribute(cell, "title") == ["123456 seeders"]

      # The mobile badge and the no-profile circle say the same.
      refute html =~ ">123456<"
      assert html =~ ~s(title="123456 seeders")
    end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `./dev mix test test/mydia_web/live/media_live/show/modals_test.exs`
Expected: the new test FAILS (text is `123456`, no `title` on the column badge).

- [ ] **Step 7: Use the formatter at all three render sites**

In `manual_search_components.ex`, extend the import:

```elixir
  import MydiaWeb.MediaLive.Show.Formatters,
    only: [format_search_size: 1, format_relative_time_short: 1, format_seeders: 1]
```

Add a private helper near `seeder_tone/1`:

```elixir
  defp seeders_title(nil), do: gettext("No seeder count (Usenet)")
  defp seeders_title(n), do: ngettext("%{count} seeder", "%{count} seeders", n)
```

Then:

1. No-profile circle (around line 155): replace its inline `title={if is_nil(...) ...}` with `title={seeders_title(@result.seeders)}` and `{@result.seeders}` with `{format_seeders(@result.seeders)}`.
2. Mobile badge (around line 205): `title={seeders_title(@result.seeders)}` and `{format_seeders(@result.seeders)}`.
3. `lg` Seeds column badge (around line 307): add `title={seeders_title(@result.seeders)}` to the `<span class={["badge badge-sm", ...]}>` and replace `{@result.seeders}` with `{format_seeders(@result.seeders)}`.

The `nil` branches (`—`) stay inside each `if is_nil(@result.seeders)`.

- [ ] **Step 8: Run the modal tests**

Run: `./dev mix test test/mydia_web/live/media_live/show/modals_test.exs test/mydia_web/live/media_live/show/formatters_test.exs`
Expected: PASS. The existing `"12 seeders"` assertion still holds.

- [ ] **Step 9: Commit**

```bash
git add lib/mydia_web/live/media_live/show/formatters.ex \
  lib/mydia_web/live/media_live/show/manual_search_components.ex \
  test/mydia_web/live/media_live/show/formatters_test.exs \
  test/mydia_web/live/media_live/show/modals_test.exs
git commit -F <msgfile>   # fix(search): compact seeder counts so 10k+ fits the Seeds column (#1341)
```

---

### Task 2: Drawer containment spike

The spec's one unproven piece. Decide the drawer CSS before rewriting the panel.

**Files:**
- Temporary only: a scratch branch edit to `modals.ex`, reverted at the end of the task. Nothing is committed except, if needed, a spec note.

- [ ] **Step 1: Build assets and confirm feature tests run**

```bash
devenv shell -- bash -c 'mix assets.setup && mix assets.build'
./dev feature-test test/mydia_web/features/smoke_test.exs --only feature
```
Expected: `Including tags: [:feature]`, 1 test, 0 failures.

- [ ] **Step 2: Wrap the results pane in a bare drawer**

In `modals.ex`, temporarily replace the `lg:grid` wrapper `<div class={["flex min-h-0 flex-1 flex-col", @filters_visible? && "lg:grid ..."]}>` with:

```heex
<div id="manual-search-drawer" class="drawer drawer-end relative min-h-0 flex-1 grid-rows-[minmax(0,1fr)]">
  <input id="manual-search-filter-toggle" type="checkbox" class="drawer-toggle" phx-update="ignore" />
  <div class="drawer-content flex min-h-0 flex-col">
    <%!-- existing #manual-search-results-pane, unchanged --%>
  </div>
  <div class="drawer-side absolute! inset-0! h-full! z-30">
    <label for="manual-search-filter-toggle" class="drawer-overlay"></label>
    <aside id="spike-panel" class="h-full w-80 max-w-[85%] bg-base-100">spike</aside>
  </div>
</div>
```

and drop the `<ManualSearchFilters.filter_panel>` call for the spike.

- [ ] **Step 3: Measure in a real browser**

Rebuild assets, then add a throwaway test to `manual_search_layout_test.exs` (do not commit it) at 1440x900 and 390x844 that opens the dialog, runs `js_click(session, "#manual-search-filter-toggle")`, and returns:

```javascript
var box = document.querySelector("#manual-search-modal .modal-box").getBoundingClientRect();
var p = document.getElementById("spike-panel").getBoundingClientRect();
return {inside: p.left >= box.left - 1 && p.right <= box.right + 1 &&
                p.top >= box.top - 1 && p.bottom <= box.bottom + 1,
        visible: p.width > 0 && getComputedStyle(p).visibility !== "hidden",
        width: Math.round(p.width)};
```

Expected for the chosen variant: `inside: true, visible: true` at both sizes, and `visible: false` (or zero-width / `visibility: hidden`) before the click.

- [ ] **Step 4: Decide**

- If `inside` and `visible` hold: record the exact class string for `.drawer-side` that worked (the starting point is `absolute! inset-0! h-full! z-30`; adjust only if needed) and use it in Task 3.
- If no class combination keeps the panel inside the box: follow the spec's fallback. In Task 3 keep `#manual-search-filter-toggle` but drop `drawer`/`drawer-side`, and instead show/hide the panel with `JS.toggle_class("hidden", ...)` on an absolutely positioned right-side `<aside>` plus a backdrop, and add one sentence to the spec's section 1 saying why. Everything else in Task 3 is unchanged.

- [ ] **Step 5: Revert the spike**

```bash
git checkout -- lib/mydia_web/live/media_live/show/modals.ex test/mydia_web/features/manual_search_layout_test.exs
```

---

### Task 3: Filters in a closed-by-default drawer, one toolbar

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/manual_search_filters.ex` (moduledoc, `toggle_sheet/1` replaced, `chip_bar/1`, `active_chips/1`, `filter_panel/1`)
- Modify: `lib/mydia_web/live/media_live/show/modals.ex:946-1016` (layout wrapper, second chip copy)
- Modify: `test/mydia_web/live/media_live/show/manual_search_filters_test.exs`
- Modify: `test/mydia_web/live/media_live/show/modals_test.exs`
- Modify: `test/mydia_web/features/manual_search_layout_test.exs:133` (chip id)
- Modify: `priv/gettext/default.pot` (via extract)

**Interfaces:**
- Produces: `ManualSearchFilters.toggle_id/0 :: "manual-search-filter-toggle"`; `ManualSearchFilters.toggle_drawer/1 :: (JS.t()) -> JS.t()` (dispatches a click on the toggle). `toggle_sheet/1` is deleted. `active_chips/1` loses `id_prefix` (ids are always `manual-search-chip-<dimension>`).

- [ ] **Step 1: Write the failing component tests**

Append to `manual_search_filters_test.exs`:

```elixir
  describe "chip_bar/1" do
    test "shows at every breakpoint with a Filters button that opens the drawer" do
      doc =
        render_component(&ManualSearchFilters.chip_bar/1, quality_filters: ["1080p"])
        |> LazyHTML.from_fragment()

      [bar] = doc |> LazyHTML.query("#manual-search-chip-bar") |> Enum.to_list()
      refute bar |> LazyHTML.attribute("class") |> hd() =~ "lg:hidden"

      button = LazyHTML.query(doc, "#manual-search-filters-button")
      assert LazyHTML.attribute(button, "aria-controls") == ["manual-search-filter-sheet"]
      assert button |> LazyHTML.attribute("phx-click") |> hd() =~ "#manual-search-filter-toggle"
      assert button |> LazyHTML.query(".badge") |> LazyHTML.text() =~ "1"
    end
  end

  describe "filter_panel/1" do
    defp panel_doc do
      render_component(&ManualSearchFilters.filter_panel/1, result_count: 3)
      |> LazyHTML.from_fragment()
    end

    test "is a daisyUI drawer side with an overlay bound to the toggle" do
      doc = panel_doc()

      assert [_] = doc |> LazyHTML.query(".drawer-side #manual-search-filter-sheet") |> Enum.to_list()

      assert doc |> LazyHTML.query(".drawer-side > label.drawer-overlay") |> LazyHTML.attribute("for") ==
               ["manual-search-filter-toggle"]

      assert [] = doc |> LazyHTML.query("#manual-search-filter-backdrop") |> Enum.to_list()
    end

    test "close and show-results controls dispatch to the toggle" do
      doc = panel_doc()

      for id <- ["#manual-search-filter-close", "#manual-search-show-results"] do
        assert doc |> LazyHTML.query(id) |> LazyHTML.attribute("phx-click") |> hd() =~
                 "#manual-search-filter-toggle"
      end

      assert doc |> LazyHTML.query("#manual-search-show-results") |> LazyHTML.text() =~ "Show 3 results"
    end
  end
```

Append to `modals_test.exs` inside `describe "manual_search_modal/1 row states"`:

```elixir
    test "filters live in a closed drawer and the chips render once" do
      html = modal_html(%{}, %{quality_filters: ["1080p"], raw_results_empty?: false})
      doc = LazyHTML.from_fragment(html)

      toggle = LazyHTML.query(doc, "#manual-search-drawer > input#manual-search-filter-toggle.drawer-toggle")
      assert [_] = Enum.to_list(toggle)
      assert LazyHTML.attribute(toggle, "checked") == []
      assert LazyHTML.attribute(toggle, "phx-update") == ["ignore"]

      assert [_] = doc |> LazyHTML.query("#manual-search-chip-quality") |> Enum.to_list()
      assert [] = doc |> LazyHTML.query("[id^='manual-search-lg-chip']") |> Enum.to_list()
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./dev mix test test/mydia_web/live/media_live/show/manual_search_filters_test.exs test/mydia_web/live/media_live/show/modals_test.exs`
Expected: the new tests FAIL (no drawer, `lg:hidden` present, `lg-chip` copy present).

- [ ] **Step 3: Rewrite the toggle helpers and moduledoc**

In `manual_search_filters.ex`, replace the moduledoc's second sentence and `toggle_sheet/1` with:

```elixir
  @moduledoc """
  The manual search dialog's filter controls: the toolbar of active filters,
  the filter panel (a daisyUI drawer inside the dialog, closed until the
  Filters button opens it) and the sort menu. `MydiaWeb.MediaLive.Show`
  handles their events.
  """
```

```elixir
  @toggle_id "manual-search-filter-toggle"

  @doc "The id of the drawer's `drawer-toggle` checkbox, rendered by the dialog."
  def toggle_id, do: @toggle_id

  @doc """
  Opens or closes the filter drawer by clicking its daisyUI `drawer-toggle`
  checkbox. Client-side only; the checkbox is `phx-update="ignore"`, so
  LiveView patches never reset it. Buttons use this rather than a bare
  `<label for>` so they stay keyboard-operable.
  """
  def toggle_drawer(js \\ %JS{}), do: JS.dispatch(js, "click", to: "##{@toggle_id}")
```

- [ ] **Step 4: Rewrite `chip_bar/1`**

Drop `lg:hidden` from the bar's class list, change the doc to "The Filters button and active chips, at every breakpoint.", and replace the button with:

```heex
      <button
        type="button"
        id="manual-search-filters-button"
        class="btn btn-sm btn-primary shrink-0"
        phx-click={toggle_drawer()}
        aria-controls="manual-search-filter-sheet"
      >
        <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
        {gettext("Filters")}
        <span :if={@active > 0} class="badge badge-sm">{@active}</span>
      </button>
```

(The count stays an inline `badge`: a daisyUI `indicator` badge sits outside the button's box and the toolbar's `overflow-x-auto` clips it. Update the spec's section 2 bullet to say so in the same commit.)

- [ ] **Step 5: Drop `id_prefix` from `active_chips/1`**

Delete the `attr :id_prefix` line and its comment, and use `id={"manual-search-chip-#{dimension}"}` on each chip.

- [ ] **Step 6: Rewrite `filter_panel/1` as a drawer side**

Replace the backdrop `<div>` and the `<aside>` opening (through the grab handle and the header) with the following, using the `.drawer-side` classes Task 2 settled on (shown here with the starting point):

```heex
    <div class="drawer-side absolute! inset-0! h-full! z-30">
      <label for={toggle_id()} class="drawer-overlay" aria-label={gettext("Close filters")}></label>
      <aside
        id="manual-search-filter-sheet"
        aria-label={gettext("Filters")}
        class="flex h-full w-80 max-w-[85%] flex-col bg-base-100 shadow-2xl"
      >
        <div class="flex shrink-0 items-center justify-between gap-2 px-4 pt-3 pb-1">
          <h4 class="font-semibold">{gettext("Filters")}</h4>
          <div class="flex items-center gap-1">
            <button
              type="button"
              id="manual-search-clear-filters"
              class="btn btn-ghost btn-xs"
              phx-click="clear_search_filters"
            >
              {gettext("Reset")}
            </button>
            <button
              type="button"
              id="manual-search-filter-close"
              class="btn btn-ghost btn-sm btn-square"
              phx-click={toggle_drawer()}
              aria-label={gettext("Close filters")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>
```

Keep the `<form id="manual-search-filter-form">` and the "Close after grabbing" label unchanged. Replace the footer with (no `lg:hidden`):

```heex
        <div class="shrink-0 border-t border-base-300 p-3">
          <button
            type="button"
            id="manual-search-show-results"
            class="btn btn-primary btn-block"
            phx-click={toggle_drawer()}
          >
            {ngettext("Show %{count} result", "Show %{count} results", @result_count)}
          </button>
        </div>
      </aside>
    </div>
```

Update the function's `@doc` to: "The filter form, as the `drawer-side` of the dialog's `#manual-search-drawer`. Closed until the toggle is checked; the overlay, the close button and Show results close it."

- [ ] **Step 7: Rewire the dialog body**

In `modals.ex`, replace the wrapper that starts `<div class={["flex min-h-0 flex-1 flex-col", @filters_visible? && "lg:grid ..."]}>` with:

```heex
        <div
          id="manual-search-drawer"
          class="drawer drawer-end relative min-h-0 flex-1 grid-rows-[minmax(0,1fr)]"
        >
          <input
            :if={@filters_visible?}
            id={ManualSearchFilters.toggle_id()}
            type="checkbox"
            class="drawer-toggle"
            phx-update="ignore"
            aria-label={gettext("Show filters")}
          />
          <div class="drawer-content flex min-h-0 flex-col">
            <div id="manual-search-results-pane" class="min-h-0 flex-1 overflow-y-auto">
              <%!-- existing pane contents, unchanged except step 8 --%>
            </div>
          </div>
          <ManualSearchFilters.filter_panel
            :if={@filters_visible?}
            ...same attrs as before...
          />
        </div>
```

The `filter_panel` call moves after `drawer-content` (daisyUI's `.drawer-toggle:checked ~ .drawer-side` selector needs the toggle before it). Keep the long `@filters_visible?` comment above `chip_bar`.

- [ ] **Step 8: Remove the second chip copy**

Delete the `<ManualSearchFilters.active_chips :if={@filters_visible?} id_prefix="manual-search-lg-chip" ... />` block under `.indexer_search_status`, and change the comment above it to `<%!-- Search progress --%>`.

- [ ] **Step 9: Point the layout feature test at the single chip id**

In `test/mydia_web/features/manual_search_layout_test.exs`, `tick/5`: `["manual-search-lg-chip-#{dimension}", shows]` becomes `["manual-search-chip-#{dimension}", shows]`.

- [ ] **Step 10: Run the LiveView suites**

```bash
./dev mix gettext.extract
./dev mix test test/mydia_web/live/media_live/show/ test/mydia_web/live/media_live/manual_search_streaming_test.exs test/mydia_web/untranslated_text_test.exs
```
Expected: PASS. If `untranslated_text_test` flags anything, wrap it in `gettext`.

- [ ] **Step 11: Commit**

```bash
git add lib/mydia_web/live/media_live/show/manual_search_filters.ex \
  lib/mydia_web/live/media_live/show/modals.ex \
  test/mydia_web/live/media_live/show/manual_search_filters_test.exs \
  test/mydia_web/live/media_live/show/modals_test.exs \
  test/mydia_web/features/manual_search_layout_test.exs \
  priv/gettext/default.pot design/specs/2026-11-04-manual-search-full-titles-design.md
git commit -F <msgfile>   # feat(search): hide manual search filters in a daisyUI drawer (#1341)
```

---

### Task 4: Wider dialog and full titles

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/modals.ex:860` (dialog width)
- Modify: `lib/mydia_web/live/media_live/show/manual_search_components.ex:174` (title classes)
- Modify: `test/mydia_web/features/manual_search_layout_test.exs` (new geometry tests)

**Interfaces:**
- Consumes: `#manual-search-filters-button`, `#manual-search-filter-sheet`, `#manual-search-filter-toggle` from Task 3.

- [ ] **Step 1: Write the failing feature tests**

In `manual_search_layout_test.exs`, add a long fictional release to `results/0`'s list:

```elixir
        %{
          title:
            "Glass.Harbor.2019.Directors.Extended.Remastered.1080p.BluRay.REMUX.AVC.DTS-HD.MA.7.1-LONGRELEASEGROUP",
          seeders: 99_999,
          indexer: "Ashvale Commons",
          info_url: "https://tracker3.example/details/77"
        }
```

Add helpers:

```elixir
  defp rect_js do
    """
    var r = function (el) { var b = el.getBoundingClientRect();
      return {l: b.left, r: b.right, t: b.top, b: b.bottom, w: b.width}; };
    """
  end

  defp open_dialog(session, movie, {w, h}) do
    login_as_admin(session)

    session
    |> resize_window(w, h)
    |> visit_liveview("/media/#{movie.id}")

    js_click(session, "#manual-search-button")
    assert Wallaby.Browser.has_css?(session, "#indexer-search-status[aria-busy='false']")
    session
  end

  # The row whose title contains `needle`, as {title_fits, seeds_overflow_px}.
  defp row_fit(session, needle) do
    eval_js(
      session,
      rect_js() <>
        """
        var needle = arguments[0];
        var t = Array.from(document.querySelectorAll("#manual-search-results-pane [title]"))
          .find(function (el) {
            return el.getAttribute("title") === needle && el.textContent.trim() === needle;
          });
        if (!t) return null;
        var row = t.closest("[id^='search-result-']");
        var seeds = row.querySelector("[id$='-seeds'] .badge");
        var cell = seeds.parentElement;
        return {
          title_fits: t.scrollHeight <= t.clientHeight + 1 && t.scrollWidth <= t.clientWidth + 1,
          seeds_overflow: Math.round(r(seeds).r - r(cell).r)
        };
        """,
      [needle]
    )
  end
```

Add tests:

```elixir
  @long "Glass.Harbor.2019.Directors.Extended.Remastered.1080p.BluRay.REMUX.AVC.DTS-HD.MA.7.1-LONGRELEASEGROUP"

  @tag :feature
  test "the dialog uses large screens", %{session: session, movie: movie} do
    open_dialog(session, movie, {2560, 1440})
    box = width_of(session, "#manual-search-modal .modal-box")
    assert box > 1152, "at 2560px the dialog was only #{box}px wide"
  end

  for {w, h} <- [{1143, 800}, {1440, 900}, {390, 844}] do
    @tag :feature
    test "filters start closed and open inside the dialog at #{w}px", %{session: session, movie: movie} do
      open_dialog(session, movie, {unquote(w), unquote(h)})

      panel = fn ->
        eval_js(session, rect_js() <> """
        var box = r(document.querySelector("#manual-search-modal .modal-box"));
        var el = document.getElementById("manual-search-filter-sheet");
        var p = r(el);
        var shown = p.w > 0 && getComputedStyle(el.parentElement).visibility !== "hidden";
        return {shown: shown,
                inside: p.l >= box.l - 1 && p.r <= box.r + 1 && p.t >= box.t - 1 && p.b <= box.b + 1};
        """)
      end

      assert %{"shown" => false} = panel.()

      js_click(session, "#manual-search-filters-button")
      eventually(fn -> if panel.()["shown"], do: {:ok, true}, else: :error end,
        description: "the filter drawer to open")
      assert %{"inside" => true} = panel.()

      js_click(session, "#manual-search-show-results")
      eventually(fn -> if panel.()["shown"], do: :error, else: {:ok, true} end,
        description: "the filter drawer to close")
    end
  end

  for {w, h} <- [{1143, 800}, {2560, 1440}] do
    @tag :feature
    test "a long release name shows in full and 99,999 seeders fit at #{w}px", %{
      session: session,
      movie: movie
    } do
      open_dialog(session, movie, {unquote(w), unquote(h)})

      assert %{"title_fits" => true, "seeds_overflow" => overflow} = row_fit(session, @long)
      assert overflow <= 0, "the seeds badge ran #{overflow}px past its column"
    end
  end
```

Note the drawer's visibility check reads `.drawer-side`'s computed `visibility` (daisyUI hides the closed side with `visibility: hidden`); if Task 2 fell back to `hidden`, check `el.offsetParent !== null` instead.

- [ ] **Step 2: Rebuild assets and run them to verify they fail**

```bash
devenv shell -- bash -c 'mix assets.build'
./dev feature-test test/mydia_web/features/manual_search_layout_test.exs --only feature
```
Expected: the drawer tests PASS (Task 3). "the dialog uses large screens" FAILS (1152px). "a long release name shows in full" FAILS on `title_fits` (clamped).

- [ ] **Step 3: Widen the dialog**

`modals.ex`, the `modal-box` class list:

```elixir
        "sm:h-[90vh] sm:max-w-4xl lg:max-w-6xl xl:max-w-[min(120rem,92vw)]"
```

- [ ] **Step 4: Stop clamping titles**

`manual_search_components.ex`, the release title `<div>`:

```heex
      <div
        class="font-medium text-sm leading-tight mb-2 wrap-anywhere"
        title={@result.title}
      >
```

- [ ] **Step 5: Rebuild assets and run the feature tests**

```bash
devenv shell -- bash -c 'mix assets.build'
./dev feature-test test/mydia_web/features/manual_search_layout_test.exs --only feature
```
Expected: `Including tags: [:feature]`, all tests PASS, including the pre-existing #1311 legibility tests.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia_web/live/media_live/show/modals.ex \
  lib/mydia_web/live/media_live/show/manual_search_components.ex \
  test/mydia_web/features/manual_search_layout_test.exs
git commit -F <msgfile>   # fix(search): show full release names in a wider manual search dialog (#1341)
```

---

### Task 5: Mobile sweep and precommit

**Files:**
- Possibly modify: `test/support/mobile_layout_manifest.ex` (only if the sweep needs a new state for the open drawer)

- [ ] **Step 1: Run the mobile layout sweep**

```bash
./dev feature-test test/mydia_web/features/mobile_layout_sweep_test.exs --only feature
```
Expected: PASS. The `manual-search` state still opens via `#manual-search-button`; the toolbar keeps `data-scroll-rail`. If it reports a violation in the dialog, fix the classes, not the manifest. If it passes, add a state that also opens the drawer so the panel is swept on phones:

```elixir
          {"manual-search-filters",
           [
             {:click, "#manual-search-button"},
             {:wait, "#manual-search-filters-button"},
             {:click, "#manual-search-filters-button"},
             {:wait, "#manual-search-filter-toggle:checked"}
           ]}
```

placed next to the existing `{"manual-search", ...}` entry, then re-run the sweep and expect PASS.

- [ ] **Step 2: Run precommit in chunks**

`mix precommit` outruns the 600s Bash cap; run it in the background or in pieces: `./dev mix format`, `./dev mix compile --warnings-as-errors`, `./dev mix gettext.extract --check-up-to-date`, then `./dev mix test test/mydia_web/` and `./dev mix test test/mydia/` as separate foreground runs.
Expected: all clean.

- [ ] **Step 3: Verify the diff against origin/master**

```bash
git fetch origin master
git diff --stat origin/master...HEAD
```
Expected: only the files named in Tasks 1-5, the spec and this plan.

- [ ] **Step 4: Commit any sweep or format changes**

```bash
git add test/support/mobile_layout_manifest.ex
git commit -F <msgfile>   # test(web): sweep the manual search filter drawer on phones
git show --stat HEAD
```
