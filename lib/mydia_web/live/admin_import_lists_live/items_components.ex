defmodule MydiaWeb.AdminImportListsLive.ItemsComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminImportListsLive.Index

  @status_legend [
    {"badge-warning", :pending},
    {"badge-success", :in_library},
    {"badge-error", :failed}
  ]

  defp legend_text(:pending), do: gettext("Pending = Waiting to add")
  defp legend_text(:in_library), do: gettext("In library = Already in your library")
  defp legend_text(:failed), do: gettext("Failed = Error occurred")

  attr :selected_list, :any, required: true
  attr :items, :list, required: true
  attr :items_filter, :string, required: true
  attr :total_count, :integer, required: true

  def import_list_items_modal(assigns) do
    assigns = assign(assigns, :status_legend, @status_legend)

    ~H"""
    <.admin_modal
      id="import-list-items-modal"
      icon={Index.media_type_icon(@selected_list.media_type)}
      title={gettext("%{name} - Items", name: @selected_list.name)}
      size={:lg}
      on_close="close_import_list_items_modal"
    >
      <div class="flex flex-wrap gap-2 mb-4 text-xs">
        <div :for={{badge, key} <- @status_legend} class="flex items-center gap-1">
          <span class={["badge badge-xs", badge]}></span>
          <span class="text-base-content/60">{legend_text(key)}</span>
        </div>
      </div>

      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-4">
        <.segmented_control
          id="import-list-items-filter"
          value={@items_filter}
          event="filter_import_list_items"
          param="status"
          label={gettext("Filter items by status")}
        >
          <:option value="to_add" label={gettext("To add")} />
          <:option value="in_library" label={gettext("In library")} />
          <:option value="all" label={pgettext("selection", "All")} />
        </.segmented_control>

        <button
          :if={Index.pending_items_in_list?(@items)}
          id="add-all-pending-import-list-items"
          phx-click="add_all_pending"
          class="btn btn-primary btn-sm gap-1"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add All Pending to Library")}
        </button>
      </div>

      <%= cond do %>
        <% @items != [] -> %>
          <div
            id="import-list-items"
            class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3 sm:overflow-y-auto sm:max-h-[50vh]"
          >
            <.item_tile
              :for={item <- Index.group_items_by_status(@items)}
              item={item}
              media_type={@selected_list.media_type}
            />
          </div>
        <% @items_filter == "to_add" and @total_count > 0 -> %>
          <div id="import-list-items-all-owned" class="alert alert-success">
            <.icon name="hero-check-circle" class="w-5 h-5" />
            <span>{gettext("Everything on this list is already in your library.")}</span>
          </div>
        <% true -> %>
          <div id="import-list-items-empty" class="alert">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span>
              <%= if @items_filter != "all" do %>
                {gettext("No items found. Try a different filter or Sync the list to fetch items.")}
              <% else %>
                {gettext("No items found. Sync the list to fetch items.")}
              <% end %>
            </span>
          </div>
      <% end %>

      <:actions>
        <button type="button" phx-click="close_import_list_items_modal" class="btn btn-ghost">
          {gettext("Close")}
        </button>
        <button
          type="button"
          phx-click="sync_import_list"
          phx-value-id={@selected_list.id}
          class="btn btn-primary"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Sync Now")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :item, :any, required: true
  attr :media_type, :string, required: true

  defp item_tile(assigns) do
    assigns = assign(assigns, :status, Index.display_status(assigns.item))

    ~H"""
    <div id={"import-list-item-#{@item.id}"} class="bg-base-200 rounded-box overflow-hidden">
      <div class="relative">
        <%= if @item.poster_path do %>
          <img
            src={ImageUrl.poster_url(@item.poster_path, "w185")}
            alt={@item.title}
            class="w-full aspect-[2/3] object-cover"
            loading="lazy"
          />
        <% else %>
          <div class="w-full aspect-[2/3] bg-base-300 flex items-center justify-center">
            <.icon name={Index.media_type_icon(@media_type)} class="w-12 h-12 text-base-content/30" />
          </div>
        <% end %>
        <div class="absolute top-1 right-1">
          <span
            class={["badge badge-sm tooltip tooltip-left", Index.status_badge_class(@status)]}
            data-tip={Index.status_explanation(@status)}
          >
            {Index.status_label(@status)}
          </span>
        </div>
      </div>
      <div class="p-2">
        <h4 class="font-medium text-xs line-clamp-2" title={@item.title}>{@item.title}</h4>
        <p class="text-xs text-base-content/60">{@item.year || gettext("Unknown year")}</p>
        <p
          :if={@status == "failed" and @item.skip_reason}
          class="text-xs text-error truncate"
          title={@item.skip_reason}
        >
          {@item.skip_reason}
        </p>
        <div class="flex gap-1 mt-1">
          <button
            :if={@status == "pending"}
            phx-click="add_item_to_library"
            phx-value-id={@item.id}
            class="btn btn-primary btn-xs flex-1 gap-1"
          >
            <.icon name="hero-plus" class="w-3 h-3" /> {pgettext("add to library", "Add")}
          </button>
          <button
            :if={@status == "failed"}
            phx-click="reset_item"
            phx-value-id={@item.id}
            class="btn btn-ghost btn-xs flex-1"
          >
            {gettext("Reset")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
