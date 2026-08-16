defmodule Mydia.Repo.Migrations.RemoveMusicObanJobs do
  use Ecto.Migration

  @moduledoc """
  Drops still-runnable Oban rows for the deleted music worker.

  `Mydia.Jobs.FetchAlbumCover` no longer exists, so a row Oban could still pick
  up would fail on a missing module and consume its retries before being
  discarded.

  Only the states Oban can still execute are deleted: `available`, `scheduled`,
  `retryable`, and `executing`. Terminal states are left alone, because none of
  them will ever be run again and they remain useful history until Oban's pruner
  removes them: `completed`, plus `discarded` and `cancelled`.

  The statement is portable across SQLite and PostgreSQL and needs no adapter branch.
  """

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE worker = 'Mydia.Jobs.FetchAlbumCover'
      AND state IN ('available', 'scheduled', 'retryable', 'executing')
    """)
  end

  def down do
    # The deleted rows reference a worker that no longer exists; recreating them
    # would only reintroduce jobs that cannot run.
    :ok
  end
end
