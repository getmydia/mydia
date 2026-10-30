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
  running does not start another (unless that fetch has held the key for 30
  seconds, see `claim/1`), so concurrent searches cost one indexer-list read.

  Same shape as `Mydia.Downloads.ClientStatusCache`: the GenServer owns the
  named table and nothing else. Without the table (a unit test that never
  started the application) `lookup/3` calls the fetch function directly.
  """

  use GenServer

  @table_name :prowlarr_indexer_privacy
  @ttl_ms :timer.hours(1)
  @failure_ttl_ms :timer.minutes(5)
  @wait_ms 3_000
  @claim_ttl_ms 30_000

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
    if stamp = claim(key),
      do: Task.Supervisor.start_child(sup(), fn -> fetch_and_store(key, fetch, stamp) end)
  end

  # Only the caller that claims the fetch starts it and waits; one that finds a
  # fetch already running carries on with an empty map.
  defp await_first(key, fetch, wait_ms) do
    case claim(key) do
      nil ->
        %{}

      stamp ->
        await(
          Task.Supervisor.async_nolink(sup(), fn -> fetch_and_store(key, fetch, stamp) end),
          wait_ms
        )
    end
  end

  defp await(task, wait_ms) do
    case Task.yield(task, wait_ms) do
      {:ok, map} -> map
      _late_or_failed -> tap(%{}, fn _ -> Task.ignore(task) end)
    end
  end

  # The in-flight marker that makes fetches single-flight per key. It holds a
  # stamp, `{claimed_at, ref}`, which claim/1 returns to its fetch (nil when
  # another fetch holds the key). The fetch stores its result and clears the
  # marker only while the marker is still its own, so a caller that stops
  # waiting loses nothing.
  #
  # Req bounds connect and receive but not DNS or pool checkout, so a fetch can
  # stall, and a task killed before its `after` runs leaves its marker behind.
  # A marker older than @claim_ttl_ms is therefore taken over, atomically;
  # until then the key reads as in flight and lookups get an empty map. A
  # stalled fetch that finishes after a takeover neither overwrites the newer
  # owner's cache entry nor clears its marker.
  defp claim(key) do
    now = System.monotonic_time(:millisecond)
    marker = {:in_flight, key}
    stamp = {now, make_ref()}

    taken? =
      :ets.insert_new(@table_name, {marker, stamp}) or
        :ets.select_replace(@table_name, [
          {{marker, {:"$1", :_}}, [{:<, :"$1", now - @claim_ttl_ms}],
           [{{{:const, marker}, {:const, stamp}}}]}
        ]) == 1

    if taken?, do: stamp
  end

  defp sup, do: Mydia.TaskSupervisor

  defp fetch_and_store(key, fetch, stamp) do
    {map, ttl} = run(fetch)

    if owner?(key, stamp),
      do: :ets.insert(@table_name, {key, map, System.monotonic_time(:millisecond) + ttl})

    map
  after
    :ets.select_delete(@table_name, [
      {{{:in_flight, key}, :"$1"}, [{:"=:=", :"$1", {:const, stamp}}], [true]}
    ])
  end

  defp owner?(key, stamp),
    do: :ets.lookup(@table_name, {:in_flight, key}) == [{{:in_flight, key}, stamp}]

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
