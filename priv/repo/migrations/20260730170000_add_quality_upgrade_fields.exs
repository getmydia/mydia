defmodule Mydia.Repo.Migrations.AddQualityUpgradeFields do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  def up do
    alter table(:quality_profiles) do
      add :upgrade_until_score, :integer, default: 85
      add :min_upgrade_margin, :integer, default: 5
    end

    alter table(:media_items) do
      add :last_upgrade_check_at, :utc_datetime
    end

    alter table(:episodes) do
      add :last_upgrade_check_at, :utc_datetime
    end

    alter table(:media_files) do
      add :supersedes_media_file_id,
          references(:media_files, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:media_items, [:last_upgrade_check_at])
    create index(:episodes, [:last_upgrade_check_at])
    create index(:media_files, [:supersedes_media_file_id])

    # Required. Ecto batches `alter table` and flushes it lazily, so without
    # this the UPDATE below runs before upgrade_until_score exists and the
    # migration fails with "no such column".
    flush()

    # Translate the retired resolution ceiling into an equivalent score so
    # existing profiles keep behaving sensibly. A profile that previously
    # capped upgrades at a low resolution gets a correspondingly low cutoff.
    execute """
    UPDATE quality_profiles
    SET upgrade_until_score = CASE upgrade_until_quality
      WHEN '480p' THEN 40
      WHEN '576p' THEN 45
      WHEN '720p' THEN 60
      WHEN '1080p' THEN 85
      WHEN '2160p' THEN 95
      ELSE 85
    END
    """

    drop_upgrade_until_quality()
  end

  def down do
    alter table(:quality_profiles) do
      add :upgrade_until_quality, :string
    end

    drop index(:media_files, [:supersedes_media_file_id])
    drop index(:episodes, [:last_upgrade_check_at])
    drop index(:media_items, [:last_upgrade_check_at])

    alter table(:media_files) do
      remove :supersedes_media_file_id
    end

    alter table(:episodes) do
      remove :last_upgrade_check_at
    end

    alter table(:media_items) do
      remove :last_upgrade_check_at
    end

    alter table(:quality_profiles) do
      remove :min_upgrade_margin
      remove :upgrade_until_score
    end
  end

  # Adapter-aware column drop. Deliberately NOT using `recreate_table/1` here:
  # its SQLite path is create-new / copy / DROP TABLE / rename, and this repo
  # runs SQLite with `foreign_keys: :on` (config/dev.exs, config/runtime.exs).
  # Under that pragma, `DROP TABLE` on a table other tables reference performs
  # an implicit `DELETE FROM` that fires child FK actions: media_files.
  # quality_profile_id has no ON DELETE and aborts the migration outright,
  # while media_items/library_paths are ON DELETE SET NULL and silently lose
  # their profile assignment. A direct column drop has none of that — the
  # column carries no index, UNIQUE, or constraint, and SQLite has supported
  # `ALTER TABLE ... DROP COLUMN` since 3.35. Do not reinstate recreate_table
  # for this column.
  defp drop_upgrade_until_quality do
    if postgres?() do
      execute("ALTER TABLE quality_profiles DROP COLUMN IF EXISTS upgrade_until_quality")
    else
      execute("ALTER TABLE quality_profiles DROP COLUMN upgrade_until_quality")
    end
  end
end
