defmodule MydiaWeb.AdminMediaServersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings

  @doc """
  Renders the Media Servers tab content.
  """
  attr :media_servers, :list, required: true
  attr :media_server_health, :map, required: true
  attr :last_runs, :map, default: %{}

  def media_servers_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-server-stack" class="w-5 h-5 opacity-60" /> Media Servers
          <span class="badge badge-ghost">{length(@media_servers)}</span>
        </h2>
        <button class="btn btn-sm btn-primary" phx-click="new_media_server">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

      <%= if @media_servers == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No media servers configured yet. Add Plex or Jellyfin to enable automatic library updates.
          </span>
        </div>
      <% else %>
        <%!-- Server Cards Grid --%>
        <div class="grid gap-4 md:grid-cols-2">
          <%= for server <- @media_servers do %>
            <% health = Map.get(@media_server_health, server.id, %{status: :unknown}) %>
            <% is_runtime = Settings.runtime_config?(server) %>
            <% last_run = Map.get(@last_runs, server.id) %>

            <div class={[
              "card bg-base-100 border transition-all duration-200 hover:shadow-lg",
              if(server.enabled,
                do: "border-base-300 hover:border-primary/30",
                else: "border-base-300/50 opacity-75"
              )
            ]}>
              <div class="card-body p-4 gap-4">
                <%!-- Top Row: Icon + Name + Status --%>
                <div class="flex items-start gap-3">
                  <%!-- Server Type Icon --%>
                  <div class={[
                    "p-3 rounded-xl shrink-0",
                    media_server_type_bg_class(server.type)
                  ]}>
                    <.icon
                      name={media_server_type_icon(server.type)}
                      class={"w-6 h-6 #{media_server_type_icon_class(server.type)}"}
                    />
                  </div>

                  <%!-- Server Info --%>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <h3 class="font-semibold text-base truncate">{server.name}</h3>
                      <%= if is_runtime do %>
                        <span
                          class="badge badge-primary badge-xs gap-1 tooltip cursor-help"
                          data-tip="Configured via environment variables (read-only)"
                        >
                          <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                        </span>
                      <% end %>
                    </div>
                    <div class="text-xs text-base-content/50 mt-0.5 font-mono truncate">
                      {server.url}
                    </div>
                  </div>

                  <%!-- Health Status Indicator --%>
                  <div
                    role="img"
                    aria-label={health_status_label(health.status)}
                    class={[
                      "w-3 h-3 rounded-full shrink-0 mt-1",
                      health_status_dot_class(health.status)
                    ]}
                  >
                  </div>
                </div>

                <%!-- Middle Row: Badges --%>
                <div class="flex flex-wrap items-center gap-2">
                  <span class={[
                    "badge badge-sm gap-1",
                    media_server_type_badge_class(server.type)
                  ]}>
                    {media_server_type_label(server.type)}
                  </span>
                  <span class={[
                    "badge badge-sm",
                    if(server.enabled, do: "badge-success badge-outline", else: "badge-ghost")
                  ]}>
                    {if server.enabled, do: "Active", else: "Inactive"}
                  </span>
                  <span class={[
                    "badge badge-sm gap-1",
                    health_status_badge_class(health.status)
                  ]}>
                    <.icon name={health_status_icon(health.status)} class="w-3 h-3" />
                    {health_status_label(health.status)}
                  </span>
                </div>

                <p
                  :if={health.status == :unhealthy and health[:error]}
                  data-test="health-error"
                  class="text-xs text-error/80 break-words"
                >
                  {health.error}
                </p>

                <%!-- Watched Sync Status --%>
                <% sync_enabled =
                  get_in(server.connection_settings || %{}, ["sync_watched"]) in [true, "true"] %>
                <% last_sync = get_in(server.connection_settings || %{}, ["last_watched_sync_at"]) %>
                <%= if sync_enabled do %>
                  <div
                    data-test="watched-sync-enabled"
                    class="flex items-center gap-2 text-xs text-base-content/60"
                  >
                    <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                    <span>
                      Watched sync enabled
                      <%= if last_sync do %>
                        &middot; Last synced {last_sync}
                      <% end %>
                    </span>
                  </div>
                <% end %>

                <div
                  :if={last_run}
                  data-test="last-sync-run"
                  class="flex items-center gap-2 text-xs"
                >
                  <span class={[
                    "badge badge-xs",
                    last_run.status == :ok && "badge-success",
                    last_run.status == :error && "badge-error",
                    last_run.status == :skipped && "badge-warning"
                  ]}>
                    {run_label(last_run)}
                  </span>
                  <span :if={last_run.error} class="text-error/80">{last_run.error}</span>
                </div>

                <%!-- Bottom Row: Actions --%>
                <div class="flex items-center justify-end gap-1 pt-2 border-t border-base-200">
                  <button
                    :if={server.last_auth_error_at}
                    data-test="reconnect-plex"
                    class="btn btn-sm btn-warning gap-1"
                    phx-click="reconnect_plex"
                    phx-value-id={server.id}
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect Plex
                  </button>
                  <%= if sync_enabled and server.type == :plex do %>
                    <button
                      class="btn btn-sm btn-ghost gap-1"
                      phx-click="sync_watched"
                      phx-value-id={server.id}
                    >
                      <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync Now
                    </button>
                  <% end %>
                  <button
                    class="btn btn-sm btn-ghost gap-1"
                    phx-click="test_media_server"
                    phx-value-id={server.id}
                  >
                    <.icon name="hero-signal" class="w-4 h-4" /> Test
                  </button>
                  <%= if is_runtime do %>
                    <div class="tooltip" data-tip="Cannot modify runtime-configured servers">
                      <button class="btn btn-sm btn-ghost" disabled>
                        <.icon name="hero-pencil" class="w-4 h-4 opacity-30" />
                      </button>
                    </div>
                  <% else %>
                    <button
                      class="btn btn-sm btn-ghost"
                      phx-click="edit_media_server"
                      phx-value-id={server.id}
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" />
                    </button>
                    <button
                      class="btn btn-sm btn-ghost text-error hover:bg-error/10"
                      phx-click="delete_media_server"
                      phx-value-id={server.id}
                      data-confirm="Are you sure you want to delete this media server?"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" />
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the Media Server modal.
  """
  attr :media_server_form, :any, required: true
  attr :media_server_mode, :atom, required: true
  attr :testing_media_server_connection, :boolean, default: false
  attr :plex_oauth_state, :atom, default: :idle
  attr :plex_oauth_servers, :list, default: []
  attr :plex_manual_entry, :boolean, default: false
  attr :plex_selected_server, :map, default: nil
  attr :plex_connection_statuses, :map, default: %{}

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
    <div class="modal modal-open" id="media-server-modal" phx-hook="PlexOAuth">
      <div class="modal-box max-w-xl">
        <%!-- Modal Header --%>
        <div class="flex items-center justify-between mb-5">
          <div class="flex items-center gap-3">
            <div class={[
              "w-10 h-10 rounded-xl flex items-center justify-center",
              if(@current_type, do: media_server_type_bg_class(@current_type), else: "bg-primary/20")
            ]}>
              <.icon
                name={
                  if @current_type,
                    do: media_server_type_icon(@current_type),
                    else: "hero-server-stack"
                }
                class={"w-5 h-5 #{if @current_type, do: media_server_type_icon_class(@current_type), else: "text-primary"}"}
              />
            </div>
            <div>
              <h3 class="font-bold text-lg">
                {if @media_server_mode == :new, do: "Add Media Server", else: "Edit Media Server"}
              </h3>
              <p class="text-sm text-base-content/60">
                {if @media_server_mode == :new,
                  do: "Connect to Plex or Jellyfin",
                  else: "Update server configuration"}
              </p>
            </div>
          </div>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-sm">Enabled</span>
            <input type="hidden" name={@media_server_form[:enabled].name} value="false" />
            <input
              type="checkbox"
              name={@media_server_form[:enabled].name}
              value="true"
              checked={Phoenix.HTML.Form.input_value(@media_server_form, :enabled) in [true, "true"]}
              class="toggle toggle-success toggle-sm"
            />
          </label>
        </div>

        <.form
          for={@media_server_form}
          id="media-server-form"
          phx-change="validate_media_server"
          phx-submit="save_media_server"
        >
          <div class="space-y-5">
            <%!-- Basic Info Section --%>
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-4">
                <.input field={@media_server_form[:name]} type="text" label="Name" required />
              </div>
              <div class="col-span-6 md:col-span-2">
                <.input
                  field={@media_server_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"Plex", "plex"},
                    {"Jellyfin", "jellyfin"}
                  ]}
                  required
                />
              </div>
            </div>

            <div class="divider my-1"></div>

            <%!-- Plex OAuth Section - only shown when Plex is selected and not in manual mode --%>
            <%= if @current_type == :plex and not @plex_manual_entry do %>
              <div class="card bg-gradient-to-br from-warning/5 to-warning/10 border border-warning/20">
                <div class="card-body p-4">
                  <%!-- OAuth Progress Steps --%>
                  <ul class="steps steps-horizontal w-full text-xs mb-4">
                    <li class={[
                      "step",
                      @plex_oauth_state in [
                        :idle,
                        :authorizing,
                        :selecting_server,
                        :selecting_connection,
                        :complete,
                        :error
                      ] && "step-warning"
                    ]}>
                      Sign In
                    </li>
                    <li class={[
                      "step",
                      @plex_oauth_state in [:selecting_server, :selecting_connection, :complete] &&
                        "step-warning"
                    ]}>
                      Server
                    </li>
                    <li class={[
                      "step",
                      @plex_oauth_state in [:selecting_connection, :complete] && "step-warning"
                    ]}>
                      Connection
                    </li>
                    <li class={["step", @plex_oauth_state == :complete && "step-warning"]}>Done</li>
                  </ul>

                  <%= case @plex_oauth_state do %>
                    <% :idle -> %>
                      <div class="text-center space-y-4 py-2">
                        <div class="bg-warning/10 inline-flex p-3 rounded-full">
                          <.icon name="hero-play-circle" class="w-8 h-8 text-warning" />
                        </div>
                        <div>
                          <p class="font-medium">Sign in with Plex</p>
                          <p class="text-sm text-base-content/60">
                            Automatically discover and configure your server
                          </p>
                        </div>
                        <button
                          type="button"
                          class="btn btn-warning gap-2"
                          phx-click="start_plex_oauth"
                        >
                          <.icon name="hero-arrow-right-end-on-rectangle" class="w-5 h-5" />
                          Connect Plex Account
                        </button>
                        <div class="divider text-xs text-base-content/40 my-2">or enter manually</div>
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm gap-1"
                          phx-click="toggle_plex_manual_entry"
                        >
                          <.icon name="hero-pencil-square" class="w-4 h-4" /> Enter token manually
                        </button>
                      </div>
                    <% :authorizing -> %>
                      <div class="text-center space-y-4 py-4">
                        <span class="loading loading-ring loading-lg text-warning"></span>
                        <div>
                          <p class="font-medium">Waiting for authorization...</p>
                          <p class="text-sm text-base-content/60">
                            Complete the sign-in in the popup window
                          </p>
                        </div>
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm"
                          phx-click="cancel_plex_oauth"
                        >
                          Cancel
                        </button>
                      </div>
                    <% :selecting_server -> %>
                      <div class="space-y-3">
                        <div class="flex items-center gap-2 text-success">
                          <.icon name="hero-check-circle" class="w-5 h-5" />
                          <span class="font-medium text-sm">Authenticated successfully</span>
                        </div>
                        <p class="text-sm text-base-content/70">Select your Plex server:</p>
                        <div class="space-y-2 max-h-48 overflow-y-auto">
                          <%= for server <- @plex_oauth_servers do %>
                            <button
                              type="button"
                              class="card card-compact bg-base-100 border border-base-300 hover:border-warning/50 hover:shadow-md transition-all w-full cursor-pointer"
                              phx-click="select_plex_server"
                              phx-value-server_id={server.client_identifier}
                            >
                              <div class="card-body flex-row items-center gap-3 p-3">
                                <div class={[
                                  "p-2 rounded-lg",
                                  if(server.presence, do: "bg-success/10", else: "bg-base-200")
                                ]}>
                                  <.icon
                                    name="hero-server"
                                    class={"w-5 h-5 #{if server.presence, do: "text-success", else: "text-base-content/40"}"}
                                  />
                                </div>
                                <div class="flex-1 text-left">
                                  <p class="font-medium">{server.name}</p>
                                  <div class="flex gap-1 mt-0.5">
                                    <%= if server.owned do %>
                                      <span class="badge badge-xs badge-primary">owner</span>
                                    <% end %>
                                    <%= unless server.presence do %>
                                      <span class="badge badge-xs badge-ghost">offline</span>
                                    <% end %>
                                  </div>
                                </div>
                                <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/40" />
                              </div>
                            </button>
                          <% end %>
                          <%= if @plex_oauth_servers == [] do %>
                            <div class="alert alert-warning">
                              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                              <span>No Plex servers found for this account.</span>
                            </div>
                          <% end %>
                        </div>
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm gap-1"
                          phx-click="cancel_plex_oauth"
                        >
                          <.icon name="hero-arrow-left" class="w-4 h-4" /> Start over
                        </button>
                      </div>
                    <% :selecting_connection -> %>
                      <div class="space-y-3">
                        <div class="flex items-center gap-2 bg-base-100 rounded-lg p-2">
                          <div class="bg-primary/10 p-2 rounded-lg">
                            <.icon name="hero-server" class="w-5 h-5 text-primary" />
                          </div>
                          <span class="font-medium">{@plex_selected_server.name}</span>
                        </div>
                        <p class="text-sm text-base-content/70">Choose a connection:</p>
                        <div class="space-y-2 max-h-48 overflow-y-auto">
                          <% sorted_connections =
                            Enum.sort_by(@plex_selected_server.connections, fn conn ->
                              case Map.get(@plex_connection_statuses, conn.uri, :testing) do
                                :ok -> 0
                                :testing -> 1
                                _ -> 2
                              end
                            end) %>
                          <%= for conn <- sorted_connections do %>
                            <% status = Map.get(@plex_connection_statuses, conn.uri, :testing) %>
                            <button
                              type="button"
                              class={[
                                "card card-compact bg-base-100 border w-full cursor-pointer transition-all",
                                cond do
                                  status == :ok ->
                                    "border-success/50 hover:border-success hover:shadow-md"

                                  status == :error ->
                                    "border-error/30 opacity-50 cursor-not-allowed"

                                  true ->
                                    "border-base-300 hover:border-warning/50"
                                end
                              ]}
                              phx-click="select_plex_connection"
                              phx-value-url={conn.uri}
                              disabled={status == :error}
                            >
                              <div class="card-body flex-row items-center gap-3 p-3">
                                <%= case status do %>
                                  <% :testing -> %>
                                    <span class="loading loading-spinner loading-sm text-warning"></span>
                                  <% :ok -> %>
                                    <div class="bg-success/10 p-1.5 rounded-lg">
                                      <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                                    </div>
                                  <% _ -> %>
                                    <div class="bg-error/10 p-1.5 rounded-lg">
                                      <.icon name="hero-x-circle" class="w-4 h-4 text-error" />
                                    </div>
                                <% end %>
                                <div class="flex-1 text-left min-w-0">
                                  <p class="font-mono text-xs truncate">
                                    {simplify_plex_url(conn.uri)}
                                  </p>
                                  <div class="flex gap-1 mt-1">
                                    <%= if conn.local do %>
                                      <span class="badge badge-xs badge-info gap-1">
                                        <.icon name="hero-home" class="w-3 h-3" /> local
                                      </span>
                                    <% end %>
                                    <%= if conn.relay do %>
                                      <span class="badge badge-xs badge-warning gap-1">
                                        <.icon name="hero-cloud" class="w-3 h-3" /> relay
                                      </span>
                                    <% end %>
                                  </div>
                                </div>
                              </div>
                            </button>
                          <% end %>
                        </div>
                        <p class="text-xs text-base-content/50">
                          <.icon name="hero-check-circle" class="w-3 h-3 inline text-success" />
                          connections are reachable. Choose "local" if on same network.
                        </p>
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm gap-1"
                          phx-click="cancel_plex_oauth"
                        >
                          <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to servers
                        </button>
                      </div>
                    <% :complete -> %>
                      <div class="text-center py-2">
                        <div class="bg-success/10 inline-flex p-3 rounded-full mb-3">
                          <.icon name="hero-check-circle" class="w-8 h-8 text-success" />
                        </div>
                        <p class="font-medium text-success">Configuration complete!</p>
                        <p class="text-sm text-base-content/60">
                          Review the details below and save.
                        </p>
                      </div>
                    <% :error -> %>
                      <div class="text-center space-y-4 py-2">
                        <div class="bg-error/10 inline-flex p-3 rounded-full">
                          <.icon name="hero-x-circle" class="w-8 h-8 text-error" />
                        </div>
                        <div>
                          <p class="font-medium text-error">Authentication failed</p>
                          <p class="text-sm text-base-content/60">Please try again</p>
                        </div>
                        <button
                          type="button"
                          class="btn btn-warning gap-2"
                          phx-click="start_plex_oauth"
                        >
                          <.icon name="hero-arrow-path" class="w-4 h-4" /> Try Again
                        </button>
                      </div>
                    <% _ -> %>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Manual entry fields - shown for Jellyfin, or Plex in manual mode, or after OAuth complete --%>
            <%= if @current_type != :plex or @plex_manual_entry or @plex_oauth_state == :complete do %>
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
                        placeholder={
                          if @current_type == :plex,
                            do: "http://192.168.1.100:32400",
                            else: "http://192.168.1.100:8096"
                        }
                        required
                      />
                      <p class="text-xs text-base-content/50 mt-1 ml-1">
                        <%= if @current_type == :plex do %>
                          Full URL including port (default: 32400)
                        <% else %>
                          Full URL including port (default: 8096)
                        <% end %>
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
                        <%= if @current_type == :plex do %>
                          X-Plex-Token from your Plex account settings
                        <% else %>
                          API Key from Dashboard → Advanced → API Keys
                        <% end %>
                      </p>
                    </div>
                  </div>

                  <%= if @current_type == :plex and @plex_manual_entry do %>
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm gap-1 self-start"
                      phx-click="toggle_plex_manual_entry"
                    >
                      <.icon name="hero-arrow-left" class="w-4 h-4" /> Use Sign in with Plex instead
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Watched Sync Section (only for Plex) --%>
            <%= if @current_type == :plex do %>
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

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
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
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @media_server_mode == :new, do: "Add Server", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_media_server_modal"></div>
    </div>
    """
  end

  # Media server type helpers
  defp media_server_type_icon(:plex), do: "hero-play-circle"
  defp media_server_type_icon(:jellyfin), do: "hero-tv"
  defp media_server_type_icon(_), do: "hero-server"

  defp media_server_type_badge_class(:plex), do: "badge-warning"
  defp media_server_type_badge_class(:jellyfin), do: "badge-info"
  defp media_server_type_badge_class(_), do: "badge-ghost"

  defp media_server_type_bg_class(:plex), do: "bg-warning/10"
  defp media_server_type_bg_class(:jellyfin), do: "bg-info/10"
  defp media_server_type_bg_class(_), do: "bg-base-300"

  defp media_server_type_icon_class(:plex), do: "text-warning"
  defp media_server_type_icon_class(:jellyfin), do: "text-info"
  defp media_server_type_icon_class(_), do: "text-base-content/60"

  defp media_server_type_label(:plex), do: "Plex"
  defp media_server_type_label(:jellyfin), do: "Jellyfin"

  defp media_server_type_label(type) when is_atom(type),
    do: Atom.to_string(type) |> String.capitalize()

  defp media_server_type_label(type), do: to_string(type)

  defp health_status_dot_class(:healthy), do: "bg-success animate-pulse"
  defp health_status_dot_class(:unhealthy), do: "bg-error"
  defp health_status_dot_class(:unknown), do: "bg-warning"
  defp health_status_dot_class(_), do: "bg-base-content/30"

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"

  defp run_label(%{status: :skipped, skip_reason: reason}) when is_binary(reason) do
    "Skipped: #{reason}"
  end

  defp run_label(%{status: :ok, counts: counts}) when is_map(counts) do
    imported = Map.get(counts, "imported") || Map.get(counts, :imported) || 0
    exported = Map.get(counts, "exported") || Map.get(counts, :exported) || 0
    "Synced #{imported} in, #{exported} out"
  end

  defp run_label(%{status: :error}), do: "Failed"
  defp run_label(_), do: "Failed"

  # Simplify plex.direct URLs to show just the IP/host and port
  # e.g., "https://10-1-1-5.abc123.plex.direct:32400" -> "(ssl) 10.1.1.5:32400"
  defp simplify_plex_url(url) when is_binary(url) do
    uri = URI.parse(url)

    host =
      case uri.host do
        nil ->
          url

        host ->
          if String.ends_with?(host, ".plex.direct") do
            # Extract IP from plex.direct subdomain (e.g., "10-1-1-5.abc123.plex.direct")
            case String.split(host, ".") do
              [ip_part | _] ->
                # Convert dashes to dots for IP addresses
                String.replace(ip_part, "-", ".")

              _ ->
                host
            end
          else
            host
          end
      end

    port = uri.port || if uri.scheme == "https", do: 443, else: 80

    "#{host}:#{port}"
  end

  defp simplify_plex_url(url), do: inspect(url)
end
