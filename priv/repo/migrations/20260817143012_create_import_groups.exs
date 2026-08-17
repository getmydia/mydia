defmodule Mydia.Repo.Migrations.CreateImportGroups do
  use Ecto.Migration

  def change do
    create table(:import_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :library_path_id,
          references(:library_paths, type: :binary_id, on_delete: :delete_all),
          null: false

      add :import_run_id,
          references(:import_runs, type: :binary_id, on_delete: :nilify_all)

      add :anchor_path, :text, null: false
      add :cluster_key, :text, null: false
      add :display_title, :text

      add :file_count, :integer, null: false, default: 0
      add :unresolved_count, :integer, null: false, default: 0
      add :numbered_count, :integer, null: false, default: 0

      add :media_type, :text
      add :provider_type, :text
      add :provider_id, :text
      add :suggested_title, :text
      add :suggested_year, :integer
      add :min_confidence, :float
      add :evidence, :text
      add :season_span, :text

      add :status, :text, null: false, default: "pending"
      add :decided_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_groups, [:library_path_id, :cluster_key])
    create index(:import_groups, [:library_path_id, :status, :file_count])
    create index(:import_groups, [:library_path_id, :status, :min_confidence])
  end
end
