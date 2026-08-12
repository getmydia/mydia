defmodule MydiaWeb.AdminMediaServersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig
  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.MediaServer.Plex.Endpoint, as: PlexEndpoint
  alias Mydia.MediaServer.Plex.Home, as: PlexHome
  alias Mydia.MediaServer.Plex.Selection
  alias Mydia.Sync

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Media Servers")
     |> assign(:active_tab, :media_servers)
     |> clear_plex_profiles()
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Plex reachability probe result

  @impl true
  def handle_info({:plex_reachability, result}, socket) do
    if socket.assigns[:plex_oauth_state] == :complete do
      {:noreply, assign(socket, :plex_reachability, result)}
    else
      {:noreply, socket}
    end
  end

  ## Plex Home profile mapping

  @impl true
  def handle_info({:plex_profiles, config_id, result}, socket) do
    # Guarded on the id so a slow plex.tv answer for a server the operator has
    # already closed cannot repopulate the modal for a different one.
    case socket.assigns[:plex_profiles_config] do
      %{id: ^config_id} = config -> {:noreply, apply_profile_load(socket, config, result)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:plex_profiles_saved, config_id, result}, socket) do
    case socket.assigns[:plex_profiles_config] do
      %{id: ^config_id} = config -> {:noreply, apply_profile_save(socket, config, result)}
      _ -> {:noreply, socket}
    end
  end

  ## Media Server Events

  @impl true
  def handle_event("open_plex_profiles", %{"id" => id}, socket) do
    config = Settings.get_media_server_config!(id)

    {:noreply,
     socket
     |> assign(:plex_profiles_config, config)
     |> assign(:plex_profiles_state, :loading)
     |> assign(:plex_profiles, [])
     |> assign(:plex_profiles_users, Accounts.list_users())
     |> assign(:plex_profiles_mapping, %{})
     |> assign(:plex_profiles_saving, false)
     |> start_profile_load(config)}
  end

  @impl true
  def handle_event("close_plex_profiles", _params, socket) do
    {:noreply, clear_plex_profiles(socket)}
  end

  @impl true
  def handle_event("save_plex_profiles", params, socket) do
    config = socket.assigns.plex_profiles_config
    mapping = normalize_mapping(params["mapping"] || %{})
    parent = self()

    # Off the LiveView process: applying a mapping is one plex.tv profile switch
    # per newly linked profile, and blocking here would freeze every other event
    # on the page while they run.
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:plex_profiles_saved, config.id, PlexHome.apply_mapping(config, mapping)})
    end)

    {:noreply, assign(socket, :plex_profiles_saving, true)}
  end

  @impl true
  def handle_event("new_media_server", _params, socket) do
    changeset = Settings.change_media_server_config(%MediaServerConfig{}, %{type: :plex})

    {:noreply,
     socket
     |> assign(:show_media_server_modal, true)
     |> assign(:media_server_form, to_form(changeset))
     |> assign(:media_server_mode, :new)
     |> assign(:testing_media_server_connection, false)
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)
     |> assign(:plex_reachability, :checking)
     |> assign(:plex_manual_entry, false)
     |> assign(:plex_discovery, nil)
     |> assign(:plex_discovery_summary, nil)}
  end

  @impl true
  def handle_event("edit_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    if Settings.runtime_config?(server) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot edit runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
       )}
    else
      changeset = Settings.change_media_server_config(server)

      {:noreply,
       socket
       |> assign(:show_media_server_modal, true)
       |> assign(:media_server_form, to_form(changeset))
       |> assign(:media_server_mode, :edit)
       |> assign(:editing_media_server, server)
       |> assign(:testing_media_server_connection, false)
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)
       |> assign(:plex_oauth_servers, [])
       |> assign(:plex_oauth_token, nil)
       |> assign(:plex_reachability, :checking)
       |> assign(:plex_manual_entry, true)
       |> assign(:plex_discovery, nil)
       |> assign(:plex_discovery_summary, nil)}
    end
  end

  @impl true
  def handle_event("reconnect_plex", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    if Settings.runtime_config?(server) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot reconnect a runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
       )}
    else
      changeset = Settings.change_media_server_config(server)

      # Reuse the existing PIN modal bound to this config so reconnect
      # updates the row in place and never creates a second config.
      {:noreply,
       socket
       |> assign(:show_media_server_modal, true)
       |> assign(:media_server_form, to_form(changeset))
       |> assign(:media_server_mode, :edit)
       |> assign(:editing_media_server, server)
       |> assign(:testing_media_server_connection, false)
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)
       |> assign(:plex_oauth_servers, [])
       |> assign(:plex_oauth_token, nil)
       |> assign(:plex_manual_entry, false)
       |> assign(:plex_discovery, nil)
       |> assign(:plex_discovery_summary, nil)}
    end
  end

  @impl true
  def handle_event("validate_media_server", %{"media_server_config" => params}, socket) do
    params = Selection.merge_discovery(params, socket.assigns[:plex_discovery])

    server =
      case socket.assigns.media_server_mode do
        :new -> %MediaServerConfig{}
        :edit -> socket.assigns.editing_media_server
      end

    changeset =
      server
      |> Settings.change_media_server_config(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:media_server_form, to_form(changeset))
     |> reset_wizard_if_type_changed(params)}
  end

  @impl true
  def handle_event("save_media_server", %{"media_server_config" => params}, socket) do
    params = Selection.merge_discovery(params, socket.assigns[:plex_discovery])

    params =
      case socket.assigns.media_server_mode do
        :edit ->
          existing = socket.assigns.editing_media_server.connection_settings || %{}
          new_settings = Map.get(params, "connection_settings", %{})
          merged = Map.merge(existing, new_settings)
          Map.put(params, "connection_settings", merged)

        :new ->
          params
      end

    result =
      case socket.assigns.media_server_mode do
        :new -> Settings.create_media_server_config(params)
        :edit -> Settings.update_media_server_config(socket.assigns.editing_media_server, params)
      end

    case result do
      {:ok, server} ->
        maybe_seed_plex_links(server)

        {:noreply,
         socket
         |> assign(:show_media_server_modal, false)
         |> put_flash(:info, "Media server saved successfully")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :media_server_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    if Settings.runtime_config?(server) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot delete runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
       )}
    else
      case Settings.delete_media_server_config(server) do
        {:ok, _server} ->
          {:noreply,
           socket
           |> put_flash(:info, "Media server deleted successfully")
           |> load_data()}

        {:error, error} ->
          MydiaLogger.log_error(:liveview, "Failed to delete media server",
            error: error,
            operation: :delete_media_server,
            server_id: id,
            server_name: server.name,
            user_id: socket.assigns.current_user.id
          )

          error_msg = MydiaLogger.user_error_message(:delete_media_server, error)

          {:noreply, put_flash(socket, :error, error_msg)}
      end
    end
  end

  @impl true
  def handle_event("close_media_server_modal", _params, socket) do
    {:noreply, assign(socket, :show_media_server_modal, false)}
  end

  ## Plex OAuth Events

  @impl true
  def handle_event("start_plex_oauth", _params, socket) do
    case PlexOAuth.create_pin() do
      {:ok, %{id: pin_id, code: code}} ->
        auth_url = PlexOAuth.get_auth_url(code)

        {:noreply,
         socket
         |> assign(:plex_oauth_state, :authorizing)
         |> assign(:plex_oauth_pin_id, pin_id)
         |> push_event("open_plex_auth", %{url: auth_url, pin_id: pin_id})}

      {:error, reason} ->
        Logger.error("Failed to start Plex OAuth: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to start Plex authentication: #{reason}")}
    end
  end

  @impl true
  def handle_event("check_plex_pin", %{"pin_id" => pin_id}, socket) do
    case PlexOAuth.check_pin(pin_id) do
      {:ok, %{auth_token: token}} ->
        socket = assign(socket, :plex_oauth_token, token)

        case PlexOAuth.list_servers(token) do
          {:ok, servers} ->
            {:noreply,
             socket
             |> push_event("plex_auth_complete", %{})
             |> apply_selection(servers)}

          {:error, reason} ->
            Logger.error("Failed to fetch Plex servers: #{inspect(reason)}")

            {:noreply,
             socket
             |> assign(:plex_oauth_state, :error)
             |> put_flash(:error, "Failed to fetch Plex servers: #{reason}")
             |> push_event("plex_auth_failed", %{})}
        end

      :pending ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Plex PIN check failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:plex_oauth_state, :error)
         |> put_flash(:error, "Authentication failed: #{reason}")
         |> push_event("plex_auth_failed", %{})}
    end
  end

  @impl true
  def handle_event("plex_popup_closed", _params, socket) do
    if socket.assigns.plex_oauth_state == :authorizing do
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_plex_server", %{"server_id" => server_id}, socket) do
    case Enum.find(socket.assigns.plex_oauth_servers, &(&1.client_identifier == server_id)) do
      nil -> {:noreply, put_flash(socket, :error, "Server not found")}
      server -> {:noreply, attach_server(socket, server)}
    end
  end

  @impl true
  def handle_event("cancel_plex_oauth", _params, socket) do
    {:noreply,
     socket
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)
     |> assign(:plex_reachability, :checking)
     |> assign(:plex_discovery, nil)
     |> assign(:plex_discovery_summary, nil)
     |> push_event("plex_auth_cancelled", %{})}
  end

  @impl true
  def handle_event("toggle_plex_manual_entry", _params, socket) do
    {:noreply,
     socket
     |> assign(:plex_manual_entry, !socket.assigns.plex_manual_entry)
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)
     |> assign(:plex_reachability, :checking)
     |> assign(:plex_discovery, nil)
     |> assign(:plex_discovery_summary, nil)}
  end

  @impl true
  def handle_event("test_media_server", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)
    adapter = MediaServerClient.adapter_for(server)

    case adapter.test_connection(server) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection to #{server.name} successful!")
         |> load_data()}

      {:error, %Error{} = error} ->
        MydiaLogger.log_warning(:liveview, "Media server connection test failed",
          operation: :test_media_server,
          server_id: id,
          server_type: server.type,
          error: Error.message(error),
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Connection failed: #{Error.message(error)}")
         |> load_data()}
    end
  end

  @impl true
  def handle_event("sync_watched", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    # Server mode rather than a job for the clicking user. With per-user links in
    # play, a job carrying no link_id falls back to the config token, which reads
    # the admin's Plex watch state and writes it onto whoever clicked.
    changeset =
      Mydia.Jobs.MediaServerWatchedSync.new(%{
        "mode" => "server",
        "config_id" => server.id
      })

    case safe_insert(changeset) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Watched sync queued for #{server.name}")
         |> load_data()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start watched sync for #{server.name}")}
    end
  end

  @impl true
  def handle_event("test_media_server_connection", _params, socket) do
    changeset = socket.assigns.media_server_form.source
    params = Ecto.Changeset.apply_changes(changeset)

    type =
      case params.type do
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
        _ -> :plex
      end

    # `connections` and `machine_identifier` have to ride along. A server just
    # picked through the OAuth wizard has no url yet and addresses itself purely
    # through its advertised connections, so dropping them here made the test
    # button report "URL is required" for a server it had only just discovered.
    test_config = %MediaServerConfig{
      type: type,
      url: params.url,
      token: params.token,
      name: params.name || "Test",
      connections: params.connections || [],
      machine_identifier: params.machine_identifier
    }

    adapter = MediaServerClient.adapter_for(test_config)

    case adapter.test_connection(test_config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:testing_media_server_connection, false)
         |> put_flash(:info, "Connection successful!")}

      {:error, %Error{} = error} ->
        MydiaLogger.log_warning(:liveview, "Media server connection test failed",
          operation: :test_media_server_connection,
          server_type: type,
          error: Error.message(error),
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> assign(:testing_media_server_connection, false)
         |> put_flash(:error, "Connection failed: #{Error.message(error)}")}
    end
  end

  ## Private Helpers

  # A Plex account often carries the operator's own server plus any shared by
  # friends. Picking is only worth asking about when it is a real choice.
  defp apply_selection(socket, servers) do
    case Selection.auto_select(servers) do
      {:ok, server} ->
        attach_server(socket, server)

      {:ambiguous, ranked} ->
        socket
        |> assign(:plex_oauth_state, :selecting_server)
        |> assign(:plex_oauth_servers, ranked)

      {:error, :no_servers} ->
        socket
        |> assign(:plex_oauth_state, :error)
        |> assign(:plex_oauth_servers, [])
        |> put_flash(:error, "No Plex servers found for this account")
    end
  end

  defp attach_server(socket, server) do
    attrs = Selection.config_attrs(server, socket.assigns.plex_oauth_token)

    case socket.assigns.media_server_mode do
      :edit ->
        # Reconnect must update the existing row in place so user links and
        # sync state are not orphaned.
        attrs = Map.merge(attrs, %{last_auth_error: nil, last_auth_error_at: nil})

        case Settings.update_media_server_config(socket.assigns.editing_media_server, attrs) do
          {:ok, updated} ->
            maybe_seed_plex_links(updated)

            socket
            |> put_flash(:info, "Plex reconnected successfully")
            |> load_data()

          {:error, %Ecto.Changeset{} = changeset} ->
            socket
            |> assign(:plex_oauth_state, :error)
            |> assign(:media_server_form, to_form(changeset))
            |> put_flash(:error, "Failed to update media server")
        end

      :new ->
        changeset = Settings.change_media_server_config(%MediaServerConfig{}, attrs)

        socket
        |> assign(:plex_oauth_state, :complete)
        |> assign(:plex_reachability, :checking)
        # `plex_discovery` keeps the full attrs (including `token` and
        # `server_access_token`) so `Selection.merge_discovery/2` still has
        # what it needs on submit. `plex_discovery_summary` is the
        # template-facing view: only the fields the review panel actually
        # renders, so the two secrets never reach template scope.
        |> assign(:plex_discovery, attrs)
        |> assign(
          :plex_discovery_summary,
          Map.take(attrs, [:name, :machine_identifier, :connections])
        )
        |> start_reachability_probe(server)
        |> assign(:media_server_form, to_form(changeset))
    end
  end

  defp start_profile_load(socket, config) do
    parent = self()

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:plex_profiles, config.id, PlexHome.list_users(config)})
    end)

    socket
  end

  defp apply_profile_load(socket, config, {:ok, profiles}) do
    links = Settings.list_media_server_user_links(config.id)

    socket
    |> assign(:plex_profiles, profiles)
    |> assign(
      :plex_profiles_mapping,
      initial_mapping(profiles, links, socket.assigns.plex_profiles_users)
    )
    |> assign(:plex_profiles_state, :ready)
  end

  defp apply_profile_load(socket, _config, {:error, %Error{} = error}) do
    assign(
      socket,
      :plex_profiles_state,
      {:error, "Could not load Plex Home profiles: #{Error.message(error)}"}
    )
  end

  defp apply_profile_save(socket, config, {:ok, links}) do
    # A fresh mapping is worth acting on immediately: the operator opened this
    # because sync had been sitting idle, and making them wait for the next
    # half-hourly tick to see whether it worked is the wrong answer.
    if links != [], do: enqueue_server_sync(config)

    socket
    |> clear_plex_profiles()
    |> put_flash(:info, link_flash(links, config))
    |> load_data()
  end

  defp apply_profile_save(socket, _config, {:error, :duplicate_user}) do
    socket
    |> assign(:plex_profiles_saving, false)
    |> put_flash(:error, "Each Mydia user can be linked to only one Plex profile.")
  end

  defp apply_profile_save(socket, _config, {:error, %Error{} = error}) do
    socket
    |> assign(:plex_profiles_saving, false)
    |> put_flash(:error, "Could not save Plex profile links: #{Error.message(error)}")
  end

  defp apply_profile_save(socket, _config, {:error, reason}) do
    MydiaLogger.log_warning(:liveview, "Saving Plex profile links failed",
      operation: :save_plex_profiles,
      error: inspect(reason)
    )

    socket
    |> assign(:plex_profiles_saving, false)
    |> put_flash(:error, "Could not save Plex profile links.")
  end

  defp link_flash([], config), do: "No Plex profiles are linked to #{config.name}."

  defp link_flash(links, config) do
    "Linked #{length(links)} Plex #{if length(links) == 1, do: "profile", else: "profiles"} " <>
      "on #{config.name}. Watched sync queued."
  end

  defp enqueue_server_sync(config) do
    %{"mode" => "server", "config_id" => config.id}
    |> Mydia.Jobs.MediaServerWatchedSync.new()
    |> safe_insert()

    :ok
  end

  # A blank select is "do not sync this profile", which has to survive as an
  # explicit nil: it is the difference between unlinking a profile and never
  # having been asked about it.
  defp normalize_mapping(mapping) do
    Map.new(mapping, fn
      {account_id, ""} -> {account_id, nil}
      {account_id, user_id} -> {account_id, user_id}
    end)
  end

  # A saved link is the operator's own decision and always wins. A username
  # match is only a suggestion for a profile nobody has mapped yet, and it must
  # never propose a user another profile already holds: two profiles on one user
  # is refused on save, and offering that as the default would hand the operator
  # a form that cannot be submitted without them working out why.
  defp initial_mapping(profiles, links, users) do
    by_account = Map.new(links, &{&1.plex_account_id, &1.user_id})
    by_username = Map.new(users, &{String.downcase(&1.username), &1.id})

    {mapping, _taken} =
      Enum.reduce(profiles, {%{}, MapSet.new(Map.values(by_account))}, fn profile, {acc, taken} ->
        case Map.get(by_account, profile.plex_account_id) do
          nil ->
            case Map.get(by_username, String.downcase(profile.username || "")) do
              suggestion when is_binary(suggestion) ->
                if MapSet.member?(taken, suggestion) do
                  {Map.put(acc, profile.plex_account_id, nil), taken}
                else
                  {Map.put(acc, profile.plex_account_id, suggestion),
                   MapSet.put(taken, suggestion)}
                end

              _ ->
                {Map.put(acc, profile.plex_account_id, nil), taken}
            end

          user_id ->
            {Map.put(acc, profile.plex_account_id, user_id), taken}
        end
      end)

    mapping
  end

  defp clear_plex_profiles(socket) do
    socket
    |> assign(:plex_profiles_config, nil)
    |> assign(:plex_profiles_state, :loading)
    |> assign(:plex_profiles, [])
    |> assign(:plex_profiles_users, [])
    |> assign(:plex_profiles_mapping, %{})
    |> assign(:plex_profiles_saving, false)
  end

  # Advisory only. The review step never blocks Save on the result, because a
  # server that is merely powered off is still worth saving: rediscovery finds
  # it when it comes back.
  defp start_reachability_probe(socket, server) do
    parent = self()
    token = socket.assigns.plex_oauth_token
    connections = server.connections

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:plex_reachability, PlexEndpoint.probe_connections(connections, token)})
    end)

    socket
  end

  # Moving the Type select off Plex makes the discovered data describe something
  # other than what is being saved. Resetting the wizard is what stops a stale
  # "Configuration complete!" panel from sitting above a Jellyfin form.
  defp reset_wizard_if_type_changed(socket, %{"type" => "plex"}), do: socket

  defp reset_wizard_if_type_changed(socket, _params) do
    if socket.assigns[:plex_discovery] do
      socket
      |> assign(:plex_discovery, nil)
      |> assign(:plex_discovery_summary, nil)
      |> assign(:plex_oauth_state, :idle)
      |> assign(:plex_reachability, :checking)
    else
      socket
    end
  end

  # Seeds per-user Plex links after any Plex config is persisted. Fires on every
  # Plex save, including one that only flips a sync direction: the job is cheap
  # to enqueue, its 120-second uniqueness window collapses bursts, and the
  # alternative is dirty-field tracking that would silently miss a changed token.
  defp maybe_seed_plex_links(%MediaServerConfig{type: :plex, id: id}) when is_binary(id) do
    %{"config_id" => id}
    |> Mydia.Jobs.PlexLinkSeed.new()
    |> safe_insert()

    :ok
  end

  defp maybe_seed_plex_links(_config), do: :ok

  # Oban's supervisor isn't started under `testing: :manual` (see
  # `Mydia.Application.oban_children/0`), so a bare `Oban.insert/1` raises a
  # RuntimeError there. Falling back to a plain repo insert keeps this working
  # both in that mode and in production, matching the pattern already used by
  # `Mydia.Jobs.MediaServerWatchedSync.safe_insert/1`.
  defp safe_insert(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Mydia.Repo.insert(changeset)
  end

  defp load_data(socket) do
    media_servers = Settings.list_media_server_configs()
    media_server_health = get_media_server_health_status(media_servers)

    last_runs =
      Map.new(media_servers, fn server ->
        {server.id, Sync.last_run(to_string(server.type), server.id)}
      end)

    socket
    |> assign(:media_servers, media_servers)
    |> assign(:media_server_health, media_server_health)
    |> assign(:last_runs, last_runs)
    |> assign(:show_media_server_modal, false)
    |> assign(:testing_media_server_connection, false)
    |> assign(:plex_oauth_state, :idle)
    |> assign(:plex_oauth_servers, [])
    |> assign(:plex_reachability, :checking)
    |> assign(:plex_manual_entry, false)
    |> assign(:plex_discovery, nil)
    |> assign(:plex_discovery_summary, nil)
  end

  defp get_media_server_health_status(media_servers) do
    media_servers
    |> Enum.map(fn server -> {server.id, %{status: :unknown}} end)
    |> Map.new()
  end
end
