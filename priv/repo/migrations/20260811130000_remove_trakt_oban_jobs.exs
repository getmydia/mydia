defmodule Mydia.Repo.Migrations.RemoveTraktObanJobs do
  use Ecto.Migration

  @moduledoc """
  Drops queued Oban rows for the deleted Trakt workers.

  `Mydia.Jobs.TraktSync` and `Mydia.Jobs.TraktTokenRefresh` no longer exist, so a
  pending row would fail on a missing module and consume its retries before
  Oban discarded it. Completed rows are left alone: Oban never re-executes them
  and its pruner removes them on the usual schedule.

  The statement is portable across SQLite and PostgreSQL and needs no adapter branch.
  """

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE worker LIKE 'Mydia.Jobs.Trakt%' AND state != 'completed'
    """)
  end

  def down do
    # The deleted rows reference workers that no longer exist; recreating them
    # would only reintroduce jobs that cannot run.
    :ok
  end
end
