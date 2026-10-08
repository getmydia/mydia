defmodule MydiaWeb.AdminIndexersLive.ModalComponents do
  @moduledoc false
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

    # Newznab indexers address a configurable API path; the form exposes it so
    # operators can point Mydia at a deployment prefix or a non-standard endpoint.
    is_newznab = indexer_type == "newznab" or indexer_type == :newznab
    assigns = assign(assigns, :is_newznab, is_newznab)

    # An unusable API path is recorded on :connection_settings by
    # IndexerConfig.normalize_and_validate_newznab_api_path/1, and the API Path
    # input is the only render site for that field, so hand its errors to the
    # input explicitly (it renders by name, not by field).
    api_path_errors =
      assigns.indexer_form.source
      |> Map.get(:errors, [])
      |> translate_errors(:connection_settings)

    assigns = assign(assigns, :api_path_errors, api_path_errors)

    # NZB-capable indexer types support a minimum post-age filter.
    # Prowlarr aggregates both protocols, Newznab is NZB-only, Jackett
    # historically passes Newznab attrs through for NZB definitions.
    is_nzb_capable =
      indexer_type in ["prowlarr", :prowlarr, "newznab", :newznab, "jackett", :jackett]

    assigns = assign(assigns, :is_nzb_capable, is_nzb_capable)

    # Ensure selected_prowlarr_indexer_ids is a MapSet
    selected_ids = assigns.selected_prowlarr_indexer_ids || MapSet.new()
    assigns = assign(assigns, :selected_prowlarr_indexer_ids, selected_ids)

    ~H"""
    <.admin_modal
      id="indexer-modal"
      icon={if(@indexer_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
      title={if @indexer_mode == :new, do: "Add Indexer", else: "Edit Indexer"}
      subtitle={
        if @indexer_mode == :new,
          do: "Configure a new search indexer",
          else: "Update indexer settings"
      }
      on_close="close_indexer_modal"
    >
      <.form
        for={@indexer_form}
        id="indexer-form"
        phx-change="validate_indexer"
        phx-submit="save_indexer"
      >
        <label class="label cursor-pointer justify-end gap-2 mb-2">
          <span class="label-text text-sm">Enabled</span>
          <input type="hidden" name={@indexer_form[:enabled].name} value="false" />
          <input
            type="checkbox"
            name={@indexer_form[:enabled].name}
            value="true"
            checked={Phoenix.HTML.Form.normalize_value("checkbox", @indexer_form[:enabled].value)}
            class="toggle toggle-success toggle-sm"
          />
        </label>
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
                  {"Newznab", "newznab"},
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

          <%!-- NZB / Usenet Options (only shown for NZB-capable indexers) --%>
          <%= if @is_nzb_capable do %>
            <div class="divider my-2"></div>
            <div class="space-y-3">
              <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                <.icon name="hero-clock" class="w-4 h-4" />
                <span>Usenet Options</span>
              </div>
              <div class="grid grid-cols-3 gap-3">
                <div class="col-span-3 md:col-span-1">
                  <.input
                    field={@indexer_form[:min_post_age_minutes]}
                    type="number"
                    label="Min post age (minutes)"
                    placeholder="0"
                    min="0"
                  />
                </div>
                <div class="col-span-3 md:col-span-2 text-xs text-base-content/60 self-end pb-2">
                  Filters out NZB results posted within this many minutes. Useful for letting
                  indexers complete article propagation. Leave blank to disable.
                </div>
              </div>
              <div :if={@is_newznab} class="grid grid-cols-3 gap-3">
                <div class="col-span-3">
                  <.input
                    id="indexer-api-path"
                    name="indexer_config[connection_settings][api_path]"
                    type="text"
                    label="API Path"
                    value={
                      get_in(
                        Phoenix.HTML.Form.input_value(@indexer_form, :connection_settings) || %{},
                        ["api_path"]
                      ) || "/api"
                    }
                    placeholder="/api"
                    hint="Newznab endpoint path; usually remains /api."
                    errors={@api_path_errors}
                  />
                </div>
              </div>
            </div>
          <% end %>

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

        <.admin_modal_actions>
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
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end
end
