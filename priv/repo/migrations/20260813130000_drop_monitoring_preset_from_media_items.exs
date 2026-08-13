defmodule Mydia.Repo.Migrations.DropMonitoringPresetFromMediaItems do
  use Ecto.Migration

  # The preset is now a one-shot action rather than stored state. Its only
  # remaining job, deciding what happens to content discovered later, moved to
  # `monitor_new_seasons` plus the season's own episodes.
  #
  # No table rebuild needed on either adapter: the bundled SQLite is 3.53.x,
  # well past the 3.35 floor for DROP COLUMN, and the column carries no index.
  def up do
    alter table(:media_items) do
      remove :monitoring_preset
    end
  end

  def down do
    alter table(:media_items) do
      add :monitoring_preset, :string, default: "all"
    end

    execute(
      "UPDATE media_items SET monitoring_preset = 'none' WHERE monitor_new_seasons = 'none'"
    )
  end
end
