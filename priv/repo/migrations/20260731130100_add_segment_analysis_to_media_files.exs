defmodule Mydia.Repo.Migrations.AddSegmentAnalysisToMediaFiles do
  use Ecto.Migration

  # Purely additive: new columns only. No ALTER COLUMN, so this needs no
  # SQLite/Postgres branching.
  #
  # last_segment_analysis_error is :text rather than :string to match the
  # existing last_analysis_error column: ffmpeg and fpcalc failures routinely
  # run past the varchar(255) that :string means on Postgres.
  def change do
    alter table(:media_files) do
      add :segment_analysis_state, :string, default: "pending", null: false
      add :segments_analyzed_at, :utc_datetime
      add :segment_analysis_attempts, :integer, default: 0, null: false
      add :last_segment_analysis_error, :text
      add :fingerprint_blob, :string
    end

    create index(:media_files, [:segment_analysis_state])
  end
end
