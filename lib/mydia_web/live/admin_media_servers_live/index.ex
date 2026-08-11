defmodule MydiaWeb.AdminMediaServersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig
  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.Sync

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Media Servers")
     |> assign(:active_tab, :media_servers)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Plex connection test result handler

  @impl true
  def handle_info({:plex_connection_tested, uri, result}, socket) do
    if socket.assigns[:plex_oauth_state] == :selecting_connection do
      statuses = socket.assigns[:plex_connection_statuses] || %{}
      updated_statuses = Map.put(statuses, uri, result)
      {:noreply, assign(socket, :plex_connection_statuses, updated_statuses)}
    else
      {:noreply, socket}
    end
  end

  ## Media Server Events

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
     |> assign(:plex_manual_entry, false)}
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
       |> assign(:plex_manual_entry, true)}
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
       |> assign(:plex_manual_entry, false)}
    end
  end

  @impl true
  def handle_event("validate_media_server", %{"media_server_config" => params}, socket) do
    server =
      case socket.assigns.media_server_mode do
        :new -> %MediaServerConfig{}
        :edit -> socket.assigns.editing_media_server
      end

    changeset =
      server
      |> Settings.change_media_server_config(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :media_server_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_media_server", %{"media_server_config" => params}, socket) do
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
      {:ok, _server} ->
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
        case PlexOAuth.list_servers(token) do
          {:ok, servers} ->
            {:noreply,
             socket
             |> assign(:plex_oauth_state, :selecting_server)
             |> assign(:plex_oauth_token, token)
             |> assign(:plex_oauth_servers, servers)
             |> push_event("plex_auth_complete", %{})}

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
    servers = socket.assigns.plex_oauth_servers
    token = socket.assigns.plex_oauth_token

    case Enum.find(servers, &(&1.client_identifier == server_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Server not found")}

      server ->
        if server.connections == [] do
          {:noreply, put_flash(socket, :error, "No available connections for this server")}
        else
          initial_statuses =
            Map.new(server.connections, fn conn -> {conn.uri, :testing} end)

          parent = self()

          for conn <- server.connections do
            Task.start(fn ->
              result = test_plex_connection(conn, token)
              send(parent, {:plex_connection_tested, conn.uri, result})
            end)
          end

          {:noreply,
           socket
           |> assign(:plex_oauth_state, :selecting_connection)
           |> assign(:plex_selected_server, server)
           |> assign(:plex_connection_statuses, initial_statuses)}
        end
    end
  end

  @impl true
  def handle_event("select_plex_connection", %{"url" => _url}, socket) do
    server = socket.assigns.plex_selected_server
    token = socket.assigns.plex_oauth_token

    server_base =
      case socket.assigns.media_server_mode do
        :new -> %MediaServerConfig{}
        :edit -> socket.assigns.editing_media_server
      end

    # url stays nil so it remains a pure manual override; discovery owns the
    # candidate list and Endpoint.resolve/1 picks a working address at call time.
    attrs = %{
      name: server.name,
      type: :plex,
      url: nil,
      token: token,
      machine_identifier: server.machine_identifier,
      connections: server.connections,
      server_access_token: server.access_token,
      enabled: true
    }

    case socket.assigns.media_server_mode do
      :edit ->
        # Reconnect (and edit-time re-auth) must update the existing row in
        # place so user links and sync state are not orphaned.
        attrs = Map.merge(attrs, %{last_auth_error: nil, last_auth_error_at: nil})

        case Settings.update_media_server_config(server_base, attrs) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Plex reconnected successfully")
             |> load_data()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:plex_oauth_state, :error)
             |> assign(:media_server_form, to_form(changeset))
             |> put_flash(:error, "Failed to update media server")}
        end

      :new ->
        changeset = Settings.change_media_server_config(server_base, attrs)

        {:noreply,
         socket
         |> assign(:plex_oauth_state, :complete)
         |> assign(:media_server_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("cancel_plex_oauth", _params, socket) do
    if socket.assigns.plex_oauth_state == :selecting_connection do
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :selecting_server)
       |> assign(:plex_selected_server, nil)}
    else
      {:noreply,
       socket
       |> assign(:plex_oauth_state, :idle)
       |> assign(:plex_oauth_pin_id, nil)
       |> assign(:plex_oauth_servers, [])
       |> assign(:plex_oauth_token, nil)
       |> assign(:plex_selected_server, nil)
       |> push_event("plex_auth_cancelled", %{})}
    end
  end

  @impl true
  def handle_event("toggle_plex_manual_entry", _params, socket) do
    {:noreply,
     socket
     |> assign(:plex_manual_entry, !socket.assigns.plex_manual_entry)
     |> assign(:plex_oauth_state, :idle)
     |> assign(:plex_oauth_pin_id, nil)
     |> assign(:plex_oauth_servers, [])
     |> assign(:plex_oauth_token, nil)}
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
    user_id = socket.assigns.current_user.id

    changeset =
      Mydia.Jobs.MediaServerWatchedSync.new(%{
        "config_id" => server.id,
        "user_id" => user_id
      })

    case Oban.insert(changeset) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Watched sync started for #{server.name}")
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

    test_config = %MediaServerConfig{
      type: type,
      url: params.url,
      token: params.token,
      name: params.name || "Test"
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
    |> assign(:plex_manual_entry, false)
  end

  defp get_media_server_health_status(media_servers) do
    media_servers
    |> Enum.map(fn server -> {server.id, %{status: :unknown}} end)
    |> Map.new()
  end

  defp test_plex_connection(conn, token) do
    protocol = conn.protocol || "https"
    address = conn.address
    port = conn.port

    test_url = "#{protocol}://#{address}:#{port}/identity"

    headers = [
      {"X-Plex-Token", token},
      {"Accept", "application/json"}
    ]

    Logger.info("Testing Plex connection: #{test_url}")

    opts = [
      headers: headers,
      receive_timeout: 5_000,
      pool_timeout: 5_000,
      retry: false,
      connect_options: [
        timeout: 3_000,
        transport_opts: [verify: :verify_none]
      ]
    ]

    case Req.get(test_url, opts) do
      {:ok, %{status: 200}} ->
        Logger.info("Plex connection OK: #{conn.uri}")
        :ok

      {:ok, %{status: status}} ->
        Logger.info("Plex connection failed HTTP #{status}: #{conn.uri}")
        :error

      {:error, error} ->
        Logger.info("Plex connection error: #{conn.uri} - #{inspect(error)}")
        :error
    end
  rescue
    e ->
      Logger.info("Plex connection exception: #{conn.uri} - #{inspect(e)}")
      :error
  end
end
