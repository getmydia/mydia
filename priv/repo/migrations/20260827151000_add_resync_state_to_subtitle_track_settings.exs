defmodule Mydia.Repo.Migrations.AddResyncStateToSubtitleTrackSettings do
  use Ecto.Migration

  # All three are nullable additions, which SQLite and PostgreSQL both accept as
  # a plain ALTER TABLE ... ADD COLUMN, so this needs no table rebuild through
  # Mydia.Repo.Migrations.Helpers.recreate_table/1.
  #
  # :text rather than :string, per the project-wide rule: a bare :string becomes
  # varchar(255) on PostgreSQL and unconstrained TEXT on SQLite.
  def change do
    alter table(:subtitle_track_settings) do
      add :resync_state, :text
      add :resync_score, :float
      add :resync_at, :utc_datetime
    end
  end
end
