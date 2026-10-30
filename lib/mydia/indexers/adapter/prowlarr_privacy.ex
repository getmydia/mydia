defmodule Mydia.Indexers.Adapter.ProwlarrPrivacy do
  @moduledoc """
  Caches which of a Prowlarr connection's indexers are private.

  Prowlarr's search results do not say whether the tracker behind a release is
  private; its indexer list does (`privacy`: `public`, `private` or
  `semiPrivate`). `Mydia.Indexers.Adapter.Prowlarr.Terms` reads that list
  through `lookup/3`.

  The lookup runs inside a search task that `Mydia.Indexers.search_all/2`
  kills at its deadline, so it never waits long:

    * A fresh entry (an hour after a successful read, five minutes after a
      failed one) is returned as is.
    * An expired entry is returned as is while one background fetch replaces
      it.
    * With no entry at all, one fetch starts and the caller waits for it at
      most `wait_ms` (3 seconds by default), then carries on with an empty map
      while the fetch finishes and fills the cache for the next search.

  Fetches are single-flight per connection: a caller that finds one already
  running does not start another, so concurrent searches cost one
  indexer-list read.

  Same shape as `Mydia.Downloads.ClientStatusCache`: the GenServer owns the
  named table and nothing else. Without the table (a unit test that never
  started the application) `lookup/3` calls the fetch function directly.
  """

  use GenServer

  @table_name :prowlarr_indexer_privacy
  @ttl_ms :timer.hours(1)
  @failure_ttl_ms :timer.minutes(5)
  @wait_ms 3_000

  @type privacy_map :: %{integer() => boolean()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The privacy map for `key`. `fetch` returns `{:ok, map}` or `:error`; an error
  caches an empty map. See the moduledoc for when the caller waits.
  """
  @spec lookup(term(), (-> {:ok, privacy_map()} | :error), non_neg_integer()) :: privacy_map()
  def lookup(key, fetch, wait_ms \\ @wait_ms) when is_function(fetch, 0) do
    if :ets.whereis(@table_name) == :undefined do
      fetch |> run() |> elem(0)
    else
      cached(key, fetch, wait_ms, System.monotonic_time(:millisecond))
    end
  end

  defp cached(key, fetch, wait_ms, now) do
    case :ets.lookup(@table_name, key) do
      [{^key, map, expires_at}] when expires_at > now ->
        map

      [{^key, map, _expired}] ->
        refresh_in_background(key, fetch)
        map

      [] ->
        await_first(key, fetch, wait_ms)
    end
  end

  defp refresh_in_background(key, fetch) do
    if claim(key), do: Task.Supervisor.start_child(sup(), fn -> fetch_and_store(key, fetch) end)
  end

  # Only the caller that claims the fetch starts it and waits; one that finds a
  # fetch already running carries on with an empty map.
  defp await_first(key, fetch, wait_ms) do
    if claim(key),
      do:
        await(Task.Supervisor.async_nolink(sup(), fn -> fetch_and_store(key, fetch) end), wait_ms),
      else: %{}
  end

  defp await(task, wait_ms) do
    case Task.yield(task, wait_ms) do
      {:ok, map} -> map
      _late_or_failed -> tap(%{}, fn _ -> Task.ignore(task) end)
    end
  end

  # The in-flight marker that makes fetches single-flight per key. The fetch
  # task stores its result and clears the marker, so a caller that stops
  # waiting loses nothing.
  defp claim(key), do: :ets.insert_new(@table_name, {{:in_flight, key}})

  defp sup, do: Mydia.TaskSupervisor

  defp fetch_and_store(key, fetch) do
    {map, ttl} = run(fetch)
    :ets.insert(@table_name, {key, map, System.monotonic_time(:millisecond) + ttl})
    map
  after
    :ets.delete(@table_name, {:in_flight, key})
  end

  defp run(fetch) do
    case fetch.() do
      {:ok, map} -> {map, @ttl_ms}
      :error -> {%{}, @failure_ttl_ms}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
