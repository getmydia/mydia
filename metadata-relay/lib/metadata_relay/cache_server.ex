defmodule MetadataRelay.CacheServer do
  @moduledoc """
  GenServer-based in-memory cache using ETS.

  Provides intelligent caching with TTL and size limits to reduce
  external API calls and prevent rate limiting.
  """

  use GenServer
  require Logger

  @table_name :metadata_relay_cache
  @cleanup_interval :timer.minutes(5)
  @max_entries 1000

  # TTL values in milliseconds
  @metadata_ttl :timer.hours(24)
  @images_ttl :timer.hours(24 * 7)
  @trending_ttl :timer.hours(1)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          Logger.debug("Cache hit: #{key}")
          {:ok, value}
        else
          # Expired entry
          :ets.delete(@table_name, key)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  def put(key, value, opts \\ []) do
    ttl = determine_ttl(key, opts)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :millisecond)

    # Check size limit and evict if necessary
    if :ets.info(@table_name, :size) >= @max_entries do
      evict_oldest()
    end

    :ets.insert(@table_name, {key, value, expires_at})
    Logger.debug("Cache put: #{key} (TTL: #{ttl}ms)")
    :ok
  end

  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  def stats do
    size = :ets.info(@table_name, :size)
    %{size: size, max_entries: @max_entries}
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp determine_ttl(key, opts) do
    case Keyword.get(opts, :ttl) do
      nil -> auto_ttl(key)
      ttl -> ttl
    end
  end

  defp auto_ttl(key) do
    cond do
      String.contains?(key, "/images") -> @images_ttl
      String.contains?(key, "/trending") -> @trending_ttl
      true -> @metadata_ttl
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()

    expired_count =
      :ets.select_delete(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", {:const, now}}], [true]}
      ])

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired cache entries")
    end
  end

  defp evict_oldest do
    # Simple LRU: delete first entry (oldest based on insertion order)
    case :ets.first(@table_name) do
      :"$end_of_table" -> :ok
      key -> :ets.delete(@table_name, key)
    end
  end
end
