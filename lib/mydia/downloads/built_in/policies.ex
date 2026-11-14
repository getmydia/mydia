defmodule Mydia.Downloads.BuiltIn.Policies do
  @moduledoc """
  The per-poll policies for built-in client downloads, run by
  `Mydia.Jobs.DownloadMonitor`. Each row is isolated: a failure is logged and
  the pass continues, so policies never fail the monitor's poll.
  """

  require Logger

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.SeedingPolicy

  @spec run([struct()], DateTime.t()) :: :ok
  def run(rows, now) do
    name = BuiltIn.name()

    rows
    |> Enum.filter(&(&1.download_client == name))
    |> Enum.each(&run_row(&1, now))
  end

  defp run_row(row, now) do
    case SeedingPolicy.apply(row, now) do
      {:error, reason} ->
        Logger.warning("Built-in seeding policy failed",
          download_id: row.id,
          reason: inspect(reason)
        )

      _outcome ->
        :ok
    end
  rescue
    exception ->
      Logger.error("Built-in policies failed; the poll continues",
        download_id: row.id,
        error: Exception.message(exception)
      )
  end
end
