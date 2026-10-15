defmodule Mydia.Repo.Migrations.CancelSnoozeLoopedRefreshJobs do
  use Ecto.Migration

  @moduledoc """
  Cancels the cron runs of `Mydia.Jobs.MetadataRefresh` and
  `Mydia.Jobs.AiringEpisodeRefresh` that never ran.

  Both workers snoozed whenever `attempt == 1`, and Oban 2.24 rolls `attempt`
  back on snooze, so every cron run since that upgrade snoozed forever. Each
  install holds one stuck row per missed run (120 airing refreshes on one
  install after a month). With the snooze fixed they would all wake inside the
  same few minutes and re-read the same seasons from the shared relay over and
  over. One fresh run is enough: the next crontab tick inserts it.

  Only `scheduled` rows are touched, which is where a snoozed job waits. Rows
  for a single item (`MetadataRefresh` with a `media_item_id`) are inserted
  `available` and never snooze, so they are unaffected. The statement is
  portable across SQLite and PostgreSQL.
  """

  def up do
    execute("""
    UPDATE oban_jobs
    SET state = 'cancelled', cancelled_at = CURRENT_TIMESTAMP
    WHERE worker IN ('Mydia.Jobs.MetadataRefresh', 'Mydia.Jobs.AiringEpisodeRefresh')
      AND state = 'scheduled'
    """)
  end

  def down do
    # The cancelled rows were duplicates of a run the cron plugin inserts again.
    :ok
  end
end
