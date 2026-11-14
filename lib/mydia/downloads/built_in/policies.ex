defmodule Mydia.Downloads.BuiltIn.Policies do
  @moduledoc """
  The per-poll policies for built-in client downloads, run by
  `Mydia.Jobs.DownloadMonitor`. Each row is isolated: a failure is logged and
  the pass continues, so policies never fail the monitor's poll.
  """

  require Logger

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{FileSelectionPolicy, SeedingPolicy}

  @spec run([struct()], DateTime.t()) :: :ok
  def run(rows, now) do
    name = BuiltIn.name()

    rows
    |> Enum.filter(&(&1.download_client == name))
    |> Enum.each(&run_row(&1, now))
  end

  @selectable_statuses ~w(downloading paused checking queued)

  defp run_row(row, now) do
    if row.in_client? == true and row.status in @selectable_statuses do
      log_failure("file selection", FileSelectionPolicy.apply(row), row)
    end

    log_failure("seeding", SeedingPolicy.apply(row, now), row)
  rescue
    exception ->
      Logger.error("Built-in policies failed; the poll continues",
        download_id: row.id,
        error: Exception.message(exception)
      )
  end

  defp log_failure(policy, {:error, reason}, row) do
    Logger.warning("Built-in #{policy} policy failed",
      download_id: row.id,
      reason: inspect(reason)
    )
  end

  defp log_failure(_policy, _outcome, _row), do: :ok
end
