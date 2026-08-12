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
  alias Mydia.MediaServer.RemoteAccount
  alias Mydia.MediaServer.SeedResult
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

  ## User Mapping Events

  @impl true
  def handle_event("user_link_discover", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    case UserLinks.discover(server) do
      {:ok, %SeedResult{} = result} ->
        {:noreply,
         socket
         |> put_flash(:info, discover_message(result, server))
         |> load_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, read_accounts_error(server, reason))}
    end
  end

  @impl true
  def handle_event("user_link_new", %{"id" => id}, socket) do
    server = Settings.get_media_server_config!(id)

    open_user_link_modal(socket, server, :new, nil)
  end

  @impl true
  def handle_event("user_link_edit", %{"id" => id}, socket) do
    link = Settings.get_media_server_user_link!(id)
    server = Settings.get_media_server_config!(link.media_server_config_id)

    open_user_link_modal(socket, server, :edit, link)
  end

  @impl true
  def handle_event("user_link_save", %{"user_link" => params}, socket) do
    # The editor holds the config and the account list the save is checked
    # against, so a save without one open has nothing to check and is refused.
    case socket.assigns[:user_link_server] do
      nil -> {:noreply, socket}
      server -> save_user_link(socket, server, params)
    end
  end

  @impl true
  def handle_event("user_link_toggle", %{"id" => id}, socket) do
    link = Settings.get_media_server_user_link!(id)

    case Settings.update_media_server_user_link(link, %{enabled: not link.enabled}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, toggle_link_message(updated))
         |> load_data()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not change that mapping")}
    end
  end

  @impl true
  def handle_event("user_link_delete", %{"id" => id}, socket) do
    link = Settings.get_media_server_user_link!(id)
    {:ok, _link} = Settings.delete_media_server_user_link(link)

    {:noreply,
     socket
     |> put_flash(:info, "User mapping removed")
     |> load_data()}
  end

  @impl true
  def handle_event("close_user_link_modal", _params, socket) do
    {:noreply, assign(socket, :show_user_link_modal, false)}
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

  defp toggle_link_message(%{enabled: true}) do
    "Mapping resumed. Watched sync will include this user again."
  end

  defp toggle_link_message(%{enabled: false}) do
    "Mapping paused. Watched sync will skip this user until it is resumed."
  end

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

  # Picking an account by hand still needs the server's own list. What a link
  # stores is a Jellyfin GUID or a Plex account id, neither of which an operator
  # can reasonably type, and on Plex the per-user token has to be minted live
  # anyway. So an unreachable server means no editor, with the reason in a flash.
  defp open_user_link_modal(socket, server, mode, link) do
    case UserLinks.list_remote_accounts(server) do
      {:ok, []} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{server.name} reported no user accounts, so there is nothing to map yet"
         )}

      {:ok, accounts} ->
        {:noreply,
         socket
         |> assign(:show_user_link_modal, true)
         |> assign(:user_link_mode, mode)
         |> assign(:user_link_server, server)
         |> assign(:user_link_accounts, accounts)
         |> assign(:editing_user_link, link)
         |> assign(:user_link_form, user_link_form(socket, link))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, read_accounts_error(server, reason))}
    end
  end

  # Exactly three values reach the write: this config, a Mydia user from the list
  # this page loaded, and an account the server itself just reported. The
  # submitted params are never cast into the link, so a crafted or incomplete
  # form cannot set or clear the link's access_token, and cannot name an account
  # the server does not have.
  defp save_user_link(socket, server, params) do
    # `:replaces` is what makes editing a row and choosing a different Mydia user
    # a move instead of a second claim on the same account.
    opts = [replaces: socket.assigns[:editing_user_link]]

    with {:ok, user} <- fetch_mydia_user(socket, params["user_id"]),
         {:ok, account} <- fetch_remote_account(socket, params["remote_user_id"]),
         {:ok, _link} <- UserLinks.link_user(server, user.id, account, opts) do
      {:noreply,
       socket
       |> assign(:show_user_link_modal, false)
       |> put_flash(
         :info,
         "Mapped #{user.username} to #{RemoteAccount.label(account)} on #{server.name}"
       )
       |> load_data()}
    else
      {:error, reason} ->
        # Keep what was chosen. Rebuilding the form from its defaults would make
        # the operator redo both selections to correct one of them.
        {:noreply,
         socket
         |> assign(:user_link_form, submitted_user_link_form(params))
         |> put_flash(:error, save_link_error(server, reason))}
    end
  end

  defp submitted_user_link_form(params) do
    to_form(
      %{
        "user_id" => params["user_id"] || "",
        "remote_user_id" => params["remote_user_id"] || ""
      },
      as: :user_link
    )
  end

  defp user_link_form(socket, nil) do
    default_user = List.first(socket.assigns.mydia_users)

    to_form(
      %{"user_id" => (default_user && default_user.id) || "", "remote_user_id" => ""},
      as: :user_link
    )
  end

  defp user_link_form(_socket, link) do
    to_form(
      %{"user_id" => link.user_id, "remote_user_id" => link.remote_user_id || ""},
      as: :user_link
    )
  end

  defp fetch_mydia_user(socket, user_id) do
    case Enum.find(socket.assigns.mydia_users, &(&1.id == user_id)) do
      nil -> {:error, :unknown_user}
      user -> {:ok, user}
    end
  end

  # The picker's own list is the whitelist: a mapping can only name an account
  # the server reported when the editor opened.
  defp fetch_remote_account(socket, remote_user_id) do
    case Enum.find(socket.assigns.user_link_accounts, &(&1.id == remote_user_id)) do
      nil -> {:error, :unknown_remote_account}
      account -> {:ok, account}
    end
  end

  # The owner fallback matched no name at all: it binds an admin to the config's
  # own token because the account reported no Plex Home profiles. Counting it as
  # a match told the operator a profile was found when none was.
  defp discover_message(%SeedResult{owner_fallback: :linked}, server) do
    "#{server.name} reported no Plex Home profiles, so the admin account was mapped to it " <>
      "directly."
  end

  defp discover_message(%SeedResult{owner_fallback: :ambiguous}, server) do
    "#{server.name} reported no Plex Home profiles, and this install has more than one admin, " <>
      "so nothing was mapped. Use Add mapping to pair the right Mydia user with the account."
  end

  defp discover_message(%SeedResult{linked: [], already_mapped: []}, server) do
    "No usernames matched on #{server.name}. Use Add mapping to pair accounts by hand."
  end

  defp discover_message(%SeedResult{} = result, server) do
    [matched_sentence(result.linked, server), kept_sentence(result.already_mapped)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp matched_sentence([], _server), do: nil
  defp matched_sentence([_link], server), do: "Matched 1 account on #{server.name}."

  defp matched_sentence(links, server) do
    "Matched #{length(links)} accounts on #{server.name}."
  end

  # Discovery leaving an account alone looks like discovery ignoring it, so the
  # operator is told their own mapping is what held it.
  defp kept_sentence([]), do: nil
  defp kept_sentence([_name]), do: "Left 1 existing mapping alone."
  defp kept_sentence(names), do: "Left #{length(names)} existing mappings alone."

  defp read_accounts_error(server, reason) do
    "Could not read accounts from #{server.name}: #{describe_reason(reason)}"
  end

  defp save_link_error(_server, :unknown_user) do
    "That Mydia user no longer exists. Reload the page and try again."
  end

  defp save_link_error(server, :unknown_remote_account) do
    "#{server.name} no longer lists that account. Discover accounts again and retry."
  end

  defp save_link_error(server, :account_already_mapped) do
    "That #{server.name} account is already mapped to another Mydia user. " <>
      "Remove that mapping first."
  end

  defp save_link_error(server, :user_already_mapped) do
    "That Mydia user already has a mapping on #{server.name}. Saving this one would " <>
      "replace it and remove the mapping you are editing. Remove the other mapping first."
  end

  # Only Plex reaches here with a media server error, from minting the per-user
  # token. Saying the mapping is unchanged matters: the alternative would have
  # been a link naming an account it holds no credential for.
  defp save_link_error(server, %Error{} = error) do
    "Could not get a #{server.name} token for that account: #{Error.message(error)}. " <>
      "The mapping was left unchanged."
  end

  defp save_link_error(_server, reason) do
    "Could not save the user mapping: #{describe_reason(reason)}"
  end

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

  # Seeds per-user Plex links after any Plex config is persisted. Fires on every
  # Plex save, including one that only flips a sync direction. The job is cheap
  # to enqueue, its 120-second uniqueness window collapses bursts, and the
  # alternative is dirty-field tracking that would silently miss a changed token.
  #
  # Firing this often is only safe because seeding runs with `only_new: true`
  # and so adds Plex Home profiles that have no link yet without touching any
  # link that exists. It used to write over them, which meant a save that
  # changed nothing but a sync direction silently repointed a mapping the
  # operator had made by hand at whichever profile shares the Mydia username.
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
    media_server_health = MediaServerHealth.status_map(media_servers)

    last_runs =
      Map.new(media_servers, fn server ->
        {server.id, Sync.last_run(to_string(server.type), server.id)}
      end)

    user_links =
      Map.new(media_servers, fn server ->
        {server.id, Settings.list_media_server_user_links(server.id)}
      end)

    socket
    |> assign(:media_servers, media_servers)
    |> assign(:media_server_health, media_server_health)
    |> assign(:last_runs, last_runs)
    |> assign(:user_links, user_links)
    |> assign(:mydia_users, Enum.sort_by(Accounts.list_users(), & &1.username))
    |> assign(:show_media_server_modal, false)
    |> assign(:show_user_link_modal, false)
    |> assign(:editing_user_link, nil)
    |> assign(:testing_media_server_connection, false)
    |> assign(:plex_oauth_state, :idle)
    |> assign(:plex_oauth_servers, [])
    |> assign(:plex_reachability, :checking)
    |> assign(:plex_manual_entry, false)
    |> assign(:plex_discovery, nil)
    |> assign(:plex_discovery_summary, nil)
  end
end
