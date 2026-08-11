defmodule Mydia.Repo.Migrations.RemoveTraktObanJobs do
  use Ecto.Migration

  @moduledoc """
  Drops still-runnable Oban rows for the deleted Trakt workers.

  `Mydia.Jobs.TraktSync` and `Mydia.Jobs.TraktTokenRefresh` no longer exist, so a
  row Oban could still pick up would fail on a missing module and consume its
  retries before being discarded.

  Only the states Oban can still execute are deleted: `available`, `scheduled`,
  `retryable`, and `executing`. Terminal states are left alone, because none of
  them will ever be run again and they remain useful history until Oban's pruner
  removes them: `completed`, plus `discarded` and `cancelled`.

  The statement is portable across SQLite and PostgreSQL and needs no adapter branch.
  """

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE worker LIKE 'Mydia.Jobs.Trakt%'
      AND state IN ('available', 'scheduled', 'retryable', 'executing')
    """)
  end

  def down do
    # The deleted rows reference workers that no longer exist; recreating them
    # would only reintroduce jobs that cannot run.
    :ok
  end
end
