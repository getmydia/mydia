defmodule MydiaWeb.LibraryComponents do
  @moduledoc """
  Reusable components for library views.

  These components provide a consistent UI for displaying library items
  across different library types (media, music, books, etc.).
  """
  use Phoenix.Component

  # Import only what we need to avoid circular dependency
  import MydiaWeb.CoreComponents, only: [icon: 1, modal: 1]
  import MydiaWeb.SegmentedControl, only: [segmented_control: 1]

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

  The buttons are icon-only. `MydiaWeb.SegmentedControl` owns the accessible
  naming, the tooltip wrapper and the `join-item` placement that icon-only
  segments need; see its moduledoc for why each is shaped the way it is.

  Kept in step with `MydiaWeb.GridDensityComponents.grid_density_toggle/1`,
  which sits directly beside this on the Libraries toolbar.

  ## Attributes

    * `:view_mode` - Required. Current view mode (:grid or :list).
  """
  attr :view_mode, :atom, required: true

  def view_mode_toggle(assigns) do
    ~H"""
    <.segmented_control
      value={@view_mode}
      event="toggle_view"
      param="mode"
      label="View mode"
      icon_only
    >
      <:option value="grid" label="Grid" icon="hero-squares-2x2" />
      <:option value="list" label="List" icon="hero-list-bullet" />
    </.segmented_control>
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
  Renders selection controls for the header area.

  ## Attributes

    * `:id` - Optional DOM id for the toggle button.
    * `:selection_mode` - Whether selection mode is active.
    * `:selected_count` - Number of selected items.
  """
  attr :id, :string, default: nil
  attr :selection_mode, :boolean, required: true
  attr :selected_count, :integer, required: true

  def selection_controls(assigns) do
    ~H"""
    <button
      id={@id}
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

      <form id={"#{@id}-form"} phx-change="toggle_delete_files">
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
              <div class="font-medium mb-1">Delete from disk</div>
              <div class="text-sm opacity-75 flex items-center gap-1">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                <span>Permanently deletes all files - cannot be undone</span>
              </div>
              <p id={"#{@id}-disk-note"} class="text-sm opacity-75 mt-1">
                Deletes each item's folder and everything in it. A folder that also holds
                other media is kept, and only the item's files are removed from it.
              </p>
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
  The caret half of the "Add to Library" split button.

  Opens `MydiaWeb.AddMediaComponents.add_config_modal/1`, which every host
  renders once per page. It renders unconditionally: the dialog behind it now
  carries the quality profile, monitoring and search-on-add controls, so it is
  worth reaching on a single-library install, which the old
  `length(@libraries) > 1` gate hid it from.

  This is a real `<button>` rather than a `div[role="button"]` because it does
  not drive a CSS `:focus` dropdown. It pushes an event and the host opens the
  dialog.
  """
  attr :ref, :string, default: nil
  attr :media_type, :any, default: nil
  attr :title, :string, default: ""

  attr :size, :string,
    default: "sm",
    values: ~w(sm md),
    doc: "Match the button it is joined to. Cards use sm, the preview modal md."

  def library_picker_button(assigns) do
    ~H"""
    <button
      type="button"
      data-test="add-config-caret"
      class={["btn btn-primary join-item px-2", @size == "sm" && "btn-sm"]}
      title="Configure before adding"
      phx-click="open_add_config"
      phx-value-ref={@ref}
      phx-value-media_type={@media_type}
      phx-value-title={@title}
    >
      <.icon name="hero-chevron-down" class="w-3 h-3" />
    </button>
    """
  end
end
