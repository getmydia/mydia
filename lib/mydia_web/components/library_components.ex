defmodule MydiaWeb.LibraryComponents do
  @moduledoc """
  Reusable components for library views.

  These components provide a consistent UI for displaying library items
  across different library types (media, music, books, etc.).
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # Import only what we need to avoid circular dependency
  import MydiaWeb.CoreComponents, only: [icon: 1, modal: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  @doc """
  Renders a grid view for library items.

  ## Attributes

    * `:id` - Required. The DOM id for the grid container.
    * `:items` - Required. The stream of items to display.
    * `:selection_mode` - Whether selection mode is active. Defaults to `false`.
    * `:selected_ids` - MapSet of selected item IDs. Defaults to empty MapSet.
    * `:class` - Additional CSS classes for the grid container.

  ## Slots

    * `:item` - Required. Slot for rendering each item. Receives the item as an argument.
  """
  attr :id, :string, required: true
  attr :items, :any, required: true
  attr :selection_mode, :boolean, default: false
  attr :selected_ids, :any, default: MapSet.new()
  attr :class, :string, default: nil

  slot :item, required: true

  def library_grid(assigns) do
    ~H"""
    <div
      id={@id}
      phx-update="stream"
      phx-viewport-bottom="load_more"
      class={[
        "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3 md:gap-4 pb-6 md:pb-8",
        @class
      ]}
    >
      <div
        :for={{id, item} <- @items}
        id={id}
      >
        {render_slot(@item, item)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a list view for library items.

  ## Attributes

    * `:id` - Required. The DOM id for the list container.
    * `:items` - Required. The stream of items to display.
    * `:show_tv_columns` - Whether to show TV-specific columns. Defaults to `false`.
    * `:class` - Additional CSS classes for the list container.

  ## Slots

    * `:item` - Required. Slot for rendering each item row. Receives the item as an argument.
  """
  attr :id, :string, required: true
  attr :items, :any, required: true
  attr :show_tv_columns, :boolean, default: false
  attr :class, :string, default: nil

  slot :item, required: true

  def library_list(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-lg overflow-hidden", @class]}>
      <%!-- List View Header --%>
      <div class="flex items-center bg-base-200 font-semibold text-sm px-4 py-3 border-b border-base-300">
        <div class="w-10 flex-shrink-0"></div>
        <div class="w-14 flex-shrink-0"></div>
        <div class="flex-1 min-w-0">Title</div>
        <div class="w-20 hidden md:block text-center flex-shrink-0">Year</div>
        <div class="w-28 hidden lg:block flex-shrink-0">Status</div>
        <div class="w-20 hidden lg:block text-center flex-shrink-0">Quality</div>
        <div class="w-24 hidden xl:block text-right flex-shrink-0">Size</div>
      </div>

      <%!-- List Items --%>
      <div
        id={@id}
        phx-update="stream"
        phx-viewport-bottom="load_more"
      >
        <div
          :for={{id, item} <- @items}
          id={id}
          class="contents"
        >
          {render_slot(@item, item)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders filter controls for a library view.

  ## Attributes

    * `:search_query` - Current search query. Defaults to empty string.
    * `:filter_monitored` - Current monitored filter value.
    * `:filter_quality` - Current quality filter value.
    * `:sort_by` - Current sort field.
    * `:show_tv_sorts` - Whether to show TV-specific sort options.
  """
  attr :search_query, :string, default: ""
  attr :filter_monitored, :any, default: nil
  attr :filter_quality, :string, default: nil
  attr :sort_by, :string, default: "title_asc"
  attr :show_tv_sorts, :boolean, default: false

  def library_filters(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row gap-3 md:gap-4 mb-4 md:mb-6">
      <%!-- Search input --%>
      <div class="flex-1">
        <.form for={%{}} phx-change="search" id="library-search-form" class="w-full">
          <input
            type="text"
            name="search"
            value={@search_query}
            placeholder="Search media..."
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </.form>
      </div>

      <%!-- Filters and Sort --%>
      <.form for={%{}} phx-change="filter" id="library-filter-form" class="join">
        <select
          name="monitored"
          class="select select-bordered join-item"
        >
          <option value="all" selected={is_nil(@filter_monitored)}>All Status</option>
          <option value="true" selected={@filter_monitored == true}>Monitored</option>
          <option value="false" selected={@filter_monitored == false}>Unmonitored</option>
        </select>

        <select
          name="quality"
          class="select select-bordered join-item"
        >
          <option value="" selected={is_nil(@filter_quality)}>All Quality</option>
          <option value="720p" selected={@filter_quality == "720p"}>720p</option>
          <option value="1080p" selected={@filter_quality == "1080p"}>1080p</option>
          <option value="2160p" selected={@filter_quality == "2160p"}>4K</option>
        </select>

        <select
          name="sort_by"
          class="select select-bordered join-item"
          title="Sort by"
        >
          <optgroup label="General">
            <option value="title_asc" selected={@sort_by == "title_asc"}>Title (A-Z)</option>
            <option value="title_desc" selected={@sort_by == "title_desc"}>Title (Z-A)</option>
            <option value="year_desc" selected={@sort_by == "year_desc"}>Year (Newest)</option>
            <option value="year_asc" selected={@sort_by == "year_asc"}>Year (Oldest)</option>
            <option value="added_desc" selected={@sort_by == "added_desc"}>Added (Newest)</option>
            <option value="added_asc" selected={@sort_by == "added_asc"}>Added (Oldest)</option>
            <option value="rating_desc" selected={@sort_by == "rating_desc"}>
              Rating (High)
            </option>
            <option value="rating_asc" selected={@sort_by == "rating_asc"}>Rating (Low)</option>
          </optgroup>
          <%= if @show_tv_sorts do %>
            <optgroup label="TV Shows">
              <option value="last_aired_desc" selected={@sort_by == "last_aired_desc"}>
                Last Aired (Recent)
              </option>
              <option value="last_aired_asc" selected={@sort_by == "last_aired_asc"}>
                Last Aired (Oldest)
              </option>
              <option value="next_aired_asc" selected={@sort_by == "next_aired_asc"}>
                Next Airing (Soon)
              </option>
              <option value="next_aired_desc" selected={@sort_by == "next_aired_desc"}>
                Next Airing (Later)
              </option>
              <option value="episode_count_desc" selected={@sort_by == "episode_count_desc"}>
                Episodes (Most)
              </option>
              <option value="episode_count_asc" selected={@sort_by == "episode_count_asc"}>
                Episodes (Least)
              </option>
            </optgroup>
          <% end %>
        </select>
      </.form>
    </div>
    """
  end

  @doc """
  Renders an empty state for a library view.

  ## Attributes

    * `:icon` - Required. The heroicon name to display.
    * `:title` - Required. The title text.
    * `:message` - Required. The message text.
    * `:icon_class` - Additional CSS classes for the icon. Defaults to "text-base-content/30".
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :icon_class, :string, default: "text-base-content/30"

  slot :actions

  def library_empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16">
      <.icon name={@icon} class={"w-16 h-16 mb-4 " <> @icon_class} />
      <h3 class="text-xl font-semibold text-base-content/70 mb-2">{@title}</h3>
      <p class="text-base-content/50 text-center max-w-md">
        {@message}
      </p>
      <%= if @actions != [] do %>
        <div class="mt-4">
          {render_slot(@actions)}
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a view mode toggle (grid/list).

  Icon-only, so `aria-label` carries each button's accessible name and
  `aria-pressed` its state. `aria-pressed` is wrapped in `to_string/1` because
  HEEx renders a `true` attribute value as a bare attribute and omits it for
  `false`, and ARIA needs the literal strings.

  Each tooltip sits on a wrapper `div` rather than on the button. daisyUI
  reveals the tip via `.tooltip:has(:focus-visible)`, and `:has()` implies a
  descendant combinator, so a `.tooltip` button whose only descendant is the
  non-focusable icon `<span>` never shows its tip to a keyboard user.

  `join-item` stays on the button and is deliberately kept off the wrapper:
  `.join-item > *` resets `--join-ss`/`--join-se`/`--join-es`/`--join-ee` to
  `initial`, so a button nested inside a `join-item` wrapper computes every
  corner to 0 and the filled active button spills square out of the join's
  rounded end cap. Left off the wrapper, the join's radius variables inherit
  straight through to the button and the caps render as before.

  Kept in step with `MydiaWeb.GridDensityComponents.grid_density_toggle/1`,
  which sits directly beside this on the Libraries toolbar.

  ## Attributes

    * `:view_mode` - Required. Current view mode (:grid or :list).
  """
  attr :view_mode, :atom, required: true

  def view_mode_toggle(assigns) do
    ~H"""
    <div class="join" role="group" aria-label="View mode">
      <div class="tooltip tooltip-bottom" data-tip="Grid">
        <button
          type="button"
          class={[
            "btn btn-sm btn-square join-item",
            @view_mode == :grid && "btn-primary",
            @view_mode != :grid && "btn-ghost"
          ]}
          phx-click="toggle_view"
          phx-value-mode="grid"
          aria-label="Grid"
          aria-pressed={to_string(@view_mode == :grid)}
        >
          <.icon name="hero-squares-2x2" class="w-4 h-4" />
        </button>
      </div>
      <div class="tooltip tooltip-bottom" data-tip="List">
        <button
          type="button"
          class={[
            "btn btn-sm btn-square join-item",
            @view_mode == :list && "btn-primary",
            @view_mode != :list && "btn-ghost"
          ]}
          phx-click="toggle_view"
          phx-value-mode="list"
          aria-label="List"
          aria-pressed={to_string(@view_mode == :list)}
        >
          <.icon name="hero-list-bullet" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a loading indicator for infinite scroll.
  """
  attr :visible, :boolean, default: true

  def loading_indicator(assigns) do
    ~H"""
    <%= if @visible do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-md text-primary"></span>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a floating action toolbar for batch operations.

  ## Attributes

    * `:selected_count` - Required. Number of selected items.
    * `:selection_mode` - Whether selection mode is active. When true, shows toolbar in selection mode.
    * `:all_selected` - Whether all items are selected (for select all checkbox).
    * `:show` - Whether to show the toolbar. Defaults to showing when in selection_mode or count > 0.
  """
  attr :selected_count, :integer, required: true
  attr :selection_mode, :boolean, default: false
  attr :all_selected, :boolean, default: false
  attr :show, :boolean, default: nil

  slot :actions, required: true

  def batch_action_toolbar(assigns) do
    # Show toolbar if: explicit show=true, or in selection_mode, or has selected items
    show =
      cond do
        not is_nil(assigns.show) -> assigns.show
        assigns.selection_mode -> true
        true -> assigns.selected_count > 0
      end

    has_selection = assigns.selected_count > 0
    assigns = assign(assigns, show: show, has_selection: has_selection)

    ~H"""
    <%= if @show do %>
      <div class="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 animate-in slide-in-from-bottom duration-300">
        <div class="bg-base-100 shadow-2xl rounded-box border border-base-300 px-2 py-2">
          <div class="flex items-center gap-1">
            <%!-- Select All checkbox with count --%>
            <%= if @selection_mode do %>
              <label
                class="flex items-center gap-2 px-3 py-1.5 rounded-lg hover:bg-base-200 cursor-pointer transition-colors"
                title={if @all_selected, do: "Deselect all", else: "Select all"}
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm checkbox-primary"
                  checked={@all_selected}
                  phx-click={
                    JS.push("toggle_select_all")
                    |> JS.dispatch("mydia:toggle-select-all", to: "#media-items")
                  }
                />
                <%= if @selected_count == 0 do %>
                  <span class="text-sm">Select All</span>
                <% else %>
                  <span class="font-medium tabular-nums">{@selected_count}</span>
                  <span class="text-sm text-base-content/60 hidden sm:inline">selected</span>
                <% end %>
              </label>
            <% else %>
              <div class="flex items-center gap-2 px-3 py-1.5">
                <span class="font-medium tabular-nums">{@selected_count}</span>
                <span class="text-sm text-base-content/60">selected</span>
              </div>
            <% end %>

            <div class="w-px h-6 bg-base-300 mx-1"></div>

            <%!-- Action buttons slot --%>
            <div class="flex items-center">
              {render_slot(@actions, @has_selection)}
            </div>

            <div class="w-px h-6 bg-base-300 mx-1"></div>

            <%!-- Done button (in selection mode) or Close button (legacy) --%>
            <%= if @selection_mode do %>
              <button
                type="button"
                class="btn btn-sm btn-primary"
                phx-click="toggle_selection_mode"
                title="Done (Esc)"
              >
                Done
              </button>
            <% else %>
              <button
                type="button"
                class="btn btn-sm btn-ghost btn-square"
                phx-click={
                  JS.push("clear_selection")
                  |> JS.dispatch("mydia:clear-selection", to: "#media-items")
                }
                title="Clear selection (Esc)"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders selection controls for the header area.

  ## Attributes

    * `:selection_mode` - Whether selection mode is active.
    * `:selected_count` - Number of selected items.
  """
  attr :selection_mode, :boolean, required: true
  attr :selected_count, :integer, required: true

  def selection_controls(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-sm gap-1", @selection_mode && "btn-active"]}
      phx-click="toggle_selection_mode"
      title={if @selection_mode, do: "Exit selection mode", else: "Enter selection mode"}
    >
      <.icon name="hero-check-circle" class="w-4 h-4" />
      <span class="hidden sm:inline">
        {if @selection_mode, do: "Selecting", else: "Select"}
      </span>
    </button>
    """
  end

  @doc """
  Renders a delete confirmation modal with file deletion options.

  ## Attributes

    * `:id` - Required. The modal ID.
    * `:show` - Whether to show the modal.
    * `:selected_count` - Number of items to delete.
    * `:delete_files` - Whether file deletion is selected.
    * `:item_label` - Label for items (default: "Item"/"Items").
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :selected_count, :integer, required: true
  attr :delete_files, :boolean, required: true
  attr :item_label, :string, default: nil

  def delete_confirmation_modal(assigns) do
    item_word =
      if assigns.item_label do
        if assigns.selected_count == 1, do: assigns.item_label, else: assigns.item_label <> "s"
      else
        if assigns.selected_count == 1, do: "Item", else: "Items"
      end

    assigns = assign(assigns, :item_word, item_word)

    ~H"""
    <.modal id={@id} show={@show} on_cancel="cancel_delete">
      <:title>
        Delete <strong>{@selected_count}</strong> {@item_word}?
      </:title>

      <form phx-change="toggle_delete_files">
        <div class="space-y-2.5">
          <label class={[
            "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
            !@delete_files && "border-primary bg-primary/10",
            @delete_files && "border-base-300 hover:border-primary/50"
          ]}>
            <input
              type="radio"
              name="delete_files"
              value="false"
              class="radio radio-primary mt-0.5 flex-shrink-0"
              checked={!@delete_files}
            />
            <div>
              <div class="font-medium mb-1">Remove from library only</div>
              <div class="text-sm opacity-75">Files stay on disk, can be re-imported later</div>
            </div>
          </label>

          <label class={[
            "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
            @delete_files && "border-error bg-error/10",
            !@delete_files && "border-base-300 hover:border-error/50"
          ]}>
            <input
              type="radio"
              name="delete_files"
              value="true"
              class="radio radio-error mt-0.5 flex-shrink-0"
              checked={@delete_files}
            />
            <div>
              <div class="font-medium mb-1">Delete files from disk</div>
              <div class="text-sm opacity-75 flex items-center gap-1">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                <span>Permanently deletes all files - cannot be undone</span>
              </div>
            </div>
          </label>
        </div>
      </form>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="cancel_delete">
          Cancel
        </button>
        <button
          type="button"
          class={["btn", (@delete_files && "btn-error") || "btn-warning"]}
          phx-click="batch_delete_confirmed"
        >
          <.icon name="hero-trash" class="w-4 h-4" />
          {if @delete_files, do: "Delete Everything", else: "Remove from Library"}
        </button>
      </:actions>
    </.modal>
    """
  end

  @doc """
  A caret button opening a menu of target libraries.

  Renders nothing when there are fewer than two candidates, so a single-library
  install sees the plain add button exactly as before.

  Libraries have no `name` column, only `path`, so each entry shows the
  basename with the full path as secondary text.
  """
  attr :libraries, :list, required: true
  attr :event, :string, required: true
  attr :tmdb_id, :any, default: nil
  attr :media_type, :any, default: nil
  attr :selected_id, :string, default: nil

  # A host that has no room below the caret opens the menu upward instead. An
  # atom with `values:` rather than a pass-through class string, so a typo is a
  # compile error and daisyUI class names stay inside this component.
  attr :placement, :atom, default: :bottom, values: [:bottom, :top]

  def library_picker_menu(assigns) do
    ~H"""
    <div
      :if={length(@libraries) > 1}
      class={["dropdown dropdown-end z-20", @placement == :top && "dropdown-top"]}
    >
      <div
        tabindex="0"
        role="button"
        data-test="library-picker-caret"
        class="btn btn-primary btn-sm join-item px-2"
        title="Choose a library"
      >
        <.icon name="hero-chevron-down" class="w-3 h-3" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu p-2 shadow-lg bg-base-100 rounded-box w-60 border border-base-300"
      >
        <li class="menu-title text-xs">Add to library</li>
        <li :for={library <- @libraries}>
          <button
            type="button"
            phx-click={@event}
            phx-value-library_path_id={library.id}
            phx-value-tmdb_id={@tmdb_id}
            phx-value-media_type={@media_type}
            class="flex-col items-start gap-0"
          >
            <span class="font-medium">{Path.basename(library.path)}</span>
            <span class="text-xs text-base-content/50 truncate w-full">{library.path}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  The caret half of the "Add to Library" split button.

  Renders nothing when there are fewer than two candidates, so a
  single-library install sees the plain add button exactly as before.

  This is a real `<button>` rather than a `div[role="button"]` because it no
  longer drives a CSS `:focus` dropdown. It pushes an event and the host opens
  `library_picker_dialog/1`.
  """
  attr :libraries, :list, required: true
  attr :tmdb_id, :any, default: nil
  attr :media_type, :any, default: nil
  attr :title, :string, default: ""

  def library_picker_button(assigns) do
    ~H"""
    <button
      :if={length(@libraries) > 1}
      type="button"
      data-test="library-picker-caret"
      class="btn btn-primary btn-sm join-item px-2"
      title="Choose a library"
      phx-click="open_library_picker"
      phx-value-tmdb_id={@tmdb_id}
      phx-value-media_type={@media_type}
      phx-value-title={@title}
    >
      <.icon name="hero-chevron-down" class="w-3 h-3" />
    </button>
    """
  end

  @doc """
  The library chooser, rendered once per host LiveView.

  An anchored dropdown inside the card cannot work here. The sidebar is
  `z-40`, the mobile dock is `z-50` and the sticky header is `z-30`, so any
  value a card claims either loses to the chrome or paints over it during
  ordinary browsing, and a horizontal rail's `overflow` clips the menu
  whatever its z-index. A page-level `.modal` is `position: fixed; inset: 0;
  z-index: 999`, which sidesteps both problems.

  The explicit `z-[1000]` puts the picker above the trending detail modal,
  which is also a `.modal` at 999, without depending on which of the two
  happens to come later in the DOM.

  Libraries have no `name` column, only `path`, so each entry shows the
  basename with the full path as secondary text.
  """
  attr :picker, :map,
    default: nil,
    doc: "nil, or %{tmdb_id:, media_type:, title:, libraries:} for the card being added"

  attr :event, :string, default: "add_to_library"
  attr :on_cancel, :string, default: "close_library_picker"

  def library_picker_dialog(assigns) do
    ~H"""
    <dialog
      id="library-picker-dialog"
      class="modal z-[1000]"
      open={@picker != nil}
      phx-window-keydown={@picker && @on_cancel}
      phx-key="Escape"
    >
      <div :if={@picker} class="modal-box max-w-md">
        <h3 class="font-bold text-lg">Add to which library?</h3>
        <p class="text-sm text-base-content/60 mt-1 truncate">{@picker.title}</p>

        <ul class="menu w-full mt-4 p-0">
          <li :for={library <- @picker.libraries}>
            <button
              type="button"
              data-test="library-picker-option"
              phx-click={@event}
              phx-value-library_path_id={library.id}
              phx-value-tmdb_id={@picker.tmdb_id}
              phx-value-media_type={@picker.media_type}
              class="flex-col items-start gap-0"
            >
              <span class="font-medium">{Path.basename(library.path)}</span>
              <span class="text-xs text-base-content/50 truncate w-full">{library.path}</span>
            </button>
          </li>
        </ul>

        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>Cancel</button>
        </div>
      </div>

      <%!-- A <dialog> opened through the `open` attribute rather than
           showModal() gets no ::backdrop and no Escape handling, which is why
           the keydown above and this click target both exist. Same approach
           as TrendingDetailModal. --%>
      <div class="modal-backdrop bg-black/70">
        <button type="button" phx-click={@on_cancel}>close</button>
      </div>
    </dialog>
    """
  end
end
