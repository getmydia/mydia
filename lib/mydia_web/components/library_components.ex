defmodule MydiaWeb.LibraryComponents do
  @moduledoc """
  Reusable components for library views.

  These components provide a consistent UI for displaying library items
  across different library types (media, music, books, etc.).
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # Import only what we need to avoid circular dependency
  import MydiaWeb.CoreComponents, only: [icon: 1, progress_bar: 1, poster_badges: 1, modal: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  alias Mydia.Media.EpisodeStatus

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
  Renders a card for a library item in grid view.

  ## Attributes

    * `:item` - Required. The library item to display.
    * `:poster_url` - Required. URL of the poster/cover image.
    * `:href` - Required. The link to the item's detail page.
    * `:selection_mode` - Whether selection mode is active. Defaults to `false`.
    * `:selected` - Whether this item is selected. Defaults to `false`.
    * `:progress` - Optional playback progress struct.

  ## Slots

    * `:badges` - Optional. Slot for rendering badges in the top-right corner.
    * `:footer` - Optional. Slot for custom footer content.
  """
  attr :item, :map, required: true
  attr :poster_url, :string, required: true
  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :year, :any, default: nil
  attr :monitored, :boolean, default: false
  attr :selection_mode, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :progress, :map, default: nil
  attr :status, :any, default: nil
  attr :quality, :string, default: nil

  slot :badges
  slot :footer

  def library_card(assigns) do
    ~H"""
    <div class="relative group">
      <%!-- Selection checkbox --%>
      <%= if @selection_mode do %>
        <div class="absolute top-2 left-2 z-10">
          <input
            type="checkbox"
            class="checkbox checkbox-primary checkbox-sm"
            checked={@selected}
            phx-click="toggle_select"
            phx-value-id={@item.id}
            onclick="event.stopPropagation()"
          />
        </div>
      <% end %>

      <%!-- Monitored toggle button (outside link, hidden in selection mode) --%>
      <%= if not @selection_mode do %>
        <button
          type="button"
          phx-click="toggle_item_monitored"
          phx-value-id={@item.id}
          class={[
            "absolute top-2 left-2 p-1 rounded-lg transition-all duration-200",
            "hover:bg-base-200 hover:scale-110 active:scale-95",
            "z-10"
          ]}
          title={if @monitored, do: "Unmonitor", else: "Monitor"}
        >
          <.icon
            name={if @monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
            class={
              if @monitored,
                do: "w-5 h-5 transition-colors duration-200 text-primary",
                else: "w-5 h-5 transition-colors duration-200 text-base-content opacity-60"
            }
          />
        </button>
      <% end %>

      <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200 overflow-hidden">
        <.link navigate={@href}>
          <figure class="relative aspect-[2/3] overflow-hidden bg-base-300">
            <img
              src={@poster_url}
              alt={@title}
              class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
              loading="lazy"
            />
            <%!-- Progress indicators --%>
            <.progress_bar :if={@progress} progress={@progress} />
            <%!-- Playback status and quality, stacked in one top-right container --%>
            <.poster_badges
              id={"poster-badges-#{@item.id}"}
              progress={@progress}
              quality={@quality}
            />
            <%!-- Custom badges slot --%>
            {render_slot(@badges)}
          </figure>
        </.link>
        <div class="card-body p-3">
          <h3 class="card-title text-sm line-clamp-2" title={@title}>
            {@title}
          </h3>
          <%!-- Status badge and year --%>
          <%= if @status do %>
            <% {status_atom, counts} = @status %>
            <div class="flex flex-col gap-1">
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-1">
                  <div class="tooltip tooltip-right" data-tip={status_label(status_atom)}>
                    <span class={["badge badge-xs", status_color(status_atom)]}>
                      <.icon name={status_icon(status_atom)} class="w-3 h-3" />
                    </span>
                  </div>
                  <%!-- File indicator for unmonitored items with files --%>
                  <%= if show_file_indicator?(status_atom, counts) do %>
                    <div
                      class="tooltip tooltip-right"
                      data-tip={file_indicator_tooltip(counts)}
                    >
                      <span class="badge badge-xs badge-success">
                        <.icon name="hero-document-check" class="w-3 h-3" />
                      </span>
                    </div>
                  <% end %>
                </div>
                <span class="text-xs text-base-content/70">{format_year(@year)}</span>
              </div>
              <%= if episode_count = format_episode_count(counts) do %>
                <span class="text-xs text-base-content/70">{episode_count}</span>
              <% end %>
            </div>
          <% else %>
            <span class="text-xs text-base-content/70">{format_year(@year)}</span>
          <% end %>
          <%!-- Custom footer slot --%>
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a row for a library item in list view.

  ## Attributes

    * `:item` - Required. The library item to display.
    * `:poster_url` - Required. URL of the poster/cover image.
    * `:href` - Required. The link to the item's detail page.
    * `:title` - Required. The display title.
    * `:secondary_text` - Optional secondary text (e.g., original title).
    * `:year` - The year value to display.
    * `:monitored` - Whether the item is monitored.
    * `:selection_mode` - Whether selection mode is active.
    * `:selected` - Whether this item is selected.
    * `:progress` - Optional playback progress struct.
    * `:status` - Status tuple from get_media_status.
    * `:quality` - Quality resolution string.
    * `:file_size` - Total file size in bytes.
  """
  attr :item, :map, required: true
  attr :poster_url, :string, required: true
  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :secondary_text, :string, default: nil
  attr :year, :any, default: nil
  attr :monitored, :boolean, default: false
  attr :selection_mode, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :progress, :map, default: nil
  attr :status, :any, default: nil
  attr :quality, :string, default: nil
  attr :file_size, :integer, default: 0

  def library_row(assigns) do
    ~H"""
    <div class="flex items-center px-4 py-3 hover:bg-base-200/50 border-b border-base-200 last:border-b-0 odd:bg-base-100 even:bg-base-200/30 transition-colors">
      <%!-- Checkbox/Bookmark column --%>
      <div class="w-10 flex-shrink-0">
        <%= if @selection_mode do %>
          <input
            type="checkbox"
            class="checkbox checkbox-primary checkbox-sm"
            checked={@selected}
            phx-click="toggle_select"
            phx-value-id={@item.id}
          />
        <% else %>
          <button
            type="button"
            phx-click="toggle_item_monitored"
            phx-value-id={@item.id}
            class="btn btn-ghost btn-xs btn-circle"
            title={if @monitored, do: "Unmonitor", else: "Monitor"}
          >
            <.icon
              name={if @monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
              class={
                if @monitored,
                  do: "w-4 h-4 text-primary",
                  else: "w-4 h-4 text-base-content/40"
              }
            />
          </button>
        <% end %>
      </div>
      <%!-- Poster column --%>
      <div class="w-14 flex-shrink-0">
        <.link navigate={@href} class="block w-10">
          <img
            src={@poster_url}
            alt={@title}
            loading="lazy"
            class="w-10 h-14 rounded shadow-sm object-cover bg-base-300"
          />
        </.link>
      </div>
      <%!-- Title column --%>
      <div class="flex-1 min-w-0 pr-4">
        <div class="flex items-center gap-2">
          <div class="flex-1 min-w-0">
            <.link
              navigate={@href}
              class="font-medium hover:text-primary transition-colors line-clamp-1"
            >
              {@title}
            </.link>
            <%= if @secondary_text do %>
              <div class="text-sm text-base-content/60 line-clamp-1">
                {@secondary_text}
              </div>
            <% end %>
          </div>
          <%!-- Progress indicator for list view --%>
          <%= if @progress do %>
            <%= if @progress.watched do %>
              <span class="badge badge-success badge-sm gap-1 flex-shrink-0">
                <.icon name="hero-check" class="w-3 h-3" /> Watched
              </span>
            <% else %>
              <span class="badge badge-primary badge-sm flex-shrink-0">
                {round(@progress.completion_percentage)}%
              </span>
            <% end %>
          <% end %>
        </div>
      </div>
      <%!-- Year column --%>
      <div class="w-20 hidden md:block text-center text-base-content/70 flex-shrink-0">
        {format_year(@year)}
      </div>
      <%!-- Status column --%>
      <div class="w-28 hidden lg:block flex-shrink-0">
        <%= if @status do %>
          <% {status_atom, counts} = @status %>
          <div class="flex flex-col gap-0.5">
            <div class="flex items-center gap-1">
              <div class="tooltip tooltip-left" data-tip={status_label(status_atom)}>
                <span class={["badge badge-sm gap-1", status_color(status_atom)]}>
                  <.icon name={status_icon(status_atom)} class="w-3 h-3" />
                </span>
              </div>
              <%!-- File indicator for unmonitored items with files --%>
              <%= if show_file_indicator?(status_atom, counts) do %>
                <div
                  class="tooltip tooltip-left"
                  data-tip={file_indicator_tooltip(counts)}
                >
                  <span class="badge badge-sm badge-success">
                    <.icon name="hero-document-check" class="w-3 h-3" />
                  </span>
                </div>
              <% end %>
            </div>
            <%= if episode_count = format_episode_count(counts) do %>
              <span class="text-xs text-base-content/60">{episode_count}</span>
            <% end %>
          </div>
        <% end %>
      </div>
      <%!-- Quality column --%>
      <div class="w-20 hidden lg:block text-center flex-shrink-0">
        <%= if @quality do %>
          <span class="badge badge-primary badge-sm">{@quality}</span>
        <% else %>
          <span class="text-base-content/40">—</span>
        <% end %>
      </div>
      <%!-- Size column --%>
      <div class="w-24 hidden xl:block text-right text-base-content/70 text-sm flex-shrink-0">
        {format_file_size(@file_size)}
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

  ## Attributes

    * `:view_mode` - Required. Current view mode (:grid or :list).
  """
  attr :view_mode, :atom, required: true

  def view_mode_toggle(assigns) do
    ~H"""
    <div class="join">
      <button
        type="button"
        class={[
          "btn btn-sm join-item",
          @view_mode == :grid && "btn-primary",
          @view_mode != :grid && "btn-ghost"
        ]}
        phx-click="toggle_view"
        phx-value-mode="grid"
      >
        <.icon name="hero-squares-2x2" class="w-5 h-5" />
        <span class="hidden sm:inline ml-1">Grid</span>
      </button>
      <button
        type="button"
        class={[
          "btn btn-sm join-item",
          @view_mode == :list && "btn-primary",
          @view_mode != :list && "btn-ghost"
        ]}
        phx-click="toggle_view"
        phx-value-mode="list"
      >
        <.icon name="hero-list-bullet" class="w-5 h-5" />
        <span class="hidden sm:inline ml-1">List</span>
      </button>
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

  # Helper functions

  defp format_year(nil), do: "N/A"
  defp format_year(year), do: year

  defp format_file_size(nil), do: "N/A"
  defp format_file_size(0), do: "—"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_episode_count(nil), do: nil

  defp format_episode_count(%{downloaded: downloaded, total: total}) do
    "#{downloaded}/#{total} episodes"
  end

  defp format_episode_count(_), do: nil

  defp status_color(status), do: EpisodeStatus.status_color(status)
  defp status_icon(status), do: EpisodeStatus.status_icon(status)
  defp status_label(status), do: EpisodeStatus.status_label(status)

  defp show_file_indicator?(status, counts) do
    status == :not_monitored && has_files?(counts)
  end

  defp has_files?(nil), do: false
  defp has_files?(%{has_files: has_files}), do: has_files
  defp has_files?(%{downloaded: downloaded}), do: downloaded > 0

  defp file_indicator_tooltip(counts) do
    case counts do
      %{file_count: count} when count > 0 ->
        "#{count} file#{if count == 1, do: "", else: "s"} available"

      %{downloaded: downloaded, total: _total} when downloaded > 0 ->
        "#{downloaded} episode#{if downloaded == 1, do: "", else: "s"} downloaded"

      _ ->
        "Files available"
    end
  end
end
