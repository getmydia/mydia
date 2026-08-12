defmodule MydiaWeb.AdminDownloadClientsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.StallDetector
  alias Mydia.Settings

  # Client types that surface category configuration in the admin form.
  # Blackhole uses filesystem paths and debrid uses a hosted service, so
  # neither has a per-content-type category taxonomy.
  @category_aware_types ~w(qbittorrent transmission rtorrent sabnzbd nzbget)

  # Client types that surface the 5-tier priority profile UI. Same set as
  # `@category_aware_types` minus blackhole — every adapter that maps the
  # abstract priority to a native value is listed here.
  @priority_profile_types ~w(qbittorrent transmission rtorrent sabnzbd nzbget)

  # Client types that can point at a remote host reachable over SFTP, so they
  # surface the remote seedbox (pull-over-SFTP) section. Blackhole and debrid
  # don't run on a remote host in this sense, and sabnzbd/nzbget (Usenet) have
  # no seedbox concept.
  @remote_fetch_types ~w(qbittorrent transmission rqbit rtorrent)

  # Placeholder hints shown in the per-tier priority profile inputs. Each
  # adapter has its own native priority value domain; the placeholder mirrors
  # the hardcoded default mapping so users see what value they'd get if they
  # left the override blank.
  @priority_profile_placeholders %{
    "sabnzbd" => %{
      "verylow" => "-100",
      "low" => "-1",
      "normal" => "0",
      "high" => "1",
      "veryhigh" => "2"
    },
    "nzbget" => %{
      "verylow" => "-100",
      "low" => "-50",
      "normal" => "0",
      "high" => "50",
      "veryhigh" => "100"
    },
    "qbittorrent" => %{
      "verylow" => "(unset)",
      "low" => "(unset)",
      "normal" => "(unset)",
      "high" => "(unset)",
      "veryhigh" => "(unset)"
    },
    "transmission" => %{
      "verylow" => "-1",
      "low" => "-1",
      "normal" => "0",
      "high" => "1",
      "veryhigh" => "1"
    },
    "rtorrent" => %{
      "verylow" => "0",
      "low" => "1",
      "normal" => "2",
      "high" => "3",
      "veryhigh" => "3"
    }
  }

  @priority_tiers [
    {"verylow", "Very Low"},
    {"low", "Low"},
    {"normal", "Normal"},
    {"high", "High"},
    {"veryhigh", "Very High"}
  ]

  @content_types [
    {"movie", "Movies"},
    {"tv", "TV Shows"},
    {"music", "Music"}
  ]

  @doc """
  Renders the Download Clients tab content.
  """
  attr :download_clients, :list, required: true
  attr :client_health, :map, required: true

  def download_clients_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-arrow-down-tray" class="w-5 h-5 opacity-60" /> Download Clients
          <span class="badge badge-ghost">{length(@download_clients)}</span>
        </h2>
        <button class="btn btn-sm btn-primary" phx-click="new_download_client">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

      <%= if @download_clients == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No download clients configured yet. Add qBittorrent or Transmission to get started.
          </span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for client <- @download_clients do %>
            <% health = Map.get(@client_health, client.id, %{status: :unknown}) %>
            <% is_runtime = Settings.runtime_config?(client) %>

            <div class="p-3 sm:p-4">
              <%!-- Mobile: stacked, Desktop: flex row --%>
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <%!-- Client Info --%>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2 flex-wrap">
                    {client.name}
                    <%= if is_runtime do %>
                      <span
                        class="badge badge-primary badge-xs tooltip"
                        data-tip="Configured via environment variables (read-only)"
                      >
                        <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                      </span>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-60 mt-1 truncate">
                    <span class="font-mono">
                      <%= cond do %>
                        <% client.type == :blackhole -> %>
                          {get_in(client.connection_settings || %{}, ["watch_folder"]) ||
                            "No watch folder"}
                        <% client.type == :debrid -> %>
                          {debrid_provider_label(client)}
                        <% true -> %>
                          {if client.use_ssl, do: "https://", else: "http://"}{client.host}:{client.port}
                      <% end %>
                    </span>
                    <%= if client.category do %>
                      <span class="ml-2">Category: {client.category}</span>
                    <% end %>
                  </div>
                </div>

                <%!-- Status Badges + Actions row --%>
                <div class="flex flex-wrap items-center gap-2">
                  <%!-- Status Badges --%>
                  <span class="badge badge-sm badge-outline">{client.type}</span>
                  <span
                    :if={client_remote_fetch_enabled?(client)}
                    class="badge badge-sm badge-outline gap-1"
                    title="Pulls completed torrents from a remote seedbox over SFTP"
                  >
                    <.icon name="hero-cloud-arrow-down" class="w-3 h-3" /> Seedbox
                  </span>
                  <span class={[
                    "badge badge-sm",
                    if(client.enabled, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if client.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                  <span class={"badge badge-sm #{health_status_badge_class(health.status)}"}>
                    <.icon name={health_status_icon(health.status)} class="w-3 h-3 mr-1" />
                    {health_status_label(health.status)}
                  </span>
                  <%= if health.status == :unhealthy and health[:error] do %>
                    <div class="tooltip tooltip-left" data-tip={health.error}>
                      <.icon name="hero-information-circle" class="w-4 h-4 text-error" />
                    </div>
                  <% end %>
                  <%= if health.status == :healthy and health[:details] && Map.get(health.details, :version) do %>
                    <div
                      class="tooltip tooltip-left"
                      data-tip={"Version: #{health.details.version}"}
                    >
                      <.icon name="hero-information-circle" class="w-4 h-4 text-success" />
                    </div>
                  <% end %>

                  <%!-- Actions --%>
                  <div class="join ml-auto sm:ml-2">
                    <button
                      class="btn btn-sm btn-ghost join-item"
                      phx-click="test_download_client"
                      phx-value-id={client.id}
                      title="Test Connection"
                    >
                      <.icon name="hero-signal" class="w-4 h-4" />
                    </button>
                    <%= if is_runtime do %>
                      <div class="tooltip" data-tip="Cannot edit runtime-configured clients">
                        <button class="btn btn-sm btn-ghost join-item" disabled>
                          <.icon name="hero-pencil" class="w-4 h-4 opacity-30" />
                        </button>
                      </div>
                      <div class="tooltip" data-tip="Cannot delete runtime-configured clients">
                        <button class="btn btn-sm btn-ghost join-item" disabled>
                          <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                        </button>
                      </div>
                    <% else %>
                      <button
                        class="btn btn-sm btn-ghost join-item"
                        phx-click="edit_download_client"
                        phx-value-id={client.id}
                        title="Edit"
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        id={"delete-download-client-#{client.id}"}
                        class="btn btn-sm btn-ghost join-item text-error"
                        phx-click="confirm_delete_download_client"
                        phx-value-id={client.id}
                        title="Delete"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
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
  Renders the Download Client modal.
  """
  attr :download_client_form, :any, required: true
  attr :download_client_mode, :atom, required: true
  attr :testing_download_client_connection, :boolean, default: false
  attr :editing_download_client, :any, default: nil

  def download_client_modal(assigns) do
    # Get the currently selected type to conditionally show fields. The
    # `nil`/`""` clauses match before the catch-all `is_atom` branch
    # because `is_atom(nil)` would otherwise stringify to `"nil"` for a
    # fresh changeset — defaulting to qBittorrent yields a more useful
    # empty form.
    selected_type =
      case Phoenix.HTML.Form.input_value(assigns.download_client_form, :type) do
        nil -> "qbittorrent"
        "" -> "qbittorrent"
        type when is_binary(type) -> type
        type when is_atom(type) -> Atom.to_string(type)
        _ -> "qbittorrent"
      end

    form = assigns.download_client_form

    # Derive the current per-content-type categories map for prefilling
    # inputs. Falls back to the legacy single `:category` value for all
    # three slots when the new map is empty — this surfaces existing
    # behaviour without forcing the user to re-enter on first edit.
    categories_value =
      case Phoenix.HTML.Form.input_value(form, :categories) do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> %{}
      end

    legacy_category =
      case Phoenix.HTML.Form.input_value(form, :category) do
        value when is_binary(value) -> value
        _ -> ""
      end

    has_legacy_only? = map_size(categories_value) == 0 and legacy_category != ""

    priority_profile_value =
      case Phoenix.HTML.Form.input_value(form, :priority_profile) do
        map when is_map(map) -> map
        _ -> %{}
      end

    show_categories? = selected_type in @category_aware_types
    show_priority_profile? = selected_type in @priority_profile_types
    show_remote_fetch? = selected_type in @remote_fetch_types

    priority_placeholders = Map.get(@priority_profile_placeholders, selected_type, %{})

    assigns =
      assigns
      |> assign(:selected_type, selected_type)
      |> assign(:categories_value, categories_value)
      |> assign(:legacy_category, legacy_category)
      |> assign(:has_legacy_only?, has_legacy_only?)
      |> assign(:priority_profile_value, priority_profile_value)
      |> assign(:show_categories?, show_categories?)
      |> assign(:show_priority_profile?, show_priority_profile?)
      |> assign(:show_remote_fetch?, show_remote_fetch?)
      |> assign(:priority_placeholders, priority_placeholders)
      |> assign(:priority_tiers, @priority_tiers)
      |> assign(:content_types, @content_types)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <.form
          for={@download_client_form}
          id="download-client-form"
          phx-change="validate_download_client"
          phx-submit="save_download_client"
        >
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-5">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                <.icon
                  name={
                    if(@download_client_mode == :new,
                      do: "hero-plus-circle",
                      else: "hero-pencil-square"
                    )
                  }
                  class="w-5 h-5 text-primary"
                />
              </div>
              <div>
                <h3 class="font-bold text-lg">
                  {if @download_client_mode == :new,
                    do: "Add Download Client",
                    else: "Edit Download Client"}
                </h3>
                <p class="text-sm text-base-content/60">
                  {if @download_client_mode == :new,
                    do: "Configure a new download client",
                    else: "Update client settings"}
                </p>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Enabled</span>
              <input
                type="checkbox"
                name={@download_client_form[:enabled].name}
                value="true"
                checked={
                  Phoenix.HTML.Form.normalize_value("checkbox", @download_client_form[:enabled].value)
                }
                class="toggle toggle-success toggle-sm"
              />
            </label>
          </div>
          <div class="space-y-5">
            <%!-- Basic Settings Row --%>
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-3">
                <.input field={@download_client_form[:name]} type="text" label="Name" required />
              </div>
              <div class="col-span-4 md:col-span-2">
                <.input
                  field={@download_client_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"qBittorrent", "qbittorrent"},
                    {"Transmission", "transmission"},
                    {"rqbit", "rqbit"},
                    {"rTorrent", "rtorrent"},
                    {"Blackhole", "blackhole"},
                    {"SABnzbd", "sabnzbd"},
                    {"NZBGet", "nzbget"},
                    {"Debrid", "debrid"}
                  ]}
                  required
                />
              </div>
              <div class="col-span-2 md:col-span-1">
                <.input field={@download_client_form[:priority]} type="number" label="Priority" />
              </div>
            </div>

            <div class="divider my-1"></div>

            <%= cond do %>
              <% @selected_type == "debrid" -> %>
                <%!-- Debrid-specific fields --%>
                <div class="space-y-3">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                    <.icon name="hero-cloud" class="w-4 h-4" />
                    <span>Debrid Service</span>
                  </div>

                  <div class="alert alert-info text-sm py-2">
                    <.icon name="hero-information-circle" class="w-4 h-4" />
                    <span>
                      Releases are submitted to your chosen provider and downloaded on their
                      infrastructure. Your IP never participates in the swarm.
                    </span>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input
                      name="download_client_config[connection_settings][provider]"
                      type="select"
                      label="Provider"
                      options={[
                        {"Real-Debrid", "real_debrid"},
                        {"AllDebrid", "all_debrid"},
                        {"Premiumize", "premiumize"},
                        {"TorBox", "tor_box"}
                      ]}
                      value={
                        get_in(
                          Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                            %{},
                          ["provider"]
                        ) || "real_debrid"
                      }
                      required
                    />
                    <.input
                      field={@download_client_form[:api_key]}
                      type="password"
                      label="API Key"
                      required
                    />
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input
                      field={@download_client_form[:download_directory]}
                      type="text"
                      label="Download Directory (optional)"
                      placeholder="/data/debrid-downloads"
                    />
                  </div>

                  <p class="text-xs text-base-content/60">
                    Where Mydia writes files pulled from the debrid provider before
                    importing them into your library. Defaults to <code>/data/debrid-downloads</code>
                    when the standard <code>/data</code>
                    volume is mounted, otherwise the system temp directory.
                    Override only if you need a specific filesystem (e.g., a faster
                    disk or one with more headroom).
                  </p>
                </div>
              <% @selected_type == "blackhole" -> %>
                <%!-- Blackhole-specific fields --%>
                <div class="space-y-3">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                    <.icon name="hero-folder" class="w-4 h-4" />
                    <span>Folder Settings</span>
                  </div>

                  <div class="alert alert-info text-sm py-2">
                    <.icon name="hero-information-circle" class="w-4 h-4" />
                    <span>
                      Blackhole writes .torrent files to a watch folder for external processing.
                    </span>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input
                      name="download_client_config[connection_settings][watch_folder]"
                      type="text"
                      label="Watch Folder"
                      placeholder="/path/to/watch"
                      value={
                        get_in(
                          Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                            %{},
                          ["watch_folder"]
                        ) || ""
                      }
                      required
                    />
                    <.input
                      name="download_client_config[connection_settings][completed_folder]"
                      type="text"
                      label="Completed Folder"
                      placeholder="/path/to/completed"
                      value={
                        get_in(
                          Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                            %{},
                          ["completed_folder"]
                        ) || ""
                      }
                      required
                    />
                  </div>

                  <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                    <div class="flex items-center gap-3">
                      <.icon name="hero-folder-open" class="w-4 h-4 text-base-content/60" />
                      <div>
                        <span class="text-sm font-medium">Category Subfolders</span>
                        <p class="text-xs text-base-content/50">Create movies/tv subfolders</p>
                      </div>
                    </div>
                    <input
                      type="checkbox"
                      name="download_client_config[connection_settings][use_category_subfolders]"
                      value="true"
                      checked={
                        get_in(
                          Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                            %{},
                          ["use_category_subfolders"]
                        ) == true
                      }
                      class="toggle toggle-primary toggle-sm"
                    />
                  </div>
                </div>
              <% true -> %>
                <%!-- Network client fields --%>
                <div class="space-y-3">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                    <.icon name="hero-server" class="w-4 h-4" />
                    <span>Connection</span>
                  </div>

                  <div class="grid grid-cols-6 gap-3">
                    <div class="col-span-6 md:col-span-4">
                      <.input
                        field={@download_client_form[:host]}
                        type="text"
                        label="Host"
                        placeholder="localhost"
                        required
                      />
                    </div>
                    <div class="col-span-3 md:col-span-1">
                      <.input
                        field={@download_client_form[:port]}
                        type="number"
                        label="Port"
                        required
                      />
                    </div>
                    <div class="col-span-3 md:col-span-1">
                      <.input field={@download_client_form[:use_ssl]} type="checkbox" label="SSL" />
                    </div>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input field={@download_client_form[:username]} type="text" label="Username" />
                    <.input field={@download_client_form[:password]} type="password" label="Password" />
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input field={@download_client_form[:api_key]} type="password" label="API Key" />
                    <.input
                      field={@download_client_form[:url_base]}
                      type="text"
                      label="URL Base"
                      placeholder="/transmission/"
                    />
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                    <.input
                      field={@download_client_form[:download_directory]}
                      type="text"
                      label="Download Directory"
                    />
                  </div>
                </div>
            <% end %>

            <%!-- Per-content-type categories. Hidden for blackhole and debrid clients. --%>
            <%= if @show_categories? do %>
              <div class="space-y-3" id="download-client-categories">
                <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                  <.icon name="hero-tag" class="w-4 h-4" />
                  <span>Categories</span>
                </div>

                <%= if @has_legacy_only? do %>
                  <div class="alert alert-warning text-sm py-2">
                    <.icon name="hero-information-circle" class="w-4 h-4" />
                    <span>
                      This client uses the legacy single category
                      <code class="font-mono">{@legacy_category}</code>
                      for all content types. Saving will migrate it to per-content-type categories below.
                    </span>
                  </div>
                <% end %>

                <p class="text-xs text-base-content/50">
                  Optional. Routes downloads to the right client-side category by content type.
                </p>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                  <%= for {key, label} <- @content_types do %>
                    <.input
                      name={"download_client_config[categories][#{key}]"}
                      id={"download-client-categories-#{key}"}
                      type="text"
                      label={label}
                      placeholder="mydia"
                      value={
                        Map.get(@categories_value, key) || (@has_legacy_only? && @legacy_category) ||
                          ""
                      }
                    />
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Stalled timeout. Visible for every client type. The entered
                 value is only the FIRST threshold; the give-up deadline is
                 derived from it and was previously invisible everywhere. --%>
            <div class="space-y-2">
              <.input
                field={@download_client_form[:incomplete_grace_minutes]}
                id="download-client-grace-minutes"
                type="number"
                label="Stalled timeout (minutes)"
                placeholder="60"
                min="1"
              />
              <% grace = grace_minutes_value(@download_client_form[:incomplete_grace_minutes].value) %>
              <% escalation = StallDetector.escalation_minutes(grace) %>
              <p class="text-xs text-base-content/50">
                Flagged as stalled after {format_duration(grace * 60)} without progress.
                If it still hasn't moved {format_duration(escalation * 60)} later
                ({format_duration((grace + escalation) * 60)} total), Mydia removes it
                and searches for a different release.
              </p>
            </div>

            <%!-- Priority profile (collapsed advanced section). --%>
            <%= if @show_priority_profile? do %>
              <details
                class="collapse collapse-arrow bg-base-200"
                id="download-client-priority-profile"
              >
                <summary class="collapse-title text-sm font-medium flex items-center gap-2">
                  <.icon name="hero-bolt" class="w-4 h-4 text-base-content/60" />
                  <span>Advanced: Priority profile</span>
                  <span class="text-xs text-base-content/50">
                    (overrides the per-tier value sent to the client)
                  </span>
                </summary>
                <div class="collapse-content space-y-3">
                  <p class="text-xs text-base-content/50">
                    Map each abstract priority tier to the value this client understands.
                    Leave blank to use the adapter's built-in default (shown as placeholder).
                  </p>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
                    <%= for {key, label} <- @priority_tiers do %>
                      <.input
                        name={"download_client_config[priority_profile][#{key}]"}
                        id={"download-client-priority-#{key}"}
                        type="text"
                        label={label}
                        placeholder={Map.get(@priority_placeholders, key) || ""}
                        value={Map.get(@priority_profile_value, key) || ""}
                      />
                    <% end %>
                  </div>
                </div>
              </details>
            <% end %>

            <%!-- Remote seedbox (SFTP pull). Visible only for network torrent-client
                 types that can point at a remote host. --%>
            <%= if @show_remote_fetch? do %>
              <details class="collapse collapse-arrow bg-base-200" id="download-client-remote-fetch">
                <summary class="collapse-title text-sm font-medium">
                  Remote seedbox (pull over SFTP)
                </summary>
                <div class="collapse-content space-y-3">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="checkbox"
                      name="download_client_config[connection_settings][remote_fetch][enabled]"
                      value="true"
                      checked={remote_fetch_value(@download_client_form, "enabled") in [true, "true"]}
                      class="checkbox checkbox-sm"
                    />
                    <span class="label-text">
                      Pull completed torrents from this client's host over SFTP
                    </span>
                  </label>

                  <p class="text-xs text-base-content/60">
                    Connection trust is not verified (no host-key checking) — only connect to hosts you control.
                  </p>

                  <.input
                    name="download_client_config[connection_settings][remote_fetch][host]"
                    type="text"
                    label="SFTP Host"
                    placeholder="seedbox.example.com"
                    value={remote_fetch_value(@download_client_form, "host")}
                  />

                  <.input
                    name="download_client_config[connection_settings][remote_fetch][port]"
                    type="number"
                    label="SFTP Port"
                    value={remote_fetch_value(@download_client_form, "port") || 22}
                  />

                  <.input
                    name="download_client_config[connection_settings][remote_fetch][username]"
                    type="text"
                    label="SFTP Username"
                    value={remote_fetch_value(@download_client_form, "username")}
                  />

                  <.input
                    name="download_client_config[connection_settings][remote_fetch][auth_method]"
                    type="select"
                    label="Authentication"
                    options={
                      Enum.map(
                        Mydia.Settings.DownloadClientConfig.remote_fetch_auth_methods(),
                        &{auth_method_label(&1), &1}
                      )
                    }
                    value={remote_fetch_value(@download_client_form, "auth_method") || "password"}
                  />

                  <%= if remote_fetch_value(@download_client_form, "auth_method") == "ssh_key" do %>
                    <.input
                      name="download_client_config[connection_settings][remote_fetch][private_key]"
                      type="textarea"
                      label="Private Key (PEM)"
                      value={remote_fetch_value(@download_client_form, "private_key")}
                    />
                    <.input
                      name="download_client_config[connection_settings][remote_fetch][passphrase]"
                      type="password"
                      label="Passphrase (optional)"
                      value={remote_fetch_value(@download_client_form, "passphrase")}
                    />
                  <% else %>
                    <.input
                      name="download_client_config[connection_settings][remote_fetch][password]"
                      type="password"
                      label="SFTP Password"
                      value={remote_fetch_value(@download_client_form, "password")}
                    />
                  <% end %>

                  <details class="collapse collapse-arrow bg-base-100">
                    <summary class="collapse-title text-xs font-medium">Advanced</summary>
                    <div class="collapse-content space-y-3">
                      <.input
                        name="download_client_config[connection_settings][remote_fetch][remote_path_prefix]"
                        type="text"
                        label="Remote Path Prefix Override"
                        placeholder="Leave blank unless SFTP is chrooted differently from the torrent client"
                        value={remote_fetch_value(@download_client_form, "remote_path_prefix")}
                      />

                      <.input
                        name="download_client_config[connection_settings][remote_fetch][max_concurrent_transfers]"
                        type="number"
                        label="Max Concurrent Transfers"
                        value={
                          remote_fetch_value(@download_client_form, "max_concurrent_transfers") || 2
                        }
                      />

                      <label class="label cursor-pointer justify-start gap-3">
                        <input
                          type="checkbox"
                          name="download_client_config[connection_settings][remote_fetch][delete_after_transfer]"
                          value="true"
                          checked={
                            remote_fetch_value(@download_client_form, "delete_after_transfer") in [
                              true,
                              "true"
                            ]
                          }
                          class="checkbox checkbox-sm"
                        />
                        <span class="label-text">Delete the remote copy after a verified transfer</span>
                      </label>
                    </div>
                  </details>

                  <div class="pt-1">
                    <button
                      type="button"
                      class="btn btn-sm btn-outline"
                      phx-click="test_seedbox_connection"
                      disabled={remote_fetch_value(@download_client_form, "host") in [nil, ""]}
                    >
                      <.icon name="hero-signal" class="w-4 h-4" /> Test SFTP Connection
                    </button>
                  </div>
                </div>
              </details>
            <% end %>

            <div class="divider my-1"></div>

            <%!-- Options Section --%>
            <div class="space-y-3">
              <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                <span>Options</span>
              </div>

              <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                <div class="flex items-center gap-3">
                  <.icon name="hero-trash" class="w-4 h-4 text-base-content/60" />
                  <div>
                    <span class="text-sm font-medium">Remove After Import</span>
                    <p class="text-xs text-base-content/50">
                      Remove downloads from client after importing
                    </p>
                  </div>
                </div>
                <input
                  type="checkbox"
                  name={@download_client_form[:remove_completed].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value(
                      "checkbox",
                      @download_client_form[:remove_completed].value
                    )
                  }
                  class="toggle toggle-primary toggle-sm"
                />
              </div>
            </div>
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_download_client_modal">
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-outline btn-secondary gap-2"
              phx-click="test_download_client_connection"
              disabled={@testing_download_client_connection}
            >
              <%= if @testing_download_client_connection do %>
                <span class="loading loading-spinner loading-sm"></span> Testing...
              <% else %>
                <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
              <% end %>
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @download_client_mode == :new, do: "Add Client", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_download_client_modal"></div>
    </div>
    """
  end

  @doc """
  Renders the delete-confirmation modal for a download client, warning the
  operator how many downloads are still waiting on it.

  The count comes from `Mydia.Downloads.count_downloads_for_client/1` and
  excludes imported downloads, which keep their row as history and are
  untouched by the delete. The copy is hedged about where the rest end up
  because not all of them land in Issues: a row that is downloaded but not yet
  imported, or one that was never matched, never enters the missing handler
  that writes the Issues-tab error.
  """
  attr :client, :map, default: nil
  attr :count, :integer, default: 0

  def delete_download_client_modal(assigns) do
    ~H"""
    <div :if={@client} id="delete-download-client-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Delete '{@client.name}'?</h3>

        <p :if={@count > 0} class="py-2">
          {@count} {if @count == 1, do: "download is", else: "downloads are"} still waiting on
          this client. Deleting it will not stop them in the client itself, and the ones still
          in flight move to the Issues tab where you can clear them. If you re-add a client
          holding these same torrents, Mydia picks them back up automatically.
        </p>

        <p :if={@count == 0} class="py-2">
          No downloads are waiting on this client.
        </p>

        <div class="modal-action">
          <button
            id="cancel-delete-download-client"
            class="btn btn-ghost"
            phx-click="cancel_delete_download_client"
          >
            Cancel
          </button>
          <button
            id="confirm-delete-download-client"
            class="btn btn-error"
            phx-click="delete_download_client"
            phx-disable-with="Deleting..."
          >
            Delete client
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_delete_download_client"></div>
    </div>
    """
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"

  # Renders a short summary string for a debrid client row in the list.
  # Surfaces the provider's human-readable label (e.g., "Real-Debrid"); the
  # debrid type itself isn't routed by host/port so the host/port fallback
  # used by other clients would render an empty "http://:" string.
  defp debrid_provider_label(client) do
    case get_in(client.connection_settings || %{}, ["provider"]) do
      provider when is_binary(provider) ->
        Mydia.Downloads.Client.Debrid.Provider.label_for(provider)

      _ ->
        "No provider"
    end
  end

  # Reads a key out of the nested `connection_settings.remote_fetch` map for
  # the form's current (possibly unsaved) state, mirroring the
  # `get_in(Phoenix.HTML.Form.input_value(...), [...])` pattern used above for
  # blackhole's `watch_folder`.
  defp remote_fetch_value(form, key) do
    get_in(
      Phoenix.HTML.Form.input_value(form, :connection_settings) || %{},
      ["remote_fetch", key]
    )
  end

  defp auth_method_label("password"), do: "Password"
  defp auth_method_label("ssh_key"), do: "SSH key"

  # Whether a client's saved connection_settings has remote_fetch enabled,
  # for the row-level "Seedbox" badge in the list. `enabled` is stored as
  # whatever the form submitted — HTML checkboxes send the string "true",
  # not the boolean — so both forms are accepted here, mirroring
  # `DownloadClientConfig.validate_remote_fetch_config/1`.
  defp client_remote_fetch_enabled?(client) do
    case get_in(client.connection_settings || %{}, ["remote_fetch", "enabled"]) do
      enabled when enabled in [true, "true"] -> true
      _ -> false
    end
  end

  # The form value arrives as a string while the operator types, as an integer
  # from a loaded config, and as nil for a fresh form. Anything unusable falls
  # back to the schema default so the help text never renders a broken number.
  defp grace_minutes_value(value) do
    case value do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> n
          _ -> Settings.default_grace_minutes()
        end

      _ ->
        Settings.default_grace_minutes()
    end
  end
end
