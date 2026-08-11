defmodule Mydia.Repo.Migrations.AddLibraryPathToMediaItems do
  use Ecto.Migration

  @moduledoc """
  Adds an explicit download-target library to media items.

  Nullable: NULL means "no explicit preference, resolve dynamically".
  on_delete: :nilify_all so removing a library returns its items to inferred
  resolution rather than blocking the delete.
  """

  def change do
    alter table(:media_items) do
      add :library_path_id,
          references(:library_paths, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:media_items, [:library_path_id])
  end
end
