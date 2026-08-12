defmodule MydiaWeb.AdminMediaServersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig
  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Health, as: MediaServerHealth
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.MediaServer.Plex.Endpoint, as: PlexEndpoint
  alias Mydia.MediaServer.Plex.Selection
  alias Mydia.MediaServer.UserLinks
  alias Mydia.Sync

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Media Servers")
     |> assign(:active_tab, :media_servers)
     |> clear_account_mapping()
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

  ## Account mapping

  @impl true
  def handle_info({:account_mapping_loaded, config_id, result}, socket) do
    # Guarded on the id so a slow answer for a server the operator has already
    # closed cannot repopulate the modal for a different one.
    case socket.assigns[:account_mapping_config] do
      %{id: ^config_id} = config -> {:noreply, apply_accounts_load(socket, config, result)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:account_mapping_saved, config_id, result}, socket) do
    case socket.assigns[:account_mapping_config] do
      %{id: ^config_id} = config -> {:noreply, apply_mapping_save(socket, config, result)}
      _ -> {:noreply, socket}
    end
  end

  ## Media Server Events

  @impl true
  def handle_event("open_account_mapping", %{"id" => id}, socket) do
    config = Settings.get_media_server_config!(id)

    {:noreply,
     socket
     |> assign(:account_mapping_config, config)
     |> assign(:account_mapping_state, :loading)
     |> assign(:account_mapping_accounts, [])
     |> assign(:account_mapping_users, Accounts.list_users())
     |> assign(:account_mapping, %{})
     |> assign(:account_mapping_saving, false)
     |> start_accounts_load(config)}
  end

  @impl true
  def handle_event("close_account_mapping", _params, socket) do
    {:noreply, clear_account_mapping(socket)}
  end

  @impl true
  def handle_event("save_account_mapping", params, socket) do
    config = socket.assigns.account_mapping_config
    mapping = normalize_mapping(params["mapping"] || %{})
    parent = self()

    # Off the LiveView process: applying a Plex mapping is one plex.tv profile
    # switch per newly linked profile, and blocking here would freeze every
    # other event on the page while they run.
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:account_mapping_saved, config.id, UserLinks.apply_mapping(config, mapping)})
    end)

    {:noreply, assign(socket, :account_mapping_saving, true)}
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

    # The PIN modal writes Plex discovery attrs, `type` included, straight onto
    # the row it was opened for. Reached with a Jellyfin server it would rewrite
    # that server as a Plex one and strand its user links on a config whose type
    # no longer matches the accounts they name. The button only renders for
    # Plex, so this refuses a request that could only be forged.
    cond do
      server.type != :plex ->
        {:noreply, put_flash(socket, :error, "Only Plex servers can be reconnected this way.")}

      Settings.runtime_config?(server) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot reconnect a runtime-configured media server. This server is configured via environment variables and is read-only in the UI."
         )}

      true ->
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
        maybe_seed_user_links(server)

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

    # A single forced check feeds both the flash and the badge, so they can
    # never disagree about whether the connection just succeeded or failed.
    # Two independent checks (one for the flash, one to refresh the cache)
    # previously let a flaky server show a success flash next to an
    # Unhealthy badge, or the reverse.
    case MediaServerHealth.check_health(server.id, force: true) do
      {:ok, %{status: :healthy}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection to #{server.name} successful!")
         |> load_data()}

      {:ok, %{error: error}} ->
        MydiaLogger.log_warning(:liveview, "Media server connection test failed",
          operation: :test_media_server,
          server_id: id,
          server_type: server.type,
          error: error,
          user_id: socket.assigns.current_user.id
        )

        {:noreply,
         socket
         |> put_flash(:error, "Connection failed: #{error}")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That media server no longer exists")}
    end
  end

  @impl true
  def handle_event("sync_watched", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    # Server mode rather than a job for the clicking user. A job carrying no
    # link_id used to fall back to the config token, which read the admin's Plex
    # watch state and wrote it onto whoever clicked. The worker refuses that
    # shape now; server mode is what gives every job it fans out a link to name.
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
            maybe_seed_user_links(updated)

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

  # Both providers answer through UserLinks, so the modal never has to know
  # whether it is looking at Plex Home profiles or Jellyfin accounts.
  defp start_accounts_load(socket, config) do
    parent = self()

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:account_mapping_loaded, config.id, UserLinks.list_remote_accounts(config)})
    end)

    socket
  end

  defp apply_accounts_load(socket, config, {:ok, accounts}) do
    links = Settings.list_media_server_user_links(config.id)

    socket
    |> assign(:account_mapping_accounts, accounts)
    |> assign(
      :account_mapping,
      initial_mapping(accounts, links, socket.assigns.account_mapping_users)
    )
    |> assign(:account_mapping_state, :ready)
  end

  defp apply_accounts_load(socket, config, {:error, reason}) do
    assign(socket, :account_mapping_state, {:error, read_accounts_error(config, reason)})
  end

  defp apply_mapping_save(socket, config, {:ok, links}) do
    # A fresh mapping is worth acting on immediately: the operator opened this
    # because sync had been sitting idle, and making them wait for the next
    # half-hourly tick to see whether it worked is the wrong answer.
    if links != [], do: enqueue_server_sync(config)

    socket
    |> clear_account_mapping()
    |> put_flash(:info, link_flash(links, config))
    |> load_data()
  end

  defp apply_mapping_save(socket, config, {:error, :duplicate_user}) do
    mapping_save_error(
      socket,
      "Each Mydia user can be linked to only one #{account_noun(config)}."
    )
  end

  # Two accounts on one Mydia user is caught above; this is the other direction,
  # two Mydia users on one account, which is the merge the whole mapping exists
  # to prevent. Refused rather than written, so nobody ever imports somebody
  # else's watch history.
  defp apply_mapping_save(socket, config, {:error, :duplicate_remote_account}) do
    mapping_save_error(
      socket,
      "Each #{account_noun(config)} can be linked to only one Mydia user."
    )
  end

  defp apply_mapping_save(socket, config, {:error, %Error{} = error}) do
    mapping_save_error(
      socket,
      "Could not save account links for #{config.name}: #{Error.message(error)}. " <>
        "The mapping was left unchanged."
    )
  end

  defp apply_mapping_save(socket, config, {:error, reason}) do
    MydiaLogger.log_warning(:liveview, "Saving media server account links failed",
      operation: :save_account_mapping,
      error: inspect(reason)
    )

    mapping_save_error(socket, "Could not save account links for #{config.name}.")
  end

  defp mapping_save_error(socket, message) do
    socket
    |> assign(:account_mapping_saving, false)
    |> put_flash(:error, message)
  end

  defp link_flash([], config), do: "No accounts are linked to #{config.name}."

  defp link_flash(links, config) do
    "Linked #{length(links)} #{if length(links) == 1, do: "account", else: "accounts"} " <>
      "on #{config.name}. Watched sync queued."
  end

  defp enqueue_server_sync(config) do
    %{"mode" => "server", "config_id" => config.id}
    |> Mydia.Jobs.MediaServerWatchedSync.new()
    |> safe_insert()

    :ok
  end

  # A blank select is "do not sync this account", which has to survive as an
  # explicit nil: it is the difference between unlinking an account and never
  # having been asked about it.
  defp normalize_mapping(mapping) do
    Map.new(mapping, fn
      {account_id, ""} -> {account_id, nil}
      {account_id, user_id} -> {account_id, user_id}
    end)
  end

  # A saved link is the operator's own decision and always wins. A username
  # match is only a suggestion for an account nobody has mapped yet, and it must
  # never propose a user another account already holds: two accounts on one user
  # is refused on save, and offering that as the default would hand the operator
  # a form that cannot be submitted without them working out why.
  defp initial_mapping(accounts, links, users) do
    by_account = Map.new(links, &{&1.remote_user_id, &1.user_id})
    by_username = Map.new(users, &{String.downcase(&1.username), &1.id})

    {mapping, _taken} =
      Enum.reduce(accounts, {%{}, MapSet.new(Map.values(by_account))}, fn account, {acc, taken} ->
        case Map.get(by_account, account.id) do
          nil ->
            choice = suggestion_for(by_username, account, taken)
            {Map.put(acc, account.id, choice), maybe_take(taken, choice)}

          user_id ->
            {Map.put(acc, account.id, user_id), taken}
        end
      end)

    mapping
  end

  defp suggestion_for(by_username, account, taken) do
    case Map.get(by_username, String.downcase(account.name || "")) do
      suggestion when is_binary(suggestion) ->
        if MapSet.member?(taken, suggestion), do: nil, else: suggestion

      _ ->
        nil
    end
  end

  defp maybe_take(taken, nil), do: taken
  defp maybe_take(taken, user_id), do: MapSet.put(taken, user_id)

  defp clear_account_mapping(socket) do
    socket
    |> assign(:account_mapping_config, nil)
    |> assign(:account_mapping_state, :loading)
    |> assign(:account_mapping_accounts, [])
    |> assign(:account_mapping_users, [])
    |> assign(:account_mapping, %{})
    |> assign(:account_mapping_saving, false)
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

  defp read_accounts_error(server, reason) do
    "Could not read accounts from #{server.name}: #{describe_reason(reason)}"
  end

  # What a server calls the things this modal maps. Plex Home calls them
  # profiles and Jellyfin calls them users, and getting it wrong in an error
  # message sends the operator looking for a screen their server does not have.
  defp account_noun(%{type: :plex}), do: "Plex profile"
  defp account_noun(%{type: :jellyfin}), do: "Jellyfin account"
  defp account_noun(_config), do: "account"

  defp describe_reason(%Error{} = error), do: Error.message(error)
  defp describe_reason(%Ecto.Changeset{}), do: "the mapping could not be saved"

  defp describe_reason({:unsupported_provider, type}) do
    "#{type} does not support per-user mapping"
  end

  defp describe_reason(reason) when is_atom(reason) do
    reason |> to_string() |> String.replace("_", " ")
  end

  defp describe_reason(reason), do: inspect(reason)

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

  # Seeds per-user links after a media server config is persisted. Fires on
  # every save of a server that can be seeded, including one that only flips a
  # sync direction. The job is cheap to enqueue, its 120-second uniqueness
  # window collapses bursts, and the alternative is dirty-field tracking that
  # would silently miss a changed token.
  #
  # Firing this often is only safe because seeding runs with `only_new: true`
  # and so adds accounts that have no link yet without touching any link that
  # exists. It used to write over them, which meant a save that changed nothing
  # but a sync direction silently repointed a mapping the operator had made by
  # hand at whichever account shares the Mydia username.
  defp maybe_seed_user_links(%MediaServerConfig{type: type, id: id} = config)
       when is_binary(id) and type in [:plex, :jellyfin] do
    unless mappings_deliberately_cleared?(config) do
      %{"config_id" => id}
      |> Mydia.Jobs.MediaServerLinkSeed.new()
      |> safe_insert()
    end

    :ok
  end

  defp maybe_seed_user_links(_config), do: :ok

  # A server that has been seeded before and now has nothing mapped is an
  # operator who removed the mappings, and the mapping modal told them watched
  # sync would skip those users until they were mapped again. Seeding on the
  # next save would put them all back, and flipping a sync direction is enough
  # to trigger a save. The scheduler makes the same distinction; this is the
  # other producer, and leaving it ungated left the promise broken by a
  # different route. The mapping modal stays the way back, because that is an
  # operator asking for it.
  defp mappings_deliberately_cleared?(config) do
    Mydia.Jobs.MediaServerLinkSeed.seeded_before?(config) and
      Settings.list_media_server_user_links(config.id) == []
  end

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
    media_server_health = MediaServerHealth.status_map(media_servers)

    last_runs =
      Map.new(media_servers, fn server ->
        {server.id, Sync.last_run(to_string(server.type), server.id)}
      end)

    link_counts =
      Map.new(media_servers, fn server ->
        {server.id, length(Settings.list_media_server_user_links(server.id))}
      end)

    socket
    |> assign(:media_servers, media_servers)
    |> assign(:media_server_health, media_server_health)
    |> assign(:last_runs, last_runs)
    |> assign(:link_counts, link_counts)
    |> assign(:show_media_server_modal, false)
    |> assign(:testing_media_server_connection, false)
    |> assign(:plex_oauth_state, :idle)
    |> assign(:plex_oauth_servers, [])
    |> assign(:plex_reachability, :checking)
    |> assign(:plex_manual_entry, false)
    |> assign(:plex_discovery, nil)
    |> assign(:plex_discovery_summary, nil)
  end
end
