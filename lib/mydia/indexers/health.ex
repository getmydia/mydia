defmodule Mydia.Indexers.Health do
  @moduledoc """
  Health checking for indexers with caching support.

  This module manages health checks for all configured indexers,
  caching results to avoid excessive API calls. Health checks verify
  connectivity and retrieve indexer capabilities.

  ## Cache Strategy

  - Health check results are cached for 5 minutes (configurable)
  - Background checks run every 3 minutes for all enabled indexers
  - Manual checks bypass the cache and force a fresh test

  ## Failure Tracking

  - Tracks consecutive failures per indexer
  - Can automatically disable indexers after N consecutive failures
  - Emits warnings and errors via Logger for monitoring

  ## Usage

      # Check health of a specific indexer (uses cache if fresh)
      {:ok, health} = Health.check_health("prowlarr-main")

      # Force a fresh health check (bypasses cache)
      {:ok, health} = Health.check_health("prowlarr-main", force: true)

      # Get health status for all indexers
      indexers = Health.check_all_indexers()
  """

  use GenServer
  require Logger

  alias Mydia.Settings
  alias Mydia.Indexers
  alias Mydia.Health

  @cache_ttl :timer.minutes(5)
  @check_interval :timer.minutes(3)
  @table_name :indexer_health
  @failure_table :indexer_failures
  @max_failures_before_disable 5

  ## Client API

  @doc """
  Starts the indexer health monitoring GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks the health of a specific indexer.

  Returns cached results if fresh, otherwise performs a new check.

  ## Options

  - `:force` - If true, bypasses cache and performs a fresh check

  ## Examples

      {:ok, %{status: :healthy, ...}} = check_health("prowlarr-main")
      {:error, :not_found} = check_health("nonexistent-indexer")
  """
  @spec check_health(String.t(), keyword()) :: {:ok, Health.health_result()} | {:error, term()}
  def check_health(indexer_id, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    if force? do
      perform_health_check(indexer_id)
    else
      case get_cached_health(indexer_id) do
        {:ok, health} -> {:ok, health}
        :not_found -> perform_health_check(indexer_id)
      end
    end
  end

  @doc """
  Lists all indexer service IDs.

  Required by the Mydia.Health provider interface.
  """
  @spec list_services() :: {:ok, [String.t()]}
  def list_services do
    indexer_ids =
      Settings.list_indexer_configs()
      |> Enum.map(& &1.id)

    {:ok, indexer_ids}
  end

  @doc """
  Checks health for all configured indexers.

  Returns a list of `{indexer_id, health_result}` tuples.
  """
  @spec check_all_indexers() :: [{String.t(), Health.health_result()}]
  def check_all_indexers do
    Settings.list_indexer_configs()
    |> Enum.map(fn config ->
      case check_health(config.id) do
        {:ok, health} -> {config.id, health}
        {:error, reason} -> {config.id, unhealthy_result(inspect(reason))}
      end
    end)
  end

  @doc """
  Forces a health check for all indexers, bypassing cache.
  """
  @spec refresh_all_indexers() :: :ok
  def refresh_all_indexers do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  @doc """
  Gets the failure count for a specific indexer.

  Returns the number of consecutive failures for the indexer.
  """
  @spec get_failure_count(String.t()) :: non_neg_integer()
  def get_failure_count(indexer_id) do
    case :ets.lookup(@failure_table, indexer_id) do
      [{^indexer_id, count, _last_failure}] -> count
      [] -> 0
    end
  end

  @doc """
  Resets the failure count for a specific indexer.

  Called when an indexer recovers or is manually reset.
  """
  @spec reset_failures(String.t()) :: :ok
  def reset_failures(indexer_id) do
    GenServer.call(__MODULE__, {:reset_failures, indexer_id})
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS tables for caching and failure tracking
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@failure_table, [:named_table, :set, :public, read_concurrency: true])

    # Register as health check provider
    Health.register_provider(:indexer, __MODULE__)

    # Schedule periodic health checks
    schedule_health_check()

    # Perform initial health check
    perform_all_health_checks()

    Logger.info("Indexer health monitoring started")
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

  @impl true
  def handle_call({:reset_failures, indexer_id}, _from, state) do
    :ets.delete(@failure_table, indexer_id)
    Logger.info("Reset failure count for indexer: #{indexer_id}")
    {:reply, :ok, state}
  end

  ## Private Functions

  defp perform_health_check(indexer_id) do
    case Settings.get_indexer_config!(indexer_id) do
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
    result =
      case Indexers.test_connection(config) do
        {:ok, info} ->
          # Also fetch capabilities if available
          capabilities =
            case Indexers.get_capabilities(config) do
              {:ok, caps} -> caps
              {:error, _} -> %{}
            end

          # Success - reset failure counter
          :ets.delete(@failure_table, config.id)

          healthy_result(Map.merge(info, %{capabilities: capabilities}))

        {:error, error} ->
          error_message =
            case error do
              %{message: msg} -> msg
              _ -> inspect(error)
            end

          # Track failure
          track_failure(config)

          unhealthy_result(error_message)
      end

    # Cache the result
    cache_health(config.id, result)

    {:ok, result}
  rescue
    error ->
      Logger.warning(
        "Health check failed for indexer #{config.name}: #{Exception.message(error)}"
      )

      # Track failure
      track_failure(config)

      result = unhealthy_result("Health check exception: #{Exception.message(error)}")
      cache_health(config.id, result)
      {:ok, result}
  end

  defp perform_all_health_checks do
    Settings.list_indexer_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(fn config ->
      # Perform health check asynchronously
      Task.start(fn ->
        {:ok, _health} = do_health_check(config)
        :ok
      end)
    end)
  end

  defp track_failure(config) do
    current_count = get_failure_count(config.id)
    new_count = current_count + 1
    now = DateTime.utc_now()

    :ets.insert(@failure_table, {config.id, new_count, now})

    Logger.warning(
      "Indexer #{config.name} health check failed (#{new_count} consecutive failures)"
    )

    # Check if we should disable the indexer
    if new_count >= @max_failures_before_disable do
      Logger.error(
        "Indexer #{config.name} has failed #{new_count} consecutive health checks. " <>
          "Consider disabling it in settings."
      )

      maybe_auto_disable_indexer(config, new_count)
    end
  end

  defp maybe_auto_disable_indexer(config, failure_count) do
    # Only auto-disable if the feature is enabled
    # For now, we just log a critical error and let admins decide
    # In the future, this could automatically disable and send alerts

    Logger.error("""
    INDEXER HEALTH ALERT: #{config.name} (ID: #{config.id})
    - Status: Unhealthy
    - Consecutive Failures: #{failure_count}
    - Type: #{config.type}
    - URL: #{config.base_url}
    - Action Required: Manual intervention recommended
    """)

    # TODO: Implement auto-disable feature with user preference
    # Settings.update_indexer_config(config, %{enabled: false})
  end

  defp get_cached_health(indexer_id) do
    case :ets.lookup(@table_name, indexer_id) do
      [{^indexer_id, health, cached_at}] ->
        if fresh?(cached_at) do
          {:ok, health}
        else
          :not_found
        end

      [] ->
        :not_found
    end
  end

  defp cache_health(indexer_id, health) do
    :ets.insert(@table_name, {indexer_id, health, System.monotonic_time(:millisecond)})
  end

  defp fresh?(cached_at) do
    now = System.monotonic_time(:millisecond)
    now - cached_at < @cache_ttl
  end

  defp schedule_health_check do
    Process.send_after(self(), :perform_health_checks, @check_interval)
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
