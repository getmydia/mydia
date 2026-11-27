defmodule Mydia.Jobs.SmartSpaceCleanup do
  @moduledoc """
  Daily job that moves watched TV to the trash when Smart Space is enabled.

  A thin wrapper over `Mydia.SmartSpace.run/0`. Files are trashed, never
  deleted, so `Mydia.Jobs.TrashCleanup` still applies the retention window.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Mydia.SmartSpace.run() do
      {:ok, summary} ->
        Logger.info("Smart Space cleanup completed", summary: inspect(summary))
        :ok

      {:error, :misconfigured} ->
        # Already recorded as a warning event; retrying would not change it.
        Logger.warning("Smart Space cleanup skipped: selected users do not resolve")
        :ok
    end
  end
end
