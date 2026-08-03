defmodule Mydia.Repo.Migrations.CreateMediaSegments do
  use Ecto.Migration

  # Purely additive: a brand new table. No ALTER COLUMN, so this needs no
  # SQLite/Postgres branching.
  def change do
    create table(:media_segments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id,
          references(:media_files, type: :binary_id, on_delete: :delete_all),
          null: false

      add :type, :string, null: false
      add :start_ms, :integer, null: false
      add :end_ms, :integer, null: false
      add :source, :string, null: false
      add :confidence, :float, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:media_segments, [:media_file_id])
    create unique_index(:media_segments, [:media_file_id, :type])
  end
end
