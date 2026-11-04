defmodule MydiaWeb.MediaLive.Show.ManualSearchFilters do
  @moduledoc """
  The manual search dialog's filter controls: the toolbar of active filters,
  the filter panel (a daisyUI drawer inside the dialog, closed until the
  Filters button opens it) and the sort menu. `MydiaWeb.MediaLive.Show`
  handles their events.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents

  alias Phoenix.LiveView.JS

  @doc """
  The sort orders, in menu order.
  """
  def sort_options do
    [
      {:quality, gettext("Best Score")},
      {:seeders, gettext("Most Seeds")},
      {:size, gettext("Largest")},
      {:date, gettext("Newest")}
    ]
  end

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

  @filters_button "#manual-search-filters-button"
  @results_pane "#manual-search-results-pane"

  @doc """
  Opens the drawer and moves focus into the panel. The panel comes after every
  result row in the DOM, so without this a keyboard user would tab through all
  of them to reach the form.

  It also sets `aria-expanded="true"` on the Filters button and makes the
  results pane `inert`, so from `sm` up (where the results stay on screen
  behind the overlay) they leave the tab order and the accessibility tree.
  LiveView's JS attribute commands survive patches, so a filter change while
  the drawer is open does not undo them.
  """
  def open_drawer do
    toggle_drawer()
    |> JS.set_attribute({"aria-expanded", "true"}, to: @filters_button)
    |> JS.set_attribute({"inert", ""}, to: @results_pane)
    |> JS.focus_first(to: "#manual-search-filter-sheet")
  end

  @doc "Closes the drawer and returns focus to the Filters button."
  def close_drawer, do: after_close(toggle_drawer())

  @doc """
  What the drawer's overlay does on click, besides the toggle. The overlay is a
  `<label for>`, so the browser already unchecks the toggle; dispatching
  another click here would reopen it. This only undoes what `open_drawer/0`
  set and returns focus to the Filters button.
  """
  def overlay_close, do: after_close(%JS{})

  # The state every close path shares: collapsed button, live results, focus
  # back where the drawer was opened from.
  defp after_close(js) do
    js
    |> JS.set_attribute({"aria-expanded", "false"}, to: @filters_button)
    |> JS.remove_attribute("inert", to: @results_pane)
    |> JS.focus(to: @filters_button)
  end

  attr :quality_filters, :list, default: []
  attr :source_filters, :list, default: []
  attr :codec_filters, :list, default: []
  attr :indexer_filters, :list, default: []
  attr :min_seeders, :integer, default: 0

  @doc """
  The Filters button and active chips, at every breakpoint. The row scrolls
  sideways on purpose when the chips outgrow it, so it carries
  `data-scroll-rail` for the mobile layout sweep.
  """
  def chip_bar(assigns) do
    assigns = assign(assigns, :active, active_count(assigns))

    ~H"""
    <div
      id="manual-search-chip-bar"
      data-scroll-rail
      class="flex items-center gap-2 overflow-x-auto border-b border-base-300 bg-base-200/50 px-3 py-2"
    >
      <button
        type="button"
        id="manual-search-filters-button"
        class="btn btn-sm btn-primary shrink-0"
        phx-click={open_drawer()}
        aria-controls="manual-search-filter-sheet"
        aria-expanded="false"
      >
        <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
        {gettext("Filters")}
        <span :if={@active > 0} class="badge badge-sm">{@active}</span>
      </button>
      <.active_chips
        quality_filters={@quality_filters}
        source_filters={@source_filters}
        codec_filters={@codec_filters}
        indexer_filters={@indexer_filters}
        min_seeders={@min_seeders}
      />
    </div>
    """
  end

  attr :quality_filters, :list, default: []
  attr :source_filters, :list, default: []
  attr :codec_filters, :list, default: []
  attr :indexer_filters, :list, default: []
  attr :min_seeders, :integer, default: 0
  attr :class, :any, default: nil

  @doc "One removable chip per active filter dimension."
  def active_chips(assigns) do
    assigns = assign(assigns, :chips, chips(assigns))

    ~H"""
    <div :if={@chips != []} class={["flex items-center gap-2", @class]}>
      <span
        :for={{dimension, label, title} <- @chips}
        id={"manual-search-chip-#{dimension}"}
        class="badge badge-soft badge-primary shrink-0 gap-1 whitespace-nowrap"
        title={title}
      >
        {label}
        <button
          type="button"
          class="cursor-pointer opacity-70 hover:opacity-100"
          phx-click="remove_search_filter"
          phx-value-dimension={dimension}
          aria-label={gettext("Remove filter: %{filter}", filter: title || label)}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </span>
    </div>
    """
  end

  attr :visible?, :boolean, required: true
  attr :quality_filters, :list, default: []
  attr :source_filters, :list, default: []
  attr :codec_filters, :list, default: []
  attr :indexer_filters, :list, default: []
  attr :filter_options, :map, default: %{sources: [], codecs: [], indexers: []}
  attr :quality_options, :list, default: []
  attr :min_seeders, :integer, default: 0
  attr :close_after_grab, :boolean, default: false
  attr :result_count, :integer, default: 0
  slot :inner_block, required: true, doc: "The results pane, wrapped in the drawer's content."

  @doc """
  The dialog's `#manual-search-drawer`: the toggle, the content holding the
  slot (the results pane) and the `filter_panel/1` as the side. The root and
  the content always render; the toggle and the side only when `visible?` is
  true, which is when the Filters button exists.
  """
  def filter_drawer(assigns) do
    ~H"""
    <div
      id="manual-search-drawer"
      class="drawer drawer-end relative min-h-0 flex-1 grid-rows-[minmax(0,1fr)]"
    >
      <input
        :if={@visible?}
        id={toggle_id()}
        type="checkbox"
        class="drawer-toggle peer"
        tabindex="-1"
        phx-update="ignore"
        aria-label={gettext("Show filters")}
      />
      <%!-- Phones only: the sheet covers nearly the whole dialog, so once it has
           slid in (the visibility flip waits out the transition) the
           results pane is hidden and its controls leave the tab order. From
           `sm` up the results stay visible, dimmed behind the overlay. --%>
      <div class={[
        "drawer-content flex min-h-0 flex-col",
        "max-sm:transition-[visibility] max-sm:duration-300 max-sm:peer-checked:invisible"
      ]}>
        {render_slot(@inner_block)}
      </div>
      <.filter_panel
        :if={@visible?}
        quality_filters={@quality_filters}
        source_filters={@source_filters}
        codec_filters={@codec_filters}
        indexer_filters={@indexer_filters}
        filter_options={@filter_options}
        quality_options={@quality_options}
        min_seeders={@min_seeders}
        close_after_grab={@close_after_grab}
        result_count={@result_count}
      />
    </div>
    """
  end

  attr :quality_filters, :list, default: []
  attr :source_filters, :list, default: []
  attr :codec_filters, :list, default: []
  attr :indexer_filters, :list, default: []
  attr :filter_options, :map, default: %{sources: [], codecs: [], indexers: []}
  attr :quality_options, :list, default: []
  attr :min_seeders, :integer, default: 0
  attr :close_after_grab, :boolean, default: false
  attr :result_count, :integer, default: 0

  @doc """
  The filter form, as the `drawer-side` of the dialog's `#manual-search-drawer`.
  Closed until the toggle is checked; the overlay, the close button and Show
  results close it.
  """
  def filter_panel(assigns) do
    ~H"""
    <%!-- daisyUI delays the `visibility` flip by 100ms, and `focus()` on a
         hidden element does nothing, so when the toggle is checked the flip is
         immediate. Closing keeps the delay and the slide-out. --%>
    <div class={[
      "drawer-side absolute! inset-0! h-full! z-30 col-start-1!",
      "peer-checked:[transition:opacity_.2s_ease-out_.1s,visibility_0s]"
    ]}>
      <label
        for={toggle_id()}
        class="drawer-overlay"
        aria-label={gettext("Close filters")}
        phx-click={overlay_close()}
      ></label>
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
              phx-click={close_drawer()}
              aria-label={gettext("Close filters")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <form
          id="manual-search-filter-form"
          phx-change="filter_search"
          class="min-h-0 flex-1 overflow-y-auto px-4 pb-3"
        >
          <fieldset class="fieldset">
            <legend class="fieldset-legend">{gettext("Quality")}</legend>
            <div class="filter flex-wrap gap-1">
              <input
                :for={quality <- @quality_options}
                type="checkbox"
                class="btn btn-sm"
                name="quality[]"
                value={quality}
                aria-label={quality_label(quality)}
                checked={quality in @quality_filters}
              />
            </div>
          </fieldset>
          <fieldset :if={@filter_options.indexers != []} class="fieldset">
            <legend class="fieldset-legend">{gettext("Indexer")}</legend>
            <ul class="menu menu-sm w-full p-0">
              <li :for={{name, count} <- @filter_options.indexers}>
                <label class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-primary"
                    name="indexer[]"
                    value={name}
                    checked={name in @indexer_filters}
                  />
                  <span class="flex-1 truncate">{name}</span>
                  <span class="text-xs text-base-content/60">{count}</span>
                </label>
              </li>
            </ul>
          </fieldset>
          <fieldset :if={@filter_options.sources != []} class="fieldset">
            <legend class="fieldset-legend">{gettext("Source")}</legend>
            <div class="filter flex-wrap gap-1">
              <input
                :for={source <- @filter_options.sources}
                type="checkbox"
                class="btn btn-sm"
                name="source[]"
                value={source}
                aria-label={source}
                checked={source in @source_filters}
              />
            </div>
          </fieldset>
          <fieldset :if={@filter_options.codecs != []} class="fieldset">
            <legend class="fieldset-legend">{gettext("Codec")}</legend>
            <div class="filter flex-wrap gap-1">
              <input
                :for={codec <- @filter_options.codecs}
                type="checkbox"
                class="btn btn-sm"
                name="codec[]"
                value={codec}
                aria-label={codec}
                checked={codec in @codec_filters}
              />
            </div>
          </fieldset>
          <fieldset class="fieldset">
            <legend class="fieldset-legend">
              {gettext("Minimum seeders: %{count}", count: @min_seeders)}
            </legend>
            <input
              type="range"
              name="min_seeders"
              min="0"
              max="50"
              step="1"
              value={@min_seeders}
              class="range range-primary"
              phx-debounce="200"
            />
          </fieldset>
        </form>
        <label
          class="label shrink-0 cursor-pointer justify-between gap-2 border-t border-base-300 px-4 py-2"
          id="close-after-grab-toggle"
          title={gettext("Close this dialog as soon as a release is grabbed")}
        >
          <span class="text-sm">{gettext("Close after grabbing")}</span>
          <input
            type="checkbox"
            class="toggle toggle-sm toggle-primary"
            checked={@close_after_grab}
            phx-click="toggle_close_after_grab"
          />
        </label>
        <div class="shrink-0 border-t border-base-300 p-3">
          <button
            type="button"
            id="manual-search-show-results"
            class="btn btn-primary btn-block"
            phx-click={close_drawer()}
          >
            {ngettext("Show %{count} result", "Show %{count} results", @result_count)}
          </button>
        </div>
      </aside>
    </div>
    """
  end

  attr :sort_by, :atom, required: true
  attr :class, :any, default: nil

  @doc """
  The sort dropdown in the dialog's navbar, the sort control below `lg`. The
  caller hides it from `lg` with `class="lg:hidden"`, where the sortable column
  headers take over.
  """
  def sort_menu(assigns) do
    assigns = assign(assigns, :options, sort_options())

    ~H"""
    <div id="manual-search-sort" class={["dropdown dropdown-end", @class]}>
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1">
        <.icon name="hero-arrows-up-down" class="w-4 h-4" />
        <span class="hidden sm:inline">{sort_label(@sort_by)}</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm z-40 w-44 rounded-box bg-base-100 p-2 shadow-lg"
      >
        <li :for={{value, label} <- @options}>
          <button
            type="button"
            phx-click="sort_search"
            phx-value-sort_by={value}
            class={[@sort_by == value && "menu-active"]}
          >
            {label}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc "The label of a sort order."
  def sort_label(sort_by) do
    case List.keyfind(sort_options(), sort_by, 0) do
      {_value, label} -> label
      nil -> gettext("Best Score")
    end
  end

  defp quality_label("2160p"), do: "4K"
  defp quality_label(quality), do: quality

  defp active_count(assigns), do: length(chips(assigns))

  defp chips(assigns) do
    [
      {"quality", Enum.map(assigns.quality_filters, &quality_label/1)},
      {"indexer", assigns.indexer_filters},
      {"source", assigns.source_filters},
      {"codec", assigns.codec_filters}
    ]
    |> Enum.reject(fn {_dimension, values} -> values == [] end)
    |> Enum.map(fn
      # Indexer names are long and a user may tick many, so the chip names two
      # and counts the rest; the title lists them all.
      {"indexer", names} -> {"indexer", indexer_chip_label(names), Enum.join(names, ", ")}
      {dimension, values} -> {dimension, Enum.join(values, ", "), nil}
    end)
    |> then(fn chips ->
      if assigns.min_seeders > 0,
        do:
          chips ++
            [
              {"min_seeders",
               ngettext("≥ %{count} seed", "≥ %{count} seeds", assigns.min_seeders,
                 count: assigns.min_seeders
               ), nil}
            ],
        else: chips
    end)
  end

  defp indexer_chip_label([_, _, _ | _] = names) do
    {shown, rest} = Enum.split(names, 2)

    ngettext("%{indexers} +%{count} more", "%{indexers} +%{count} more", length(rest),
      indexers: Enum.join(shown, ", ")
    )
  end

  defp indexer_chip_label(names), do: Enum.join(names, ", ")
end
