defmodule MydiaWeb.AdminImportListsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.ImportLists.ImportList
  alias MydiaWeb.AdminImportListsLive.Index

  @doc "The page header's Sync All and New TMDB List buttons."
  def header_actions(assigns) do
    ~H"""
    <button id="sync-all-import-lists" class="btn btn-sm btn-ghost" phx-click="sync_all">
      <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync All
    </button>
    <button id="new-import-list" class="btn btn-sm btn-primary" phx-click="new_import_list">
      <.icon name="hero-plus" class="w-4 h-4" /> New TMDB List
    </button>
    """
  end

  attr :import_lists, :list, required: true
  attr :presets, :list, required: true
  attr :configured_presets, :any, required: true
  attr :syncing_list_id, :any, required: true

  def import_lists_tab(assigns) do
    assigns =
      assign(
        assigns,
        :available_presets,
        Enum.reject(assigns.presets, fn preset ->
          Index.preset_configured?(assigns.configured_presets, preset.type, preset.media_type)
        end)
      )

    ~H"""
    <div class="space-y-6 mt-6">
      <.admin_section id="import-lists-quick-add" title="Quick Add" icon="hero-bolt">
        <%= if @available_presets == [] do %>
          <p class="text-sm text-base-content/60">All presets enabled</p>
        <% else %>
          <div class="flex flex-wrap gap-2">
            <button
              :for={preset <- @available_presets}
              id={"enable-preset-#{preset.id}"}
              phx-click="enable_preset"
              phx-value-preset-id={preset.id}
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-base-200 border border-base-300 hover:border-primary hover:bg-primary/5 text-sm transition-colors"
              title={preset.description}
            >
              <.icon
                name={Index.media_type_icon(preset.media_type)}
                class="w-3.5 h-3.5 text-base-content/60"
              />
              {preset.name}
              <.icon name="hero-plus" class="w-3 h-3 text-primary" />
            </button>
          </div>
        <% end %>
      </.admin_section>

      <.admin_section id="import-lists-section" title="Active Lists" icon="hero-list-bullet">
        <.admin_list id="import-lists" items={@import_lists}>
          <:row :let={list}>
            <.import_list_row list={list} syncing?={@syncing_list_id == list.id} />
          </:row>
          <:empty>
            No import lists configured. Enable a preset above or create a custom list.
          </:empty>
        </.admin_list>
      </.admin_section>
    </div>
    """
  end

  attr :list, ImportList, required: true
  attr :syncing?, :boolean, required: true

  defp import_list_row(assigns) do
    assigns =
      assigns
      |> assign(:pending, Index.pending_count(assigns.list))
      |> assign(:descriptor, descriptor(assigns.list))

    ~H"""
    <.admin_row id={"import-list-#{@list.id}"} class={if(!@list.enabled, do: "opacity-60")}>
      <:title>
        <.icon name={Index.media_type_icon(@list.media_type)} class="w-4 h-4 opacity-60" />
        {@list.name}
      </:title>
      <:descriptor>{@descriptor}</:descriptor>
      <:details :if={@list.sync_error}>
        <p class="text-error flex items-start gap-1">
          <.icon name="hero-exclamation-circle" class="w-4 h-4 shrink-0 mt-0.5" />
          <span>{@list.sync_error}</span>
        </p>
      </:details>
      <:badges>
        <input
          id={"toggle-import-list-#{@list.id}"}
          type="checkbox"
          class="toggle toggle-sm toggle-success shrink-0"
          checked={@list.enabled}
          phx-click="toggle_import_list"
          phx-value-id={@list.id}
          title={if @list.enabled, do: "Disable", else: "Enable"}
        />
        <span :if={@list.auto_add} class="badge badge-info badge-sm badge-outline gap-1">
          <.icon name="hero-bolt" class="w-3 h-3" /> Auto-add
        </span>
        <span
          :if={@list.target_collection}
          class="badge badge-accent badge-sm badge-outline gap-1"
          title={"Add to: #{@list.target_collection.name}"}
        >
          <.icon name="hero-folder" class="w-3 h-3" /> {@list.target_collection.name}
        </span>
        <span class="badge badge-ghost badge-sm">{Index.item_count_badge(@list)}</span>
        <button
          :if={@pending > 0 and not @list.auto_add}
          id={"add-pending-import-list-#{@list.id}"}
          phx-click="add_pending_from_table"
          phx-value-id={@list.id}
          class="badge badge-warning badge-sm gap-1 hover:brightness-110 cursor-pointer"
          title={"Add #{@pending} pending items to library"}
        >
          <.icon name="hero-plus" class="w-3 h-3" /> {@pending} pending
        </button>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"sync-import-list-#{@list.id}"}
            icon="hero-arrow-path"
            title="Sync"
            loading={@syncing?}
            phx-click="sync_import_list"
            phx-value-id={@list.id}
          />
          <.row_action
            id={"view-import-list-items-#{@list.id}"}
            icon="hero-list-bullet"
            title="Items"
            phx-click="view_import_list_items"
            phx-value-id={@list.id}
          />
          <.row_action
            id={"edit-import-list-#{@list.id}"}
            icon="hero-pencil"
            title="Edit"
            phx-click="edit_import_list"
            phx-value-id={@list.id}
          />
          <.row_action
            id={"delete-import-list-#{@list.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            phx-click="delete_import_list"
            phx-value-id={@list.id}
            data-confirm="Are you sure you want to delete this import list?"
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  defp descriptor(list) do
    media = if list.media_type == "movie", do: "Movies", else: "TV Shows"

    Enum.join(
      [
        ImportList.type_label(list.type),
        media,
        ImportList.sync_interval_label(list.sync_interval),
        "Synced " <> Index.format_last_synced(list.last_synced_at)
      ],
      " · "
    )
  end
end
