defmodule Mydia.MediaServer.Health do
  @moduledoc """
  Health checking for media servers with caching support.

  Follows the same shape as `Mydia.Downloads.ClientHealth` and
  `Mydia.Indexers.Health`: a GenServer over an ETS cache, periodic background
  checks, registered with `Mydia.Health`.

  ## Cache Strategy

  - Results are cached for 5 minutes
  - Background checks run every 5 minutes for all enabled servers
  - `force: true` bypasses the cache, which is what "Test connection" uses

  `status_map/1` never performs I/O. It reads the cache so a LiveView mount
  cannot block on an unreachable server, and reports `:unknown` until the
  background check has filled the cache.
  """

  use GenServer
  require Logger

  alias Mydia.Health
  alias Mydia.MediaServer.Client, as: MediaServerClient
  alias Mydia.MediaServer.Error
  alias Mydia.Settings

  @cache_ttl :timer.minutes(5)
  @check_interval :timer.minutes(5)
  @table_name :media_server_health

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks one media server, using the cache unless `force: true`.
  """
  @spec check_health(String.t(), keyword()) :: {:ok, Health.health_result()} | {:error, term()}
  def check_health(config_id, opts \\ []) do
    if Keyword.get(opts, :force, false) do
      perform_health_check(config_id)
    else
      case get_cached_health(config_id) do
        {:ok, health} -> {:ok, health}
        :not_found -> perform_health_check(config_id)
      end
    end
  end

  @doc """
  Required by the `Mydia.Health` provider interface.
  """
  @spec list_services() :: {:ok, [String.t()]}
  def list_services do
    {:ok, Enum.map(Settings.list_media_server_configs(), & &1.id)}
  end

  @doc """
  Maps config id to health result for display, reading cache only.

  A disabled server reports `:disabled` rather than `:unknown`: it is never
  checked, so "Unknown" would be a badge that can never change.
  """
  @spec status_map([struct()]) :: %{String.t() => Health.health_result()}
  def status_map(configs) do
    Map.new(configs, fn config -> {config.id, cached_status(config)} end)
  end

  @doc """
  Forces a check of every enabled server, bypassing cache.
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    Health.register_provider(:media_server, __MODULE__)
    schedule_health_check()
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

  defp cached_status(%{enabled: false}), do: disabled_result()

  defp cached_status(config) do
    case get_cached_health(config.id) do
      {:ok, health} -> health
      :not_found -> unknown_result()
    end
  end

  defp perform_health_check(config_id) do
    config = Settings.get_media_server_config!(config_id)
    do_health_check(config)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp do_health_check(config) do
    adapter = MediaServerClient.adapter_for(config)

    result =
      case adapter.test_connection(config) do
        :ok -> healthy_result(%{})
        {:error, %Error{} = error} -> unhealthy_result(Error.message(error))
        {:error, other} -> unhealthy_result(inspect(other))
      end

    cache_health(config.id, result)
    {:ok, result}
  rescue
    error ->
      Logger.warning(
        "Health check failed for media server #{config.name}: #{Exception.message(error)}"
      )

      result = unhealthy_result("Health check exception: #{Exception.message(error)}")
      cache_health(config.id, result)
      {:ok, result}
  end

  defp perform_all_health_checks do
    Settings.list_media_server_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(fn config ->
      Task.start(fn ->
        do_health_check(config)
        :ok
      end)
    end)
  end

  defp get_cached_health(config_id) do
    case :ets.lookup(@table_name, config_id) do
      [{^config_id, health, cached_at}] ->
        if fresh?(cached_at), do: {:ok, health}, else: :not_found

      [] ->
        :not_found
    end
  rescue
    # The table does not exist in :test, where the GenServer is not started.
    ArgumentError -> :not_found
  end

  defp cache_health(config_id, health) do
    :ets.insert(@table_name, {config_id, health, System.monotonic_time(:millisecond)})
  rescue
    ArgumentError -> :ok
  end

  defp fresh?(cached_at) do
    System.monotonic_time(:millisecond) - cached_at < @cache_ttl
  end

  defp schedule_health_check do
    Process.send_after(self(), :perform_health_checks, @check_interval)
  end

  defp healthy_result(details) do
    %{status: :healthy, checked_at: DateTime.utc_now(), details: details, error: nil}
  end

  defp unhealthy_result(error_message) do
    %{status: :unhealthy, checked_at: DateTime.utc_now(), details: %{}, error: error_message}
  end

  defp unknown_result do
    %{status: :unknown, checked_at: nil, details: %{}, error: nil}
  end

  defp disabled_result do
    %{status: :disabled, checked_at: nil, details: %{}, error: nil}
  end
end
