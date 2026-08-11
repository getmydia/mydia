defmodule Mydia.Jobs.SyncRunCleanup do
  @moduledoc """
  Background job for pruning old sync run records.

  Sync runs are written per server, per user, per scheduler tick, so at the
  default 30 minute cadence a single mapped user produces roughly 48 rows a day.
  Retention is required from the start rather than added once the table is
  already large.

  ## Configuration

  Set the retention period in your config:

      config :mydia, :sync_run_retention_days, 30
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Logger

  alias Mydia.Sync

  @default_retention_days 30

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days =
      Application.get_env(:mydia, :sync_run_retention_days, @default_retention_days)

    Logger.info("Starting sync run cleanup job", retention_days: retention_days)

    {count, _} = Sync.prune(retention_days)

    Logger.info("Sync run cleanup completed",
      deleted_count: count,
      retention_days: retention_days
    )

    :ok
  end
end
