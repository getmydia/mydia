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

  # Adapter-aware column drop. This mirrors `drop_dead_columns/0` in
  # priv/repo/migrations/20260628000000_unify_quality_profiles.exs, which drops
  # columns from this exact table. Postgres drops directly; SQLite rebuilds the
  # table without the dropped column. `recreate_table/1` takes a keyword list
  # and raises without `:table`, so the full column and index list is required.
  defp drop_upgrade_until_quality do
    if postgres?() do
      execute("ALTER TABLE quality_profiles DROP COLUMN IF EXISTS upgrade_until_quality")
    else
      recreate_table(
        table: :quality_profiles,
        primary_key: false,
        columns: [
          {:id, :binary_id, [primary_key: true]},
          {:name, :string, [null: false]},
          {:upgrades_allowed, :boolean, [default: true]},
          {:description, :text, []},
          {:is_system, :boolean, [default: false]},
          {:version, :integer, [default: 1]},
          {:source_url, :string, []},
          {:last_synced_at, :utc_datetime, []},
          {:quality_standards, :text, []},
          {:upgrade_until_score, :integer, [default: 85]},
          {:min_upgrade_margin, :integer, [default: 5]}
        ],
        indexes: [
          {[:name], [unique: true]},
          [:is_system],
          [:version]
        ]
      )
    end
  end
end
