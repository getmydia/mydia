defmodule Mydia.Jobs.TrashCleanup do
  @moduledoc """
  Background job for permanently deleting media files that have been in trash
  beyond the configured retention period.

  Runs daily to purge trashed files older than the retention period.
  Default retention is 30 days.

  Purging deletes the row **and the bytes behind it**. Trashed files live in
  the trash directory (see `Mydia.Library.TrashStore`); files trashed before
  that directory existed are still sitting at their library path, and are
  deleted from there. Leaving them was
  [#295](https://github.com/getmydia/mydia/issues/295): trash retention
  expired without ever reclaiming any disk space.

  ## Configuration

  Set the retention period in your config:

      config :mydia, :trash_retention_days, 30

  The trash directory itself defaults to a `.mydia-trash` directory beside
  each library path and can be overridden with `MYDIA_TRASH_DIR`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Logger
  alias Mydia.Library

  @default_retention_days 30

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = Application.get_env(:mydia, :trash_retention_days, @default_retention_days)

    Logger.info("Starting trash cleanup job",
      retention_days: retention_days
    )

    case Library.purge_old_trashed_media_files(retention_days) do
      {:ok, count} ->
        Logger.info("Trash cleanup completed",
          deleted_count: count,
          retention_days: retention_days
        )

        :ok
    end
  end
end
