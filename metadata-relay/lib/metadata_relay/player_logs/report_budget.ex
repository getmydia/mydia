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
  Whether `size` more report bytes from `address` today would stay within
  the daily budget. Charges nothing; call `charge/3` once the batch the
  check was for has actually been stored.
  """
  @spec check(String.t(), non_neg_integer(), DateTime.t()) :: :ok | {:error, pos_integer()}
  def check(address, size, now) do
    if used(address, now) + size > budget() do
      {:error, MetadataRelay.PlayerLogs.seconds_until_midnight(now)}
    else
      :ok
    end
  end

  @doc "Adds `size` bytes to `address`'s tally for today, resetting it first if the day rolled over."
  @spec charge(String.t(), non_neg_integer(), DateTime.t()) :: :ok
  def charge(address, size, now) do
    GenServer.call(__MODULE__, {:charge, address, size, DateTime.to_date(now)})
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
  def handle_call({:charge, address, size, today}, _from, state) do
    new_bytes =
      case :ets.lookup(@table, address) do
        [{^address, ^today, bytes}] -> bytes + size
        _ -> size
      end

    :ets.insert(@table, {address, today, new_bytes})
    {:reply, :ok, state}
  end
end
