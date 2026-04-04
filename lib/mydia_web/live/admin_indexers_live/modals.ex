defmodule MydiaWeb.AdminIndexersLive.Modals do
  @moduledoc """
  Modal components for the Indexers admin page.

  Extracted from Components to keep file sizes manageable.
  """
  use MydiaWeb, :html

  @doc """
  Renders the Indexer modal.
  """
  attr :indexer_form, :any, required: true
  attr :indexer_mode, :atom, required: true
  attr :testing_indexer_connection, :boolean, default: false
  attr :available_env_indexers, :list, default: []
  attr :prowlarr_indexers, :list, default: nil
  attr :fetching_prowlarr_indexers, :boolean, default: false
  attr :prowlarr_indexers_error, :string, default: nil
  attr :selected_prowlarr_indexer_ids, :any, default: nil

  def indexer_modal(assigns) do
    # Check if an env_name is currently set
    env_name = Phoenix.HTML.Form.input_value(assigns.indexer_form, :env_name)
    assigns = assign(assigns, :using_env_source, env_name != nil and env_name != "")

    # Check if type is prowlarr (handle both atom and string)
    indexer_type = Phoenix.HTML.Form.input_value(assigns.indexer_form, :type)
    is_prowlarr = indexer_type == "prowlarr" or indexer_type == :prowlarr
    assigns = assign(assigns, :is_prowlarr, is_prowlarr)

    # Ensure selected_prowlarr_indexer_ids is a MapSet
    selected_ids = assigns.selected_prowlarr_indexer_ids || MapSet.new()
    assigns = assign(assigns, :selected_prowlarr_indexer_ids, selected_ids)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <.form
          for={@indexer_form}
          id="indexer-form"
          phx-change="validate_indexer"
          phx-submit="save_indexer"
        >
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-5">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                <.icon
                  name={if(@indexer_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
                  class="w-5 h-5 text-primary"
                />
              </div>
              <div>
                <h3 class="font-bold text-lg">
                  {if @indexer_mode == :new, do: "Add Indexer", else: "Edit Indexer"}
                </h3>
                <p class="text-sm text-base-content/60">
                  {if @indexer_mode == :new,
                    do: "Configure a new search indexer",
                    else: "Update indexer settings"}
                </p>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Enabled</span>
              <input
                type="checkbox"
                name={@indexer_form[:enabled].name}
                value="true"
                checked={Phoenix.HTML.Form.normalize_value("checkbox", @indexer_form[:enabled].value)}
                class="toggle toggle-success toggle-sm"
              />
            </label>
          </div>
          <div class="space-y-5">
            <%!-- Basic Settings - Compact Row --%>
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-3">
                <.input field={@indexer_form[:name]} type="text" label="Name" required />
              </div>
              <div class="col-span-3 md:col-span-2">
                <.input
                  field={@indexer_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"Prowlarr", "prowlarr"},
                    {"Jackett", "jackett"},
                    {"NZBHydra2", "nzbhydra2"},
                    {"Public", "public"}
                  ]}
                  required
                />
              </div>
              <div class="col-span-3 md:col-span-1">
                <.input field={@indexer_form[:priority]} type="number" label="Priority" />
              </div>
            </div>

            <div class="divider my-1"></div>

            <%!-- Connection Settings Section --%>
            <div class="space-y-3">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                  <.icon name="hero-server" class="w-4 h-4" />
                  <span>Connection</span>
                </div>
                <%= if @using_env_source do %>
                  <span class="badge badge-info badge-sm gap-1">
                    <.icon name="hero-shield-check" class="w-3 h-3" /> From environment
                  </span>
                <% end %>
              </div>

              <%!-- Connection Source Selection --%>
              <%= if @available_env_indexers != [] do %>
                <.input
                  field={@indexer_form[:env_name]}
                  type="select"
                  label="Source"
                  options={
                    [{"Manual Configuration", ""}] ++
                      Enum.map(@available_env_indexers, fn env ->
                        label =
                          if env.has_api_key,
                            do: "#{env.env_name} (#{env.base_url})",
                            else: "#{env.env_name} (#{env.base_url}) - No API Key"

                        {label, env.env_name}
                      end)
                  }
                />
              <% end %>

              <%!-- Show credential fields only when not using env source --%>
              <%= if !@using_env_source do %>
                <div class="grid grid-cols-3 gap-3">
                  <div class="col-span-3 md:col-span-2">
                    <.input
                      field={@indexer_form[:base_url]}
                      type="text"
                      label="Base URL"
                      placeholder="http://localhost:9696"
                    />
                  </div>
                  <div class="col-span-3 md:col-span-1">
                    <.input
                      field={@indexer_form[:api_key]}
                      type="password"
                      label="API Key"
                      placeholder="API key"
                    />
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Prowlarr Indexer Selection (only shown for Prowlarr type) --%>
            <%= if @is_prowlarr do %>
              <div class="divider my-2"></div>

              <div class="space-y-4">
                <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                  <.icon name="hero-queue-list" class="w-4 h-4" />
                  <span>Indexer Selection</span>
                </div>

                <p class="text-sm text-base-content/60">
                  Choose which Prowlarr indexers to search. Leave empty to search all enabled indexers.
                </p>

                <%!-- Loading State --%>
                <%= if @fetching_prowlarr_indexers do %>
                  <div class="flex items-center justify-center gap-3 py-8 bg-base-200 rounded-lg">
                    <span class="loading loading-spinner loading-md text-primary"></span>
                    <span class="text-sm text-base-content/70">
                      Loading indexers from Prowlarr...
                    </span>
                  </div>
                <% end %>

                <%!-- Error State --%>
                <%= if @prowlarr_indexers_error do %>
                  <div class="alert alert-error">
                    <.icon name="hero-exclamation-circle" class="w-5 h-5" />
                    <div>
                      <p class="font-medium">Failed to load indexers</p>
                      <p class="text-sm opacity-80">{@prowlarr_indexers_error}</p>
                    </div>
                  </div>
                <% end %>

                <%!-- Indexer List --%>
                <%= if @prowlarr_indexers do %>
                  <%= if @prowlarr_indexers == [] do %>
                    <div class="alert alert-warning">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                      <div>
                        <p class="font-medium">No indexers found</p>
                        <p class="text-sm opacity-80">
                          Add indexers in your Prowlarr instance first
                        </p>
                      </div>
                    </div>
                  <% else %>
                    <%!-- Quick Selection Header --%>
                    <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-2">
                      <div class="flex items-center gap-2">
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost gap-1"
                          phx-click="select_all_prowlarr_indexers"
                        >
                          <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> All
                        </button>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost gap-1"
                          phx-click="deselect_all_prowlarr_indexers"
                        >
                          <.icon name="hero-x-circle" class="w-3.5 h-3.5" /> None
                        </button>
                      </div>
                      <span class="badge badge-primary badge-sm">
                        {MapSet.size(@selected_prowlarr_indexer_ids)}/{length(@prowlarr_indexers)} selected
                      </span>
                    </div>

                    <%!-- Indexer Checkboxes --%>
                    <div class="max-h-64 overflow-y-auto border border-base-300 rounded-lg divide-y divide-base-200">
                      <%= for indexer <- @prowlarr_indexers do %>
                        <label class={[
                          "flex items-center gap-3 px-4 py-3 hover:bg-base-200/50 cursor-pointer transition-colors",
                          !indexer.enabled && "opacity-50"
                        ]}>
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm checkbox-primary"
                            checked={MapSet.member?(@selected_prowlarr_indexer_ids, indexer.id)}
                            phx-click="toggle_prowlarr_indexer"
                            phx-value-id={indexer.id}
                          />
                          <span class="flex-1 text-sm font-medium">{indexer.name}</span>
                          <div class="flex items-center gap-2">
                            <span class={[
                              "badge badge-sm",
                              indexer.protocol == "torrent" && "badge-primary",
                              indexer.protocol == "usenet" && "badge-secondary"
                            ]}>
                              {indexer.protocol}
                            </span>
                            <%= if !indexer.enabled do %>
                              <span class="badge badge-sm badge-warning gap-1">
                                <.icon name="hero-pause" class="w-3 h-3" /> disabled
                              </span>
                            <% end %>
                          </div>
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_indexer_modal">
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-outline btn-secondary gap-2"
              phx-click="test_indexer_connection"
              disabled={@testing_indexer_connection}
            >
              <%= if @testing_indexer_connection do %>
                <span class="loading loading-spinner loading-sm"></span> Testing...
              <% else %>
                <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
              <% end %>
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" /> Save Indexer
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_indexer_modal"></div>
    </div>
    """
  end

  @doc """
  Renders the Library Indexer Config modal.

  Dynamically renders form fields based on the indexer's settings definition.
  """
  attr :configuring_library_indexer, :any, required: true
  attr :settings, :list, default: []
  attr :testing, :boolean, default: false
  attr :test_result, :map, default: nil

  def library_config_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <%!-- Header with close button --%>
        <div class="flex items-start justify-between mb-4">
          <div>
            <h3 class="font-bold text-lg flex items-center gap-2">
              <.icon name="hero-cog-6-tooth" class="w-5 h-5 opacity-60" />
              Configure {@configuring_library_indexer.name}
            </h3>
            <div class="flex items-center gap-2 mt-1">
              <span class={"badge badge-sm #{library_indexer_type_badge(@configuring_library_indexer.type)}"}>
                {@configuring_library_indexer.type}
              </span>
              <%= if @configuring_library_indexer.language do %>
                <span class="badge badge-sm badge-ghost">
                  {@configuring_library_indexer.language}
                </span>
              <% end %>
            </div>
          </div>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_library_config_modal"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Info banner --%>
        <div class="alert mb-4">
          <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
          <span class="text-sm">
            <%= if @configuring_library_indexer.type == "private" do %>
              This indexer requires authentication to search and download torrents.
            <% else %>
              Configure optional settings for this indexer.
            <% end %>
          </span>
        </div>

        <form id="library-indexer-config-form" phx-submit="save_library_indexer_config">
          <%!-- Settings Card --%>
          <div class="card bg-base-200">
            <div class="card-body p-4">
              <div class="space-y-4">
                <%= if @settings == [] do %>
                  <%!-- Fallback: Generic username/password form --%>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text font-medium">Username</span>
                    </label>
                    <input
                      type="text"
                      name="config[username]"
                      value={get_in(@configuring_library_indexer.config || %{}, ["username"])}
                      class="input input-bordered w-full"
                      placeholder="Enter your username"
                    />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text font-medium">Password</span>
                    </label>
                    <input
                      type="password"
                      name="config[password]"
                      value={get_in(@configuring_library_indexer.config || %{}, ["password"])}
                      class="input input-bordered w-full"
                      placeholder="Enter your password"
                    />
                  </div>
                <% else %>
                  <%!-- Dynamic fields from indexer definition --%>
                  <%= for setting <- @settings do %>
                    <.library_config_field
                      setting={setting}
                      config={@configuring_library_indexer.config || %{}}
                    />
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Test Result --%>
          <%= if @test_result do %>
            <div class={[
              "alert mt-4",
              if(@test_result.success, do: "alert-success", else: "alert-error")
            ]}>
              <.icon
                name={if @test_result.success, do: "hero-check-circle", else: "hero-x-circle"}
                class="w-5 h-5 shrink-0"
              />
              <div>
                <div class="font-medium">{@test_result.message}</div>
                <%= if @test_result.response_time_ms do %>
                  <div class="text-sm opacity-80">
                    Response time: {@test_result.response_time_ms}ms
                  </div>
                <% end %>
                <%= if @test_result.error do %>
                  <div class="text-sm opacity-80">{@test_result.error}</div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Actions --%>
          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_library_config_modal">
              Cancel
            </button>
            <button
              type="submit"
              name="action"
              value="test"
              class="btn btn-secondary"
              disabled={@testing}
            >
              <%= if @testing do %>
                <span class="loading loading-spinner loading-sm"></span> Testing...
              <% else %>
                <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
              <% end %>
            </button>
            <button type="submit" name="action" value="save" class="btn btn-primary">Save</button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_library_config_modal"></div>
    </div>
    """
  end

  # ============================================================================
  # Indexer Library Modal
  # ============================================================================

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
    <div class="modal modal-open">
      <div class="modal-box max-w-5xl max-h-[90vh]">
        <%!-- Header with Close Button --%>
        <div class="flex items-center justify-between mb-4">
          <div>
            <h3 class="font-bold text-lg flex items-center gap-2">
              <.icon name="hero-book-open" class="w-5 h-5 opacity-60" /> Indexer Library
            </h3>
            <p class="text-base-content/70 text-sm mt-1">
              Browse and enable indexers from the definition library
            </p>
          </div>
          <button
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_indexer_library"
            title="Close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <%!-- Experimental Warning --%>
        <div class="alert alert-warning mb-4">
          <.icon name="hero-beaker" class="w-5 h-5" />
          <span class="text-sm">
            <span class="font-medium">Experimental:</span>
            Only a limited number of indexers have been tested. Prowlarr and Jackett integrations are stable and recommended.
          </span>
        </div>
        <%!-- Filters and Search --%>
        <div class="card bg-base-200 shadow-sm mb-4">
          <div class="card-body p-4">
            <div class="flex flex-wrap gap-4 items-end">
              <%!-- Search --%>
              <div class="form-control flex-1 min-w-48">
                <label class="label py-1">
                  <span class="label-text text-xs">Search</span>
                </label>
                <form id="indexer-library-search-form" phx-change="library_search">
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
                phx-change="library_filter"
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
                  class={["btn btn-primary btn-sm", @syncing && "btn-disabled"]}
                  phx-click="library_sync_definitions"
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
        </div>
        <%!-- Indexer List --%>
        <div class="overflow-y-auto max-h-[50vh]">
          <%= if @definitions == [] do %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>
                <%= if @search_query != "" or @filter_type != "all" or @filter_language != "all" or @filter_enabled != "all" do %>
                  No indexers match your filters. Try adjusting your search criteria.
                <% else %>
                  No indexer definitions available. Click "Sync Library" to fetch indexers from the repository.
                <% end %>
              </span>
            </div>
          <% else %>
            <div class="bg-base-200 rounded-box divide-y divide-base-300">
              <%= for definition <- @definitions do %>
                <div class="p-3 sm:p-4">
                  <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                    <%!-- Indexer Info --%>
                    <div class="flex-1 min-w-0">
                      <div class="font-semibold flex items-center gap-2 flex-wrap">
                        {definition.name}
                        <span class={"badge badge-sm #{indexer_type_badge_class(definition.type)}"}>
                          {definition.type}
                        </span>
                        <%= if definition.language do %>
                          <span class="badge badge-sm badge-ghost">{definition.language}</span>
                        <% end %>
                      </div>
                      <%= if definition.description do %>
                        <div class="text-sm text-base-content/70 mt-1 line-clamp-1">
                          {definition.description}
                        </div>
                      <% end %>
                    </div>
                    <%!-- Actions --%>
                    <div class="flex items-center gap-3">
                      <%!-- Configure button for private indexers --%>
                      <%= if definition.type in ["private", "semi-private"] do %>
                        <button
                          class="btn btn-ghost btn-xs"
                          phx-click="library_configure_indexer"
                          phx-value-id={definition.id}
                          title="Configure"
                        >
                          <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                        </button>
                      <% end %>
                      <%!-- Needs config warning --%>
                      <%= if needs_library_definition_config?(definition) and definition.enabled do %>
                        <div class="tooltip" data-tip="This indexer requires configuration">
                          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
                        </div>
                      <% end %>
                      <%!-- Health status --%>
                      <%= if definition.enabled and definition.health_status not in [nil, "unknown"] do %>
                        <span class={"badge badge-sm #{library_health_status_badge_class(definition.health_status)}"}>
                          {library_health_status_label(definition.health_status)}
                        </span>
                      <% end %>
                      <%!-- Enable/Disable toggle with status label --%>
                      <label class="flex items-center gap-2 cursor-pointer">
                        <span class={[
                          "text-xs font-medium min-w-14 text-right",
                          if(definition.enabled, do: "text-success", else: "text-base-content/50")
                        ]}>
                          {if definition.enabled, do: "Enabled", else: "Disabled"}
                        </span>
                        <input
                          type="checkbox"
                          class="toggle toggle-success toggle-sm"
                          checked={definition.enabled}
                          phx-click="library_toggle_indexer"
                          phx-value-id={definition.id}
                        />
                      </label>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        <%!-- Modal Footer --%>
        <div class="modal-action">
          <button class="btn" phx-click="close_indexer_library">Close</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_indexer_library"></div>
    </div>
    <%!-- Configuration Modal --%>
    <%= if @configuring_definition do %>
      <div class="modal modal-open" style="z-index: 60;">
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-4">Configure {@configuring_definition.name}</h3>
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
            <div class="modal-action">
              <button
                type="button"
                class="btn"
                phx-click="library_close_config"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">Save</button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="library_close_config"></div>
      </div>
    <% end %>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp library_indexer_type_badge("public"), do: "badge-success"
  defp library_indexer_type_badge("private"), do: "badge-error"
  defp library_indexer_type_badge("semi-private"), do: "badge-warning"
  defp library_indexer_type_badge(_), do: "badge-ghost"

  defp library_health_status_badge_class("healthy"), do: "badge-success"
  defp library_health_status_badge_class("degraded"), do: "badge-warning"
  defp library_health_status_badge_class("unhealthy"), do: "badge-error"
  defp library_health_status_badge_class(_), do: "badge-ghost"

  defp library_health_status_label("healthy"), do: "Healthy"
  defp library_health_status_label("degraded"), do: "Degraded"
  defp library_health_status_label("unhealthy"), do: "Unhealthy"
  defp library_health_status_label(_), do: "Unknown"

  defp indexer_type_badge_class("public"), do: "badge-success"
  defp indexer_type_badge_class("private"), do: "badge-error"
  defp indexer_type_badge_class("semi-private"), do: "badge-warning"
  defp indexer_type_badge_class(_), do: "badge-ghost"

  defp needs_library_definition_config?(%{type: "public"}), do: false

  defp needs_library_definition_config?(%{type: type, config: nil})
       when type in ["private", "semi-private"],
       do: true

  defp needs_library_definition_config?(%{type: type, config: config})
       when type in ["private", "semi-private"] and config == %{},
       do: true

  defp needs_library_definition_config?(_), do: false

  # Renders a single config field based on its type
  attr :setting, :map, required: true
  attr :config, :map, required: true

  defp library_config_field(assigns) do
    assigns =
      assigns
      |> assign(:field_name, assigns.setting.name)
      |> assign(
        :field_label,
        assigns.setting[:label] || humanize_field_name(assigns.setting.name)
      )
      |> assign(:field_type, assigns.setting.type)
      |> assign(:field_default, assigns.setting[:default])
      |> assign(:field_options, assigns.setting[:options])
      |> assign(
        :current_value,
        get_in(assigns.config, [assigns.setting.name]) || assigns.setting[:default]
      )

    ~H"""
    <div class="form-control">
      <%= case @field_type do %>
        <% "text" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="text"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
        <% "password" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="password"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
        <% "checkbox" -> %>
          <label class="label cursor-pointer justify-start gap-3">
            <input
              type="hidden"
              name={"config[#{@field_name}]"}
              value="false"
            />
            <input
              type="checkbox"
              name={"config[#{@field_name}]"}
              value="true"
              checked={@current_value == true or @current_value == "true"}
              class="checkbox checkbox-primary"
            />
            <span class="label-text font-medium">{@field_label}</span>
          </label>
        <% "select" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <select name={"config[#{@field_name}]"} class="select select-bordered w-full">
            <%= if @field_options do %>
              <%= for {label, value} <- normalize_select_options(@field_options) do %>
                <option value={value} selected={to_string(@current_value) == to_string(value)}>
                  {label}
                </option>
              <% end %>
            <% end %>
          </select>
        <% "info" -> %>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <div class="text-sm text-base-content/70 bg-base-300 p-3 rounded-lg">
            {@field_default || "No additional information"}
          </div>
        <% _ -> %>
          <%!-- Default to text input for unknown types --%>
          <label class="label">
            <span class="label-text font-medium">{@field_label}</span>
          </label>
          <input
            type="text"
            name={"config[#{@field_name}]"}
            value={@current_value}
            class="input input-bordered w-full"
          />
      <% end %>
    </div>
    """
  end

  defp humanize_field_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_field_name(name) when is_atom(name), do: humanize_field_name(Atom.to_string(name))

  defp normalize_select_options(options) when is_map(options) do
    Enum.map(options, fn {k, v} -> {v, k} end)
  end

  defp normalize_select_options(options) when is_list(options) do
    Enum.map(options, fn
      %{"name" => name, "value" => value} -> {name, value}
      %{name: name, value: value} -> {name, value}
      value when is_binary(value) -> {value, value}
      value -> {to_string(value), value}
    end)
  end

  defp normalize_select_options(_), do: []
end
