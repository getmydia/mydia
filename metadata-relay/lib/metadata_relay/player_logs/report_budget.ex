defmodule MetadataRelay.PlayerLogs.ReportBudget do
  @moduledoc """
  A per-address daily byte budget for `kind: "report"` uploads only.

  `device_id` is client-controlled and only UUID-validated
  (`MetadataRelay.PlayerLogs.Ingest`), so rotating it bypasses both the
  per-device rate limit and the per-device daily quota
  (`MetadataRelay.PlayerLogs.ingest/2`). An all-traffic per-address budget
  would close that, but production sits behind Cloudflare, where the
  resolvable client address can be an edge shared by many installs (see
  `MetadataRelay.PlayerLogs.Handler`'s moduledoc) -- an all-traffic budget
  keyed on that address would starve unrelated installs sharing it.

  Scoping the budget to reports only is what makes it safe to share an
  address's bucket across every device behind it: a report is a deliberate
  "Send logs now" upload of a few MB, so even a shared edge produces only a
  handful a day. Stream traffic keeps just the existing loose per-address
  rate limit (`MetadataRelay.PlayerLogs.Handler`'s `@ip_limit`) -- stream
  chunks are the first thing `MetadataRelay.PlayerLogs.enforce_cap/0` evicts
  under the disk cap, so a device-rotating stream flood degrades stream
  retention but cannot touch the report store, which is where a user's
  actual bug report lives.

  Backed by ETS rather than the database: a restart clearing every address's
  count costs an attacker nothing they could not get by waiting a few
  minutes for a fresh pod, and it keeps this off the SQLite write path
  entirely.
  """

  use GenServer

  @table :player_logs_report_budget
  @default_budget_bytes 256 * 1024 * 1024

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Reserves `size` report bytes against `address`'s daily budget, or refuses
  without reserving anything when that would exceed it. The check and the
  increment run inside the same `handle_call/3`, so they cannot interleave
  with another reservation the way two separate `check` and `charge` calls
  could: concurrent uploads no longer both read "room left" and both land.

  Call `release/3` to give the bytes back if the batch this reservation was
  for then fails to store.
  """
  @spec reserve(String.t(), non_neg_integer(), DateTime.t()) :: :ok | {:error, pos_integer()}
  def reserve(address, size, now) do
    GenServer.call(__MODULE__, {:reserve, address, size, DateTime.to_date(now), now})
  end

  @doc """
  Gives back `size` bytes reserved for `address`, flooring at zero. A no-op
  if the day has already rolled over, since the reservation it would undo no
  longer applies to today's tally anyway.
  """
  @spec release(String.t(), non_neg_integer(), DateTime.t()) :: :ok
  def release(address, size, now) do
    GenServer.call(__MODULE__, {:release, address, size, DateTime.to_date(now)})
  end

  @doc false
  @spec used(String.t(), DateTime.t()) :: non_neg_integer()
  def used(address, now) do
    today = DateTime.to_date(now)

    case :ets.lookup(@table, address) do
      [{^address, ^today, bytes}] -> bytes
      _ -> 0
    end
  end

  defp budget do
    Application.fetch_env!(:metadata_relay, :player_logs)
    |> Keyword.get(:report_budget_bytes, @default_budget_bytes)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:reserve, address, size, today, now}, _from, state) do
    used =
      case :ets.lookup(@table, address) do
        [{^address, ^today, bytes}] -> bytes
        _ -> 0
      end

    if used + size > budget() do
      {:reply, {:error, MetadataRelay.PlayerLogs.seconds_until_midnight(now)}, state}
    else
      :ets.insert(@table, {address, today, used + size})
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release, address, size, today}, _from, state) do
    case :ets.lookup(@table, address) do
      [{^address, ^today, bytes}] -> :ets.insert(@table, {address, today, max(bytes - size, 0)})
      # No entry, or one from a previous day: today's tally is already zero
      # (or about to be reset by the next reserve), so there is nothing to
      # give back.
      _ -> :ok
    end

    {:reply, :ok, state}
  end
end
