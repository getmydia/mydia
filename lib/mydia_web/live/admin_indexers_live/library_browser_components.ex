defmodule MydiaWeb.AdminIndexersLive.LibraryBrowserComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminIndexersLive.Components

  @doc """
  Renders the indexer library modal for browsing and enabling indexer definitions.
  """
  attr :definitions, :list, required: true
  attr :available_languages, :list, required: true
  attr :filter_type, :string, required: true
  attr :filter_language, :string, required: true
  attr :filter_enabled, :string, required: true
  attr :search_query, :string, required: true
  attr :syncing, :boolean, required: true
  attr :configuring_definition, :any, required: true
  attr :config_form, :any, required: true

  def indexer_library_modal(assigns) do
    ~H"""
    <.admin_modal
      id="indexer-library-modal"
      icon="hero-book-open"
      title="Indexer Library"
      subtitle="Browse and enable indexers from the definition library"
      on_close="close_indexer_library"
      size={:lg}
    >
      <%!-- Experimental Warning --%>
      <div class="alert alert-warning mb-4">
        <.icon name="hero-beaker" class="w-5 h-5" />
        <span class="text-sm">
          <span class="font-medium">Experimental:</span>
          Only a limited number of indexers have been tested. Prowlarr and Jackett integrations are stable and recommended.
        </span>
      </div>
      <%!-- Filters and Search --%>
      <div class="bg-base-200 rounded-box p-3 mb-4">
        <div class="flex flex-wrap gap-4 items-end">
          <%!-- Search --%>
          <div class="form-control flex-1 min-w-48">
            <label class="label py-1">
              <span class="label-text text-xs">Search</span>
            </label>
            <form id="indexer-library-search-form" phx-change="search_library_indexers">
              <input
                type="text"
                name="search[query]"
                value={@search_query}
                placeholder="Search by name or description..."
                class="input input-bordered input-sm w-full"
              />
            </form>
          </div>
          <%!-- Filter Dropdowns --%>
          <.form
            for={%{}}
            id="indexer-library-filter-form"
            phx-change="filter_library_indexers"
            class="contents"
          >
            <%!-- Type Filter --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Type</span>
              </label>
              <select class="select select-bordered select-sm" name="type">
                <option value="all" selected={@filter_type == "all"}>All Types</option>
                <option value="public" selected={@filter_type == "public"}>Public</option>
                <option value="private" selected={@filter_type == "private"}>Private</option>
                <option value="semi-private" selected={@filter_type == "semi-private"}>
                  Semi-Private
                </option>
              </select>
            </div>
            <%!-- Language Filter --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Language</span>
              </label>
              <select class="select select-bordered select-sm" name="language">
                <option value="all" selected={@filter_language == "all"}>All Languages</option>
                <%= for language <- @available_languages do %>
                  <option value={language} selected={@filter_language == language}>
                    {language}
                  </option>
                <% end %>
              </select>
            </div>
            <%!-- Status Filter --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Status</span>
              </label>
              <select class="select select-bordered select-sm" name="enabled">
                <option value="all" selected={@filter_enabled == "all"}>All Status</option>
                <option value="enabled" selected={@filter_enabled == "enabled"}>Enabled</option>
                <option value="disabled" selected={@filter_enabled == "disabled"}>
                  Disabled
                </option>
              </select>
            </div>
          </.form>
          <%!-- Sync Button --%>
          <div class="form-control">
            <button
              id="sync-library-definitions"
              class={["btn btn-primary btn-sm", @syncing && "btn-disabled"]}
              phx-click="sync_library_definitions"
              disabled={@syncing}
            >
              <%= if @syncing do %>
                <span class="loading loading-spinner loading-xs"></span> Syncing...
              <% else %>
                <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync Library
              <% end %>
            </button>
          </div>
        </div>
      </div>
      <%!-- Indexer List --%>
      <div class="overflow-y-auto max-h-[50vh]">
        <.admin_list id="library-definitions" items={@definitions}>
          <:row :let={definition}>
            <.definition_row definition={definition} />
          </:row>
          <:empty>
            <%= if @search_query != "" or @filter_type != "all" or @filter_language != "all" or @filter_enabled != "all" do %>
              No indexers match your filters. Try adjusting your search criteria.
            <% else %>
              No indexer definitions available. Click "Sync Library" to fetch indexers from the repository.
            <% end %>
          </:empty>
        </.admin_list>
      </div>
      <.admin_modal_actions>
        <button class="btn btn-ghost" phx-click="close_indexer_library">Close</button>
      </.admin_modal_actions>
    </.admin_modal>
    <%!-- Credentials dialog, stacked above the library modal --%>
    <.admin_modal
      :if={@configuring_definition}
      id="library-definition-config-modal"
      icon="hero-cog-6-tooth"
      title={"Configure #{@configuring_definition.name}"}
      on_close="close_library_definition_config_modal"
    >
      <.form
        for={@config_form}
        id="indexer-config-form"
        phx-submit="library_save_config"
        class="space-y-4"
      >
        <input type="hidden" name="definition_id" value={@configuring_definition.id} />
        <div class="form-control">
          <label class="label">
            <span class="label-text">Username</span>
          </label>
          <input
            type="text"
            name="config[username]"
            value={@config_form[:username].value}
            class="input input-bordered w-full"
            placeholder="Enter username"
          />
        </div>
        <div class="form-control">
          <label class="label">
            <span class="label-text">Password</span>
          </label>
          <input
            type="password"
            name="config[password]"
            value={@config_form[:password].value}
            class="input input-bordered w-full"
            placeholder="Enter password"
          />
        </div>
        <.admin_modal_actions>
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="close_library_definition_config_modal"
          >
            Cancel
          </button>
          <button type="submit" class="btn btn-primary">Save</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :definition, :any, required: true

  defp definition_row(assigns) do
    ~H"""
    <.admin_row id={"library-definition-#{@definition.id}"}>
      <:title>
        {@definition.name}
        <span class={"badge badge-sm badge-outline #{Components.library_indexer_type_badge_class(@definition.type)}"}>
          {@definition.type}
        </span>
        <span :if={@definition.language} class="badge badge-sm badge-ghost">
          {@definition.language}
        </span>
      </:title>
      <:descriptor :if={@definition.description}>{@definition.description}</:descriptor>
      <:badges>
        <%= if Components.needs_library_config?(@definition) and @definition.enabled do %>
          <div class="tooltip" data-tip="This indexer requires configuration">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
          </div>
        <% end %>
        <%= if @definition.enabled and @definition.health_status not in [nil, "unknown"] do %>
          <span class={"badge badge-sm badge-outline #{Components.library_health_status_badge_class(@definition.health_status)}"}>
            {Components.library_health_status_label(@definition.health_status)}
          </span>
        <% end %>
        <%!-- Enable/Disable toggle with status label --%>
        <label class="flex items-center gap-2 cursor-pointer">
          <span class={[
            "text-xs font-medium min-w-14 text-right",
            if(@definition.enabled, do: "text-success", else: "text-base-content/50")
          ]}>
            {if @definition.enabled, do: "Enabled", else: "Disabled"}
          </span>
          <input
            type="checkbox"
            class="toggle toggle-success toggle-sm"
            checked={@definition.enabled}
            phx-click="toggle_library_definition"
            phx-value-id={@definition.id}
            aria-label={
              if @definition.enabled,
                do: "Disable #{@definition.name}",
                else: "Enable #{@definition.name}"
            }
          />
        </label>
      </:badges>
      <:actions :if={@definition.type in ["private", "semi-private"]}>
        <.row_actions>
          <.row_action
            id={"configure-library-definition-#{@definition.id}"}
            icon="hero-cog-6-tooth"
            title="Configure"
            phx-click="configure_library_definition"
            phx-value-id={@definition.id}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end
end
