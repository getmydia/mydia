defmodule Mydia.Repo.Migrations.UpgradeObanJobsToV14 do
  use Ecto.Migration

  # Oban 2.23 introduced a `:suspended` job state and its own Oban.Testing
  # helpers (assert_enqueued/refute_enqueued) unconditionally query for it
  # alongside :available/:scheduled. On SQLite the `state` column is plain
  # text, so this is a no-op there, but Postgres stores it in a native
  # `oban_job_state` enum — without this migration, any such query raises
  # `invalid input value for enum oban_job_state: "suspended"`.
  #
  # v13 adds two supporting indexes; v14 adds the 'suspended' enum value.
  # Both steps are Oban's own migrator (see the original migration at
  # 20251104022339_add_oban_jobs_table.exs), so this stays adapter-agnostic
  # the same way that one does.
  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 12)
  end
end
