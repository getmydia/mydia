defmodule MydiaWeb.AdminMediaServersLive.MediaServerModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  import MydiaWeb.AdminMediaServersLive.Components,
    only: [media_server_type_icon: 1]

  @doc """
  Renders the Media Server modal.
  """
  attr :media_server_form, :any, required: true
  attr :media_server_mode, :atom, required: true
  attr :testing_media_server_connection, :boolean, default: false

  def media_server_modal(assigns) do
    # Get the current type from the form
    current_type =
      case Phoenix.HTML.Form.input_value(assigns.media_server_form, :type) do
        nil -> nil
        "" -> nil
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
      end

    assigns = assign(assigns, :current_type, current_type)

    ~H"""
    <.admin_modal
      id="media-server-modal"
      icon={if @current_type, do: media_server_type_icon(@current_type), else: "hero-server-stack"}
      title={if @media_server_mode == :new, do: "Add Media Server", else: "Edit Media Server"}
      subtitle={
        if @media_server_mode == :new,
          do: "Connect a Jellyfin server",
          else: "Update server configuration"
      }
      on_close="close_media_server_modal"
    >
      <:header_aside>
        <label class="label cursor-pointer gap-2">
          <span class="label-text text-sm">Enabled</span>
          <input
            type="hidden"
            name={@media_server_form[:enabled].name}
            value="false"
            form="media-server-form"
          />
          <input
            type="checkbox"
            name={@media_server_form[:enabled].name}
            value="true"
            checked={Phoenix.HTML.Form.input_value(@media_server_form, :enabled) in [true, "true"]}
            class="toggle toggle-success toggle-sm"
            form="media-server-form"
          />
        </label>
      </:header_aside>
      <.form
        for={@media_server_form}
        id="media-server-form"
        phx-change="validate_media_server"
        phx-submit="save_media_server"
      >
        <div class="space-y-5">
          <%!-- Basic Info Section --%>
          <div class="grid grid-cols-6 gap-3">
            <div class="col-span-6">
              <.input field={@media_server_form[:name]} type="text" label="Name" required />
              <input type="hidden" name={@media_server_form[:type].name} value="jellyfin" />
            </div>
          </div>

          <div class="divider my-1"></div>

          <div class="card bg-base-200/50 border border-base-300">
            <div class="card-body p-4 gap-4">
              <div class="flex items-center gap-2 text-sm font-medium text-base-content/70">
                <.icon name="hero-link" class="w-4 h-4" /> Connection Details
              </div>

              <div class="space-y-4">
                <div>
                  <.input
                    field={@media_server_form[:url]}
                    type="text"
                    label="Server URL"
                    placeholder="http://192.168.1.100:8096"
                    required
                  />
                  <p class="text-xs text-base-content/50 mt-1 ml-1">
                    Full URL including port (default: 8096)
                  </p>
                </div>

                <div>
                  <.input
                    field={@media_server_form[:token]}
                    type="password"
                    label="API Token"
                    required
                  />
                  <p class="text-xs text-base-content/50 mt-1 ml-1">
                    API Key from Dashboard → Advanced → API Keys
                  </p>
                </div>
              </div>
            </div>
          </div>

          <%!-- Watched Sync Section --%>
          <%= if @current_type == :jellyfin do %>
            <div class="card bg-base-200/50 border border-base-300">
              <div class="card-body p-4 gap-4">
                <div class="flex items-center gap-2 text-sm font-medium text-base-content/70">
                  <.icon name="hero-arrow-path" class="w-4 h-4" /> Watched Status Sync
                </div>

                <div class="space-y-3">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="hidden"
                      name="media_server_config[connection_settings][sync_watched]"
                      value="false"
                    />
                    <input
                      type="checkbox"
                      name="media_server_config[connection_settings][sync_watched]"
                      value="true"
                      checked={
                        get_in(
                          Phoenix.HTML.Form.input_value(
                            @media_server_form,
                            :connection_settings
                          ) || %{},
                          ["sync_watched"]
                        ) in [true, "true"]
                      }
                      class="toggle toggle-primary toggle-sm"
                    />
                    <div>
                      <span class="label-text">Enable watched sync</span>
                      <p class="text-xs text-base-content/50">
                        Sync watched status between Mydia and this server every 30 minutes
                      </p>
                    </div>
                  </label>

                  <div>
                    <label class="label">
                      <span class="label-text text-sm">Sync Direction</span>
                    </label>
                    <% direction =
                      get_in(
                        Phoenix.HTML.Form.input_value(@media_server_form, :connection_settings) ||
                          %{},
                        ["sync_watched_direction"]
                      ) || "bidirectional" %>
                    <select
                      name="media_server_config[connection_settings][sync_watched_direction]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option value="bidirectional" selected={direction == "bidirectional"}>
                        Bidirectional
                      </option>
                      <option value="import" selected={direction == "import"}>
                        Import only (server → Mydia)
                      </option>
                      <option value="export" selected={direction == "export"}>
                        Export only (Mydia → server)
                      </option>
                    </select>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_media_server_modal">
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-outline btn-secondary gap-2"
            phx-click="test_media_server_connection"
            disabled={@testing_media_server_connection}
          >
            <%= if @testing_media_server_connection do %>
              <span class="loading loading-spinner loading-sm"></span> Testing...
            <% else %>
              <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
            <% end %>
          </button>
          <button type="submit" id="media-server-submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" />
            {if @media_server_mode == :new, do: "Add Server", else: "Save Changes"}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end
end
