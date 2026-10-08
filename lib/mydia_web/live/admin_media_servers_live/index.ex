defmodule MydiaWeb.AdminMediaServersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Accounts.UsernameIndex
  alias Mydia.Plugins
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.InstanceHealth
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.RuntimeInstances
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig
  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Health, as: MediaServerHealth
  alias Mydia.MediaServer.UserLinks
  alias Mydia.Sync

  alias Mydia.Logger, as: MydiaLogger

  @runtime_mapping_message "Account mapping needs a database-managed server. Servers configured through env or YAML cannot store account links."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Media Servers")
     |> clear_account_mapping()
     |> assign(:plugin_setup, nil)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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

  ## Plugin setup modal

  @impl true
  def handle_info({MydiaWeb.PluginSetupLive.Modal, :closed, %{status: :done}}, socket) do
    {:noreply,
     socket
     |> assign(:plugin_setup, nil)
     |> put_flash(:info, "Server saved")
     |> load_plugin_instances()}
  end

  @impl true
  def handle_info({MydiaWeb.PluginSetupLive.Modal, :closed, %{status: :cancelled}}, socket) do
    {:noreply, assign(socket, :plugin_setup, nil)}
  end

  @impl true
  def handle_info({:plugin_instance_tested, _id}, socket) do
    # Only plugin state: load_data/1 would also close an open Jellyfin modal.
    {:noreply, load_plugin_instances(socket)}
  end

  ## Plugin instances

  @impl true
  def handle_event("add_plugin_server", %{"slug" => slug}, socket) do
    {:noreply, open_setup(socket, slug, nil, "start")}
  end

  @impl true
  def handle_event("plugin_instance_reconnect", %{"id" => id}, socket) do
    with_editable_instance(socket, id, &open_setup(&2, &1.plugin_slug, &1.id, "start"))
  end

  @impl true
  def handle_event("plugin_instance_accounts", %{"id" => id}, socket) do
    with_editable_instance(socket, id, &open_setup(&2, &1.plugin_slug, &1.id, "accounts"))
  end

  @impl true
  def handle_event("plugin_instance_health_action", %{"id" => id}, socket) do
    health = Map.get(socket.assigns.plugin_instance_health, id, %{})

    step =
      case health[:action] do
        :confirm_endpoints -> "confirm-endpoints"
        _ -> "start"
      end

    with_editable_instance(socket, id, &open_setup(&2, &1.plugin_slug, &1.id, step))
  end

  @impl true
  def handle_event("plugin_instance_sync", %{"id" => id}, socket) do
    case Instances.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That server no longer exists")}

      instance ->
        # A schedule run can take up to a minute; never block the page on it.
        Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
          Plugins.invoke_plugin_schedule(instance.plugin_slug, instance.id)
        end)

        {:noreply, put_flash(socket, :info, "Sync started for #{instance.name}")}
    end
  end

  @impl true
  def handle_event("plugin_instance_test", %{"id" => id}, socket) do
    parent = self()

    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      InstanceHealth.check(id, force: true)
      send(parent, {:plugin_instance_tested, id})
    end)

    {:noreply, put_flash(socket, :info, "Checking connection...")}
  end

  @impl true
  def handle_event("plugin_instance_toggle", %{"id" => id}, socket) do
    with_editable_instance(socket, id, fn instance, socket ->
      {:ok, _} = Instances.update(instance, %{enabled: not instance.enabled})
      load_plugin_instances(socket)
    end)
  end

  @impl true
  def handle_event("plugin_instance_delete", %{"id" => id}, socket) do
    with_editable_instance(socket, id, fn instance, socket ->
      :ok = Instances.delete(instance)

      socket
      |> put_flash(:info, "#{instance.name} deleted")
      |> load_plugin_instances()
    end)
  end

  # Removes by value (scheme, host, port), so a stale page or malformed params
  # can never remove the wrong address or crash the view.
  @impl true
  def handle_event(
        "plugin_instance_remove_endpoint",
        %{"id" => id, "scheme" => scheme, "host" => host, "port" => port},
        socket
      ) do
    with_editable_instance(socket, id, fn instance, socket ->
      wanted = {to_string(scheme), to_string(host), to_string(port)}

      case Enum.find(instance.approved_endpoints, &(endpoint_key(&1) == wanted)) do
        nil ->
          socket

        endpoint ->
          {:ok, _} = Instances.remove_endpoint(instance, endpoint)
          load_plugin_instances(socket)
      end
    end)
  end

  ## Media Server Events

  @impl true
  def handle_event("open_account_mapping", %{"id" => id}, socket) do
    config = Settings.get_media_server_config!(id)

    if Settings.runtime_config?(config) do
      {:noreply, put_flash(socket, :error, @runtime_mapping_message)}
    else
      {:noreply,
       socket
       |> assign(:show_account_mapping_modal, true)
       |> assign(:account_mapping_config, config)
       |> assign(:account_mapping_state, :loading)
       |> assign(:account_mapping_accounts, [])
       |> assign(:account_mapping_users, Accounts.list_users())
       |> assign(:account_mapping, %{})
       |> assign(:account_mapping_saving, false)
       |> start_accounts_load(config)}
    end
  end

  @impl true
  def handle_event("close_account_mapping_modal", _params, socket) do
    {:noreply, clear_account_mapping(socket)}
  end

  @impl true
  def handle_event("save_account_mapping", params, socket) do
    config = socket.assigns.account_mapping_config
    mapping = normalize_mapping(params["mapping"] || %{})
    parent = self()

    # Off the LiveView process: applying a mapping talks to the media server,
    # and blocking here would freeze every other event on the page.
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      send(parent, {:account_mapping_saved, config.id, UserLinks.apply_mapping(config, mapping)})
    end)

    {:noreply, assign(socket, :account_mapping_saving, true)}
  end

  @impl true
  def handle_event("new_media_server", _params, socket) do
    changeset = Settings.change_media_server_config(%MediaServerConfig{}, %{type: :jellyfin})

    {:noreply,
     socket
     |> assign(:show_media_server_modal, true)
     |> assign(:media_server_form, to_form(changeset))
     |> assign(:media_server_mode, :new)
     |> assign(:testing_media_server_connection, false)}
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
       |> assign(:testing_media_server_connection, false)}
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
    # link_id used to fall back to the config token, which read the admin's
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

    type = :jellyfin

    test_config = %MediaServerConfig{
      type: :jellyfin,
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

  # Accounts are listed through UserLinks, so the modal never has to know
  # which provider it is looking at.
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

  defp apply_mapping_save(socket, _config, {:error, :runtime_media_server}) do
    mapping_save_error(socket, @runtime_mapping_message)
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
    by_username = UsernameIndex.build(users)

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
    case UsernameIndex.get(by_username, account.name) do
      %User{id: id} -> if MapSet.member?(taken, id), do: nil, else: id
      nil -> nil
    end
  end

  defp maybe_take(taken, nil), do: taken
  defp maybe_take(taken, user_id), do: MapSet.put(taken, user_id)

  defp clear_account_mapping(socket) do
    socket
    |> assign(:show_account_mapping_modal, false)
    |> assign(:account_mapping_config, nil)
    |> assign(:account_mapping_state, :loading)
    |> assign(:account_mapping_accounts, [])
    |> assign(:account_mapping_users, [])
    |> assign(:account_mapping, %{})
    |> assign(:account_mapping_saving, false)
  end

  defp read_accounts_error(server, reason) do
    "Could not read accounts from #{server.name}: #{describe_reason(reason)}"
  end

  # What a server calls the things this modal maps. Getting it wrong in an error
  # message sends the operator looking for a screen their server does not have.
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
       when is_binary(id) and type == :jellyfin do
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

  defp open_setup(socket, slug, instance_id, entry_step) do
    assign(socket, :plugin_setup, %{slug: slug, instance_id: instance_id, entry_step: entry_step})
  end

  # Runtime instances (declared in YAML or env) are DB rows with a runtime_key,
  # and read-only here exactly like runtime Jellyfin configs: the declaration
  # overwrites them on the next boot, so an edit would silently revert.
  defp with_editable_instance(socket, id, fun) do
    case Instances.get(id) do
      %{source: :db} = instance ->
        {:noreply, fun.(instance, socket)}

      %{source: :runtime} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This server is configured via environment variables and is read-only in the UI."
         )}

      nil ->
        {:noreply, put_flash(socket, :error, "That server no longer exists")}
    end
  end

  defp endpoint_key(%{"scheme" => scheme, "host" => host, "port" => port}),
    do: {to_string(scheme), to_string(host), to_string(port)}

  defp endpoint_key(_), do: nil

  defp media_server_plugins do
    Plugins.list_plugins()
    |> Enum.filter(&(&1.category == "media_server"))
    |> Enum.sort_by(& &1.name)
  end

  defp load_plugin_instances(socket) do
    plugins = media_server_plugins()

    # Instances.list/1 returns DB and runtime rows alike (declared instances are
    # persisted at boot), enabled or not.
    pairs =
      for plugin <- plugins, instance <- Instances.list(plugin.slug), do: {plugin, instance}

    instances = Enum.map(pairs, &elem(&1, 1))

    last_runs =
      Map.new(pairs, fn {plugin, instance} ->
        {instance.id, Sync.last_run("plugin:#{plugin.slug}", instance.id)}
      end)

    links =
      Map.new(instances, fn instance ->
        {instance.id, Enum.filter(AccountLinks.list(instance.id), &(&1.role == :user))}
      end)

    socket
    # The Add server menu offers only plugins an operator can add a server for:
    # enabled, with a setup flow. Existing instances of any media server plugin
    # still get a card.
    |> assign(:media_server_plugins, Enum.filter(plugins, &(&1.enabled and &1.setup)))
    |> assign(:plugin_instances, pairs)
    |> assign(:plugin_instance_health, InstanceHealth.status_map(instances))
    |> assign(:plugin_instance_runs, last_runs)
    |> assign(:plugin_instance_links, links)
    |> assign(:plex_deprecations, RuntimeInstances.legacy_declarations())
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
    |> load_plugin_instances()
  end
end
