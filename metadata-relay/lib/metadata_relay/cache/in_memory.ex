defmodule MetadataRelay.Cache.InMemory do
  @moduledoc """
  In-memory cache adapter using ETS.

  Provides fast, local caching with TTL and size limits.
  Cache contents are lost on service restart.
  """

  use GenServer
  require Logger

  @behaviour MetadataRelay.Cache.Adapter

  @table_name :metadata_relay_cache
  # Tracks insertion order independently of the main table, which is a
  # `:set` keyed on cache key (for O(1) lookup by key) and therefore cannot
  # itself answer "what was inserted first" -- `:ets.first/1` on a `:set`
  # returns whatever key the table's internal hashing happens to place
  # first, unrelated to insertion order. This table is an `:ordered_set`
  # keyed on a monotonic sequence number, so its first key genuinely is the
  # oldest live entry.
  @order_table_name :metadata_relay_cache_order
  @stats_table :metadata_relay_cache_stats
  @cleanup_interval :timer.minutes(15)
  @default_max_entries 20_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl MetadataRelay.Cache.Adapter
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at, _seq}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          Logger.debug("Cache hit: #{key}")
          increment_hits()
          {:ok, value}
        else
          # Expired entry
          delete_entry(key)
          increment_misses()
          {:error, :not_found}
        end

      [] ->
        increment_misses()
        {:error, :not_found}
    end
  end

  @impl MetadataRelay.Cache.Adapter
  def put(key, value, ttl) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :millisecond)

    # An update to an existing key must drop its old position in the order
    # table first, or that stale (and now spuriously "oldest") sequence
    # number would linger there and could get a fresh entry evicted in its
    # place.
    drop_order_entry(key)

    # Check size limit and evict if necessary
    if :ets.info(@table_name, :size) >= max_entries() do
      evict_oldest()
    end

    seq = :erlang.unique_integer([:monotonic, :positive])
    :ets.insert(@order_table_name, {seq, key})
    :ets.insert(@table_name, {key, value, expires_at, seq})
    Logger.debug("Cache put: #{key} (TTL: #{ttl}ms)")
    :ok
  end

  @impl MetadataRelay.Cache.Adapter
  def clear do
    :ets.delete_all_objects(@table_name)
    :ets.delete_all_objects(@order_table_name)
    # Also reset stats counters
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    :ok
  end

  @impl MetadataRelay.Cache.Adapter
  def stats do
    size = :ets.info(@table_name, :size)
    memory_words = :ets.info(@table_name, :memory)
    memory_bytes = memory_words * :erlang.system_info(:wordsize)
    memory_mb = Float.round(memory_bytes / 1_024_000, 2)

    hits = get_counter(:hits)
    misses = get_counter(:misses)
    total = hits + misses
    hit_rate = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0
    max = max_entries()

    %{
      adapter: "in_memory",
      size: size,
      max_entries: max,
      memory_mb: memory_mb,
      memory_bytes: memory_bytes,
      utilization_pct: Float.round(size / max * 100, 1),
      hits: hits,
      misses: misses,
      total_requests: total,
      hit_rate_pct: hit_rate
    }
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    :ets.new(@order_table_name, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true
    ])

    :ets.new(@stats_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    schedule_cleanup()
    Logger.info("In-memory cache adapter started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  # Overridable for tests: exercising the real 20,000-entry default would
  # make eviction tests slow (and, worse, only ever test the "cache is
  # basically empty" case in isolation from other suites). Production
  # never sets this.
  defp max_entries do
    Application.get_env(:metadata_relay, :cache_max_entries, @default_max_entries)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()

    expired =
      :ets.select(@table_name, [
        {{:"$1", :_, :"$3", :"$4"}, [{:<, :"$3", {:const, now}}], [{{:"$1", :"$4"}}]}
      ])

    # `expired` is a snapshot taken by the `:ets.select/2` above. A
    # concurrent `put/3` for one of these keys can land between that
    # snapshot and this loop and give the key a new value and a new `seq`
    # -- see `delete_if_current/2` for why the main-table delete below must
    # be conditioned on `seq` still matching, rather than deleting by `key`
    # alone, or this sweep could destroy a write that raced in after the
    # snapshot decided the *old* value had expired.
    Enum.each(expired, fn {key, seq} ->
      delete_if_current(key, seq)
      :ets.delete(@order_table_name, seq)
    end)

    if expired != [] do
      Logger.debug("Cleaned up #{length(expired)} expired cache entries")
    end
  end

  # Deletes oldest-first by insertion order, using the order table's own
  # ordering rather than the main table's arbitrary hash-bucket order.
  #
  # Two concurrent `put/3` calls for the same key can each insert their own
  # `{seq, key}` row into the order table (`drop_order_entry/1`'s
  # lookup-then-delete is not atomic with the sibling call's own insert),
  # while the main table -- a `:set` -- ends up keeping only the last
  # writer's record. That leaves the losing call's order-table row pointing
  # at a `seq` the main table no longer has under that key. Walking
  # straight from that stale row to an unconditional
  # `:ets.delete(@table_name, key)` would delete whatever the *current*
  # (possibly much newer, unrelated to this row) record for that key is,
  # destroying live data a concurrent write just produced. Guarding the
  # delete on `seq` still matching (`delete_if_current/2`) means a stale
  # row can only ever remove itself; eviction then falls through to the
  # next-oldest row so real capacity pressure still gets relieved.
  defp evict_oldest do
    case :ets.first(@order_table_name) do
      :"$end_of_table" ->
        :ok

      seq ->
        case :ets.lookup(@order_table_name, seq) do
          [{^seq, key}] ->
            :ets.delete(@order_table_name, seq)

            if delete_if_current(key, seq) == 0 do
              evict_oldest()
            end

          [] ->
            evict_oldest()
        end
    end
  end

  # Best-effort: this lookup-then-delete is itself the non-atomic sequence
  # that lets a concurrent sibling `put/3` call's row survive uncleared (see
  # `evict_oldest/0`). That's left as-is rather than serialized -- a
  # surviving stale row costs a few bytes in the order table and is always
  # reconciled the next time `evict_oldest/0` walks past it, since every
  # main-table delete downstream (`delete_if_current/2`) is itself guarded
  # against acting on a stale `seq`. Making *this* function atomic too would
  # only shrink how often a harmless orphan row briefly exists, not change
  # any observable behavior, so it isn't worth adding contention to the hot
  # path of every cache write for that.
  defp drop_order_entry(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, _value, _expires_at, seq}] -> :ets.delete(@order_table_name, seq)
      [] -> :ok
    end
  end

  defp delete_entry(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, _value, _expires_at, seq}] ->
        delete_if_current(key, seq)
        :ets.delete(@order_table_name, seq)

      [] ->
        :ok
    end
  end

  # Deletes the main-table record for `key` only if it is still the exact
  # record tagged with `seq` -- never a record a concurrent `put/3` has
  # since replaced with a new value and a new `seq`. Always safe to call
  # with a `seq` that no longer matches (or a `key` that no longer exists):
  # it simply deletes nothing. Returns the number of records deleted (0 or
  # 1), matching `:ets.select_delete/2`.
  defp delete_if_current(key, seq) do
    :ets.select_delete(@table_name, [{{key, :_, :_, seq}, [], [true]}])
  end

  defp increment_hits do
    :ets.update_counter(@stats_table, :hits, 1, {:hits, 0})
  end

  defp increment_misses do
    :ets.update_counter(@stats_table, :misses, 1, {:misses, 0})
  end

  defp get_counter(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end
