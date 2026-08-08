defmodule MetadataRelay.P2pAccess.Store do
  @moduledoc """
  Long-lived ETS owner for p2p relay access state.

  Owns two tables:

    * `:p2p_sightings` - `{endpoint_id, first_seen_unix, last_seen_unix, conn_count}`
    * `:p2p_blocked`   - `{endpoint_id, reason, blocked_at_unix}`

  Two functions here sit on the relay authorization hot path and must stay
  ETS-only: `record_sighting/1` and `blocked?/1`. The access callback is
  fail-closed, so if either becomes slow or raises, the relay refuses real
  users.

  The rest do touch the database, but never inline with a request. Seeding runs
  at boot, flush and prune run on timers inside the GenServer, and blocking runs
  on an operator's admin action.

  Both tables are seeded from the database at boot, so a restart does not
  silently unblock revoked endpoints or reset sighting history.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias MetadataRelay.P2pAccess.{Block, Sighting}
  alias MetadataRelay.Repo

  @sightings :p2p_sightings
  @blocked :p2p_blocked

  @default_max_sightings 200_000
  @default_flush_interval_ms 30_000
  @default_prune_interval_ms 86_400_000
  @default_retention_seconds 2_592_000
  @default_reload_retry_interval_ms 5_000

  # exqlite builds SQLite with SQLITE_MAX_VARIABLE_NUMBER=32766, and each
  # sighting row binds 4 parameters, so a single insert_all/3 tops out at
  # 8_191 rows. The configured sighting cap is far higher than that, so the
  # write is chunked well below the ceiling rather than left to fail.
  @insert_chunk_size 2_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates both ETS tables if they do not exist. Idempotent.
  """
  def init_tables do
    # Sightings take a write (update_counter + update_element) on every relay
    # connection, so they need write_concurrency for that many-distinct-keys
    # counter-bump pattern (mirrors MetadataRelay.Metrics's counters table).
    ensure_table(@sightings, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Blocked is read on every connection but written only on rare admin
    # action, so it stays read-optimized instead.
    ensure_table(@blocked, [:set, :public, :named_table, read_concurrency: true])
    :ok
  end

  @doc """
  Records that the relay asked about this endpoint.

  New endpoints are only recorded while the table is below
  `:p2p_max_sightings`. Endpoints already in the table are always updated, so
  a flood of unknown endpoint IDs costs us telemetry rather than memory.

  The cap is a soft cap, not a hard ceiling: the membership check, the size
  check, and the write are three unsynchronized ETS calls, so concurrent
  callers racing at the boundary with different new endpoint IDs can each
  observe the table below the cap and all proceed, overshooting it by
  roughly the number of callers racing at that instant. This is accepted
  deliberately, because the alternative is serializing every relay
  connection through this GenServer, which would make it the very
  bottleneck this ETS-only hot path exists to avoid. What this guarantees
  is bounded growth, not an exact maximum.
  """
  def record_sighting(endpoint_id) when is_binary(endpoint_id) do
    now = System.system_time(:second)

    cond do
      :ets.member(@sightings, endpoint_id) ->
        bump(endpoint_id, now)

      :ets.info(@sightings, :size) < max_sightings() ->
        bump(endpoint_id, now)

      true ->
        MetadataRelay.Metrics.inc("metadata_relay_p2p_sightings_shed_total")
        :ok
    end
  end

  def sighting_count, do: :ets.info(@sightings, :size)

  def lookup_sighting(endpoint_id) when is_binary(endpoint_id) do
    case :ets.lookup(@sightings, endpoint_id) do
      [{^endpoint_id, first_seen, last_seen, conn_count}] ->
        {:ok, {first_seen, last_seen, conn_count}}

      [] ->
        :error
    end
  end

  @doc """
  Whether this endpoint is denied relay access. ETS only, hot path.
  """
  def blocked?(endpoint_id) when is_binary(endpoint_id) do
    :ets.member(@blocked, endpoint_id)
  end

  @doc """
  Blocks an endpoint. Writes the database first so a crash between the two
  writes fails safe: the block survives and is restored by `reload_blocks/0`.
  """
  def put_block(endpoint_id, reason) when is_binary(endpoint_id) and is_binary(reason) do
    blocked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.insert(
        %Block{endpoint_id: endpoint_id, reason: reason, blocked_at: blocked_at},
        on_conflict: {:replace, [:reason, :blocked_at]},
        conflict_target: :endpoint_id
      )

    case result do
      {:ok, _} ->
        :ets.insert(@blocked, {endpoint_id, reason, DateTime.to_unix(blocked_at)})
        Logger.warning("Blocked p2p endpoint #{String.slice(endpoint_id, 0, 8)}: #{reason}")
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Unblocks an endpoint. Removes it from ETS first so access is restored even
  if the database delete fails.
  """
  def delete_block(endpoint_id) when is_binary(endpoint_id) do
    :ets.delete(@blocked, endpoint_id)
    Repo.delete_all(from(b in Block, where: b.endpoint_id == ^endpoint_id))
    Logger.info("Unblocked p2p endpoint #{String.slice(endpoint_id, 0, 8)}")
    :ok
  end

  @doc """
  Repopulates the ETS blocklist from the database. Called at boot.

  Only the database read is fault-tolerant. If the read succeeds, any error
  in the transform or the ETS write is a programming error and crashes.
  """
  def reload_blocks do
    case fetch_blocks() do
      {:ok, blocks} ->
        rows =
          Enum.map(blocks, fn block ->
            {block.endpoint_id, block.reason, DateTime.to_unix(block.blocked_at)}
          end)

        :ets.delete_all_objects(@blocked)
        :ets.insert(@blocked, rows)

        Logger.info("Loaded #{length(rows)} blocked p2p endpoints")
        :ok

      {:error, error} ->
        Logger.error("Could not load p2p blocklist from the database: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Repopulates the ETS sightings table from the database. Called at boot.

  Without this, `list_recent/1` would only ever show endpoints seen since the
  last restart, and the first flush after a restart would overwrite each
  persisted `conn_count` with a counter that had just restarted at zero.

  At most `:p2p_max_sightings` rows are seeded, most recently seen first, so
  a boot cannot start out over the cap.

  Sightings are telemetry, not policy: a failed seed is logged and the table
  is left empty rather than blocking boot or being retried.
  """
  def seed_sightings do
    case fetch_recent_sightings(max_sightings()) do
      {:ok, sightings} ->
        rows =
          Enum.map(sightings, fn sighting ->
            {sighting.endpoint_id, DateTime.to_unix(sighting.first_seen),
             DateTime.to_unix(sighting.last_seen), sighting.conn_count}
          end)

        :ets.insert(@sightings, rows)

        Logger.info("Seeded #{length(rows)} p2p endpoint sightings from the database")
        :ok

      {:error, error} ->
        Logger.warning("Could not seed p2p sightings from the database: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Writes accumulated ETS sightings to the database.

  Returns the number of rows written to the database. If the write fails, the
  failure is logged and this returns `{:ok, 0}` — zero is the truth here,
  since nothing was actually persisted.
  """
  def flush_now, do: GenServer.call(__MODULE__, :flush)

  @doc """
  Drops sightings older than the retention window from ETS and the database.

  Returns the number of ETS rows evicted. That eviction has already happened
  by the time the database delete is attempted, so if the database delete
  fails, the failure is logged but the count is unchanged — the stale rows
  are left in the database to be cleaned up by a later prune, rather than
  being subtracted from what ETS actually evicted.
  """
  def prune_now, do: GenServer.call(__MODULE__, :prune)

  # The database is not always reachable when the Store starts: under the
  # ExUnit sandbox no connection is checked out yet, and in development the
  # database can lag the application. An unreachable database must not stop
  # the service from booting.
  defp fetch_blocks do
    {:ok, Repo.all(Block)}
  rescue
    error -> {:error, error}
  end

  defp fetch_recent_sightings(limit) do
    query = from(s in Sighting, order_by: [desc: s.last_seen], limit: ^limit)
    {:ok, Repo.all(query)}
  rescue
    error -> {:error, error}
  end

  @impl true
  def init(_opts) do
    init_tables()
    reload_blocks_or_retry()
    seed_sightings()

    schedule(:flush, flush_interval_ms())
    schedule(:prune, prune_interval_ms())

    # Zero, not the current time, so the first flush after boot persists the
    # sightings just seeded from the database as well as anything recorded
    # since. The chunking in do_flush/1 is what keeps that first, largest
    # flush safe.
    {:ok, %{last_flush_at: 0}}
  end

  # A blocklist that fails to load must not leave the service running with an
  # empty one: that silently restores access for every revoked endpoint, which
  # is the exact failure this feature exists to prevent. Retry until it loads.
  defp reload_blocks_or_retry do
    case reload_blocks() do
      :ok ->
        :ok

      {:error, _} = error ->
        Logger.warning(
          "The p2p blocklist is empty and revoked endpoints are being allowed. " <>
            "Retrying the load in #{reload_retry_interval_ms()}ms."
        )

        schedule(:reload_blocks, reload_retry_interval_ms())
        error
    end
  end

  # `update_counter` with a default tuple creates the row atomically when it is
  # missing, so `update_element` that follows always finds a row to touch.
  defp bump(endpoint_id, now) do
    :ets.update_counter(@sightings, endpoint_id, {4, 1}, {endpoint_id, now, now, 0})
    :ets.update_element(@sightings, endpoint_id, {3, now})
    :ok
  end

  defp max_sightings do
    Application.get_env(:metadata_relay, :p2p_max_sightings, @default_max_sightings)
  end

  defp ensure_table(name, opts) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
      Logger.info("Created ETS table #{inspect(name)} for p2p access control")
    end

    :ok
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, state} = do_flush(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:prune, _from, state), do: {:reply, do_prune(), state}

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = do_flush(state)
    schedule(:flush, flush_interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    do_prune()
    schedule(:prune, prune_interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:reload_blocks, state) do
    reload_blocks_or_retry()
    {:noreply, state}
  end

  defp do_flush(state) do
    # Read the clock before the select, never after: a sighting recorded
    # between the two would otherwise fall outside both this window and the
    # next one and never be persisted.
    now = System.system_time(:second)

    rows =
      @sightings
      |> select_since(state.last_flush_at)
      |> Enum.map(fn {endpoint_id, first_seen, last_seen, conn_count} ->
        %{
          endpoint_id: endpoint_id,
          first_seen: DateTime.from_unix!(first_seen),
          last_seen: DateTime.from_unix!(last_seen),
          conn_count: conn_count
        }
      end)

    case rows do
      [] ->
        {{:ok, 0}, %{state | last_flush_at: now}}

      rows ->
        # Only the database write below is fault-tolerant. It can fail for
        # environmental reasons (connection drop, lock timeout) and must not
        # take down the Store, which owns the ETS tables the request path
        # depends on: crashing it would discard every sighting and the
        # in-memory blocklist. The transform above, including
        # DateTime.from_unix!/1, is deliberately left outside this rescue —
        # a bad value there is a programming error and must crash loudly
        # rather than be reported as a silent "flush failed".
        try do
          count = insert_sightings(rows)
          {{:ok, count}, %{state | last_flush_at: now}}
        rescue
          error ->
            Logger.error("p2p sighting flush failed to write to the database: #{inspect(error)}")

            # The window is deliberately not advanced on failure, so the next
            # flush retries these rows instead of dropping them.
            {{:ok, 0}, state}
        end
    end
  end

  # Only rows touched since the previous flush need writing, so each cycle
  # costs the delta rather than a full copy of the table. The bound is `>=`,
  # not `>`: `last_seen` has one-second resolution, so a sighting recorded in
  # the same second as the previous flush would be skipped forever by a
  # strict comparison. Re-writing a row an extra time is harmless; losing one
  # is not. Position 3 of the tuple is `last_seen`.
  defp select_since(table, since) do
    :ets.select(table, [{{:_, :_, :"$1", :_}, [{:>=, :"$1", since}], [:"$_"]}])
  end

  # One insert_all/3 per chunk, summed, so a large flush cannot blow past
  # SQLite's bind-parameter ceiling. Errors propagate to the caller's rescue.
  defp insert_sightings(rows) do
    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, total ->
      {count, _} =
        Repo.insert_all(Sighting, chunk,
          on_conflict: {:replace, [:last_seen, :conn_count]},
          conflict_target: :endpoint_id
        )

      total + count
    end)
  end

  defp do_prune do
    cutoff = System.system_time(:second) - retention_seconds()

    stale =
      :ets.select(@sightings, [
        {{:"$1", :_, :"$2", :_}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(stale, &:ets.delete(@sightings, &1))

    cutoff_dt = DateTime.from_unix!(cutoff)

    # As with do_flush/0, only the database delete below is fault-tolerant:
    # it can fail for environmental reasons and must not take down the
    # Store. The ETS work above has already removed the stale rows the
    # request path relies on, regardless of whether the mirrored database
    # cleanup completes.
    try do
      Repo.delete_all(from(s in Sighting, where: s.last_seen < ^cutoff_dt))
    rescue
      error ->
        Logger.error("p2p sighting prune failed to delete database rows: #{inspect(error)}")
    end

    if stale != [] do
      Logger.info("Pruned #{length(stale)} stale p2p endpoint sightings")
    end

    {:ok, length(stale)}
  end

  defp schedule(message, interval_ms) do
    Process.send_after(self(), message, interval_ms)
  end

  defp flush_interval_ms do
    Application.get_env(:metadata_relay, :p2p_flush_interval_ms, @default_flush_interval_ms)
  end

  defp prune_interval_ms do
    Application.get_env(:metadata_relay, :p2p_prune_interval_ms, @default_prune_interval_ms)
  end

  defp reload_retry_interval_ms do
    Application.get_env(
      :metadata_relay,
      :p2p_reload_retry_interval_ms,
      @default_reload_retry_interval_ms
    )
  end

  defp retention_seconds do
    Application.get_env(:metadata_relay, :p2p_retention_seconds, @default_retention_seconds)
  end
end
