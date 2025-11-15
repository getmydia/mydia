defmodule Mydia.Repo.Migrations.AddRelativePathColumnsToMediaFiles do
  use Ecto.Migration

  def change do
    # Add library_path_id foreign key column
    # Nullable initially to allow data migration
    # CASCADE on delete: if library path is deleted, remove associated files
    alter table(:media_files) do
      add :library_path_id, references(:library_paths, type: :binary_id, on_delete: :delete_all)
    end

    # Add index on library_path_id for query performance
    create index(:media_files, [:library_path_id])

    # Add relative_path column
    # Nullable initially to allow gradual migration
    # Will store path relative to library root
    alter table(:media_files) do
      add :relative_path, :string
    end
  end
end
