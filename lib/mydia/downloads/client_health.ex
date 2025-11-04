defmodule Mydia.Downloads.ClientHealth do
  @moduledoc """
  Health checking for download clients with caching support.

  This module manages health checks for all configured download clients,
  caching results to avoid excessive API calls. Health checks are performed
  periodically in the background and can be queried on-demand.

  ## Cache Strategy

  - Health check results are cached for 5 minutes (configurable)
  - Background checks run every 2 minutes for all enabled clients
  - Manual checks bypass the cache and force a fresh test

  ## Usage

      # Check health of a specific client (uses cache if fresh)
      {:ok, health} = ClientHealth.check_health("my-qbittorrent")

      # Force a fresh health check (bypasses cache)
      {:ok, health} = ClientHealth.check_health("my-qbittorrent", force: true)

      # Get health status for all clients
      clients = ClientHealth.check_all_clients()
  """

  use GenServer
  require Logger

  alias Mydia.Settings
  alias Mydia.Downloads.Client
  alias Mydia.Health

  @cache_ttl :timer.minutes(5)
  @check_interval :timer.minutes(2)
  @table_name :download_client_health

  ## Client API

  @doc """
  Starts the client health monitoring GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks the health of a specific download client.

  Returns cached results if fresh, otherwise performs a new check.

  ## Options

  - `:force` - If true, bypasses cache and performs a fresh check

  ## Examples

      {:ok, %{status: :healthy, ...}} = check_health("qbittorrent-main")
      {:error, :not_found} = check_health("nonexistent-client")
  """
  @spec check_health(String.t(), keyword()) :: {:ok, Health.health_result()} | {:error, term()}
  def check_health(client_id, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    if force? do
      perform_health_check(client_id)
    else
      case get_cached_health(client_id) do
        {:ok, health} -> {:ok, health}
        :not_found -> perform_health_check(client_id)
      end
    end
  end

  @doc """
  Lists all download client service IDs.

  Required by the Mydia.Health provider interface.
  """
  @spec list_services() :: {:ok, [String.t()]}
  def list_services do
    client_ids =
      Settings.list_download_client_configs()
      |> Enum.map(& &1.id)

    {:ok, client_ids}
  end

  @doc """
  Checks health for all configured download clients.

  Returns a list of `{client_id, health_result}` tuples.
  """
  @spec check_all_clients() :: [{String.t(), Health.health_result()}]
  def check_all_clients do
    Settings.list_download_client_configs()
    |> Enum.map(fn config ->
      case check_health(config.id) do
        {:ok, health} -> {config.id, health}
        {:error, reason} -> {config.id, unhealthy_result(inspect(reason))}
      end
    end)
  end

  @doc """
  Forces a health check for all clients, bypassing cache.
  """
  @spec refresh_all_clients() :: :ok
  def refresh_all_clients do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Register as health check provider
    Health.register_provider(:download_client, __MODULE__)

    # Schedule periodic health checks
    schedule_health_check()

    # Perform initial health check
    perform_all_health_checks()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:perform_health_checks, state) do
    perform_all_health_checks()
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    perform_all_health_checks()
    {:noreply, state}
  end

  ## Private Functions

  defp perform_health_check(client_id) do
    case Settings.get_download_client_config!(client_id) do
      nil ->
        {:error, :not_found}

      config ->
        do_health_check(config)
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  defp do_health_check(config) do
    adapter = get_adapter(config.type)
    client_config = config_to_map(config)

    result =
      case Client.test_connection(adapter, client_config) do
        {:ok, info} ->
          healthy_result(info)

        {:error, error} ->
          error_message =
            case error do
              %{message: msg} -> msg
              _ -> inspect(error)
            end

          unhealthy_result(error_message)
      end

    # Cache the result
    cache_health(config.id, result)

    {:ok, result}
  rescue
    error ->
      Logger.warning(
        "Health check failed for download client #{config.name}: #{Exception.message(error)}"
      )

      result = unhealthy_result("Health check exception: #{Exception.message(error)}")
      cache_health(config.id, result)
      {:ok, result}
  end

  defp perform_all_health_checks do
    Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(fn config ->
      # Perform health check asynchronously
      Task.start(fn ->
        {:ok, _health} = do_health_check(config)
        :ok
      end)
    end)
  end

  defp get_cached_health(client_id) do
    case :ets.lookup(@table_name, client_id) do
      [{^client_id, health, cached_at}] ->
        if fresh?(cached_at) do
          {:ok, health}
        else
          :not_found
        end

      [] ->
        :not_found
    end
  end

  defp cache_health(client_id, health) do
    :ets.insert(@table_name, {client_id, health, System.monotonic_time(:millisecond)})
  end

  defp fresh?(cached_at) do
    now = System.monotonic_time(:millisecond)
    now - cached_at < @cache_ttl
  end

  defp schedule_health_check do
    Process.send_after(self(), :perform_health_checks, @check_interval)
  end

  defp get_adapter(:qbittorrent), do: Mydia.Downloads.Client.Qbittorrent
  defp get_adapter(:transmission), do: Mydia.Downloads.Client.Transmission
  defp get_adapter(:http), do: Mydia.Downloads.Client.Http

  defp config_to_map(config) do
    %{
      type: config.type,
      host: config.host,
      port: config.port,
      use_ssl: config.use_ssl,
      username: config.username,
      password: config.password,
      url_base: config.url_base,
      options: config.connection_settings || %{}
    }
  end

  defp healthy_result(info) do
    %{
      status: :healthy,
      checked_at: DateTime.utc_now(),
      details: info,
      error: nil
    }
  end

  defp unhealthy_result(error_message) do
    %{
      status: :unhealthy,
      checked_at: DateTime.utc_now(),
      details: %{},
      error: error_message
    }
  end
end
