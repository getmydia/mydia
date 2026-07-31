defmodule MetadataRelay.P2pAccess.Store do
  @moduledoc """
  Long-lived ETS owner for p2p relay access state.

  Owns two tables:

    * `:p2p_sightings` - `{endpoint_id, first_seen_unix, last_seen_unix, conn_count}`
    * `:p2p_blocked`   - `{endpoint_id, reason, blocked_at_unix}`

  Reads and writes here are on the relay authorization hot path, so every
  public function in this module must be ETS-only. Database work happens on
  timers inside the GenServer, never inline with a request.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias MetadataRelay.P2pAccess.Block
  alias MetadataRelay.Repo

  @sightings :p2p_sightings
  @blocked :p2p_blocked

  @default_max_sightings 200_000

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
  """
  def reload_blocks do
    rows =
      Block
      |> Repo.all()
      |> Enum.map(fn block ->
        {block.endpoint_id, block.reason, DateTime.to_unix(block.blocked_at)}
      end)

    :ets.delete_all_objects(@blocked)
    :ets.insert(@blocked, rows)

    Logger.info("Loaded #{length(rows)} blocked p2p endpoints")
    :ok
  end

  @impl true
  def init(_opts) do
    init_tables()

    try do
      reload_blocks()
    rescue
      error ->
        Logger.error("Could not load p2p blocklist at boot: #{inspect(error)}")
    end

    {:ok, %{}}
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
end
