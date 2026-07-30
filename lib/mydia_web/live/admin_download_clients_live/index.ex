defmodule MydiaWeb.AdminDownloadClientsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Downloads
  alias Mydia.Settings
  alias Mydia.Settings.DownloadClientConfig
  alias Mydia.Downloads.ClientHealth

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Download Clients")
     |> assign(:active_tab, :clients)
     |> assign(:pending_delete_client, nil)
     |> assign(:pending_delete_count, 0)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Download Client Events

  @impl true
  def handle_event("new_download_client", _params, socket) do
    changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, %{})

    {:noreply,
     socket
     |> assign(:show_download_client_modal, true)
     |> assign(:download_client_form, to_form(changeset))
     |> assign(:download_client_mode, :new)
     |> assign(:editing_download_client, nil)
     |> assign(:testing_download_client_connection, false)}
  end

  @impl true
  def handle_event("edit_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    if Settings.runtime_config?(client) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot edit runtime-configured download client. This client is configured via environment variables and is read-only in the UI."
       )}
    else
      changeset = DownloadClientConfig.changeset(client, %{})

      {:noreply,
       socket
       |> assign(:show_download_client_modal, true)
       |> assign(:download_client_form, to_form(changeset))
       |> assign(:download_client_mode, :edit)
       |> assign(:editing_download_client, client)
       |> assign(:testing_download_client_connection, false)}
    end
  end

  @impl true
  def handle_event("validate_download_client", %{"download_client_config" => params}, socket) do
    client =
      case socket.assigns.download_client_mode do
        :new -> %DownloadClientConfig{}
        :edit -> socket.assigns.editing_download_client
      end

    changeset =
      client
      |> DownloadClientConfig.changeset(normalize_client_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :download_client_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_download_client", %{"download_client_config" => params}, socket) do
    normalized = normalize_client_params(params)

    result =
      case socket.assigns.download_client_mode do
        :new ->
          Settings.create_download_client_config(normalized)

        :edit ->
          Settings.update_download_client_config(
            socket.assigns.editing_download_client,
            normalized
          )
      end

    case result do
      {:ok, _client} ->
        {:noreply,
         socket
         |> assign(:show_download_client_modal, false)
         |> put_flash(:info, "Download client saved successfully")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :download_client_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("confirm_delete_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    if Settings.runtime_config?(client) do
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Cannot delete runtime-configured download client. This client is configured via environment variables and is read-only in the UI."
       )}
    else
      # Counted before deletion, while the client still exists, so the operator
      # sees the real blast radius rather than a bare "are you sure".
      count = Downloads.count_downloads_for_client(client.name)

      {:noreply,
       socket
       |> assign(:pending_delete_client, client)
       |> assign(:pending_delete_count, count)}
    end
  end

  @impl true
  def handle_event("cancel_delete_download_client", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_delete_client, nil)
     |> assign(:pending_delete_count, 0)}
  end

  @impl true
  def handle_event("delete_download_client", _params, socket) do
    client = socket.assigns.pending_delete_client

    case Settings.delete_download_client_config(client) do
      {:ok, _client} ->
        {:noreply,
         socket
         |> assign(:pending_delete_client, nil)
         |> assign(:pending_delete_count, 0)
         |> put_flash(:info, "Download client deleted successfully")
         |> load_data()}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Failed to delete download client",
          error: error,
          operation: :delete_download_client,
          client_id: client.id,
          client_name: client.name,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:delete_download_client, error)

        {:noreply,
         socket
         |> assign(:pending_delete_client, nil)
         |> assign(:pending_delete_count, 0)
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("close_download_client_modal", _params, socket) do
    {:noreply, assign(socket, :show_download_client_modal, false)}
  end

  @impl true
  def handle_event("test_download_client", %{"id" => id}, socket) do
    client = Settings.get_download_client_config!(id)

    client_config =
      cond do
        client.type == :blackhole ->
          %{
            type: :blackhole,
            connection_settings: client.connection_settings || %{}
          }

        client.type == :debrid ->
          %{
            type: :debrid,
            api_key: client.api_key,
            download_directory: client.download_directory,
            connection_settings: client.connection_settings || %{}
          }

        true ->
          %{
            type: client.type,
            host: client.host,
            port: client.port,
            use_ssl: client.use_ssl,
            username: client.username,
            password: client.password,
            api_key: client.api_key,
            url_base: client.url_base,
            options: client.connection_settings || %{}
          }
      end

    case test_client_connection(client_config) do
      {:ok, info} ->
        version_info =
          cond do
            Map.has_key?(info, :version) -> "Version: #{info.version}"
            Map.has_key?(info, :rpc_version) -> "RPC Version: #{info.rpc_version}"
            true -> "Connected"
          end

        {:noreply, put_flash(socket, :info, "Connection successful! #{version_info}")}

      {:error, error} ->
        MydiaLogger.log_error(:liveview, "Download client connection test failed",
          error: error,
          operation: :test_download_client,
          client_id: id,
          client_type: client.type,
          client_host: client.host,
          user_id: socket.assigns.current_user.id
        )

        error_msg =
          case error do
            %{message: msg} -> msg
            _ -> MydiaLogger.extract_error_message(error)
          end

        {:noreply, put_flash(socket, :error, "Connection failed: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("test_download_client_connection", _params, socket) do
    changeset = socket.assigns.download_client_form.source
    params = Ecto.Changeset.apply_changes(changeset)

    type =
      case params.type do
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
      end

    test_config =
      cond do
        type == :blackhole ->
          %{
            type: :blackhole,
            connection_settings: params.connection_settings || %{}
          }

        type == :debrid ->
          # The UI renders the Provider sub-selector with "real_debrid" as
          # the visible default via the `<.input value={...}>` attribute, but
          # that visible default doesn't enter the changeset until the user
          # interacts with the field — phx-change fires on user input only.
          # Mirror the visible default here so "Test Connection" works on a
          # fresh form where the operator only filled in the API key.
          provider =
            params.connection_settings
            |> Kernel.||(%{})
            |> Map.get("provider", "real_debrid")

          %{
            type: :debrid,
            api_key: params.api_key,
            download_directory: params.download_directory,
            connection_settings: Map.put(params.connection_settings || %{}, "provider", provider)
          }

        true ->
          %{
            type: type,
            host: params.host,
            port: params.port,
            use_ssl: params.use_ssl || false,
            username: params.username,
            password: params.password,
            api_key: params.api_key,
            url_base: params.url_base,
            options: params.connection_settings || %{}
          }
      end

    case test_client_connection(test_config) do
      {:ok, info} ->
        version_info =
          cond do
            Map.has_key?(info, :version) -> "Version: #{info.version}"
            Map.has_key?(info, :rpc_version) -> "RPC Version: #{info.rpc_version}"
            true -> "Connected"
          end

        {:noreply,
         socket
         |> assign(:testing_download_client_connection, false)
         |> put_flash(:info, "Connection successful! #{version_info}")}

      {:error, error} ->
        MydiaLogger.log_warning(:liveview, "Download client connection test failed",
          operation: :test_download_client_connection,
          error: error,
          client_type: type,
          user_id: socket.assigns.current_user.id
        )

        error_msg =
          case error do
            %{message: msg} -> msg
            _ -> MydiaLogger.extract_error_message(error)
          end

        {:noreply,
         socket
         |> assign(:testing_download_client_connection, false)
         |> put_flash(:error, "Connection failed: #{error_msg}")}
    end
  end

  ## Private Helpers

  defp load_data(socket) do
    download_clients = Settings.list_download_client_configs()
    client_health = get_client_health_status(download_clients)

    socket
    |> assign(:download_clients, download_clients)
    |> assign(:client_health, client_health)
    |> assign(:show_download_client_modal, false)
    |> assign(:testing_download_client_connection, false)
  end

  defp get_client_health_status(clients) do
    clients
    |> Task.async_stream(
      fn client ->
        case ClientHealth.check_health(client.id) do
          {:ok, health} -> {client.id, health}
          {:error, _} -> {client.id, %{status: :unknown, error: "Unable to check health"}}
        end
      end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  defp test_client_connection(client_config) do
    alias Mydia.Downloads.Client.Registry

    with {:ok, adapter} <- Registry.get_adapter(client_config.type),
         {:ok, result} <- adapter.test_connection(client_config) do
      {:ok, result}
    else
      {:error, _} = error -> error
    end
  end

  # Drops empty-string values from the nested `categories` and
  # `priority_profile` maps before passing through to the changeset.
  # Browsers submit every text input even when blank, so without this
  # the database would accumulate `%{"movie" => "", "tv" => ""}` entries
  # that defeat the "fall back to legacy category" precedence rule in
  # `Mydia.Downloads.Queue.resolve_category/3`.
  defp normalize_client_params(params) when is_map(params) do
    params
    |> normalize_map_field("categories")
    |> normalize_map_field("priority_profile")
  end

  defp normalize_map_field(params, key) do
    case Map.get(params, key) do
      map when is_map(map) ->
        cleaned =
          for {k, v} <- map,
              is_binary(v) and String.trim(v) != "",
              into: %{},
              do: {k, String.trim(v)}

        Map.put(params, key, cleaned)

      _ ->
        params
    end
  end
end
