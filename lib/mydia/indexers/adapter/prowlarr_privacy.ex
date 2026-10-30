defmodule Mydia.Indexers.Adapter.ProwlarrPrivacy do
  @moduledoc """
  Caches which of a Prowlarr connection's indexers are private.

  Prowlarr's search results do not say whether the tracker behind a release is
  private; its indexer list does (`privacy`: `public`, `private` or
  `semiPrivate`). `Mydia.Indexers.Adapter.Prowlarr` reads that list at most
  once an hour per connection through `lookup/2`, and a failed read is
  remembered for five minutes so a down Prowlarr is not asked again on every
  search.

  Same shape as `Mydia.Downloads.ClientStatusCache`: the GenServer owns the
  named table and nothing else. Without the table (a unit test that never
  started the application) `lookup/2` calls the fetch function directly.
  """

  use GenServer

  @table_name :prowlarr_indexer_privacy
  @ttl_ms :timer.hours(1)
  @failure_ttl_ms :timer.minutes(5)

  @type privacy_map :: %{integer() => boolean()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The cached privacy map for `key`, or the result of `fetch` when the cached
  one is missing or expired. `fetch` returns `{:ok, map}` or `:error`; an error
  caches and returns an empty map.
  """
  @spec lookup(term(), (-> {:ok, privacy_map()} | :error)) :: privacy_map()
  def lookup(key, fetch) when is_function(fetch, 0) do
    now = System.monotonic_time(:millisecond)

    case cached(key, now) do
      {:ok, map} -> map
      :miss -> refresh(key, fetch, now)
    end
  end

  defp cached(key, now) do
    case :ets.lookup(@table_name, key) do
      [{^key, map, expires_at}] when expires_at > now -> {:ok, map}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp refresh(key, fetch, now) do
    {map, ttl} =
      case fetch.() do
        {:ok, map} -> {map, @ttl_ms}
        :error -> {%{}, @failure_ttl_ms}
      end

    store(key, map, now + ttl)
    map
  end

  defp store(key, map, expires_at) do
    :ets.insert(@table_name, {key, map, expires_at})
  rescue
    ArgumentError -> true
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
