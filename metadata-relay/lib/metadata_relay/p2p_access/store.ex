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

  require Logger

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
    ensure_table(@sightings)
    ensure_table(@blocked)
    :ok
  end

  @doc """
  Records that the relay asked about this endpoint.

  New endpoints are only recorded while the table is below
  `:p2p_max_sightings`. Endpoints already in the table are always updated, so
  a flood of unknown endpoint IDs costs us telemetry rather than memory.
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

  @impl true
  def init(_opts) do
    init_tables()
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

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
      Logger.info("Created ETS table #{inspect(name)} for p2p access control")
    end

    :ok
  end
end
