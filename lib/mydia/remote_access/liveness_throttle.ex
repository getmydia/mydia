defmodule Mydia.RemoteAccess.LivenessThrottle do
  @moduledoc """
  In-memory gate in front of `Mydia.RemoteAccess.touch_device_if_stale/1`.

  Every p2p request carries the device's access token, HLS segment requests
  included, so a streaming player asks to record liveness every few seconds.
  The conditional UPDATE behind that throttles itself, but SQLite takes its
  write lock for an UPDATE even when no row matches, so each segment request
  queued behind whatever write was in flight. This remembers when each device
  last claimed a write, so only one request per window reaches the database.

  Two processes can both win a claim in a race. That costs one redundant
  UPDATE, which the conditional statement already reduces to a single write.
  """

  @table :remote_device_liveness

  @doc """
  Creates the ETS table. Must be called before the supervision tree starts.
  """
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
  end

  @doc """
  Returns `true`, and starts a new window, when `device_id` has not claimed a
  write within the last `window_ms`. Returns `false` otherwise.
  """
  @spec claim(String.t(), pos_integer(), integer()) :: boolean()
  def claim(device_id, window_ms, now_ms \\ System.monotonic_time(:millisecond)) do
    case :ets.lookup(@table, device_id) do
      [{^device_id, claimed_at}] when now_ms - claimed_at < window_ms ->
        false

      _ ->
        :ets.insert(@table, {device_id, now_ms})
        true
    end
  end
end
