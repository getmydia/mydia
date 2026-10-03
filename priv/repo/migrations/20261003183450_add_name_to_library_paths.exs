defmodule Mydia.Repo.Migrations.AddNameToLibraryPaths do
  use Ecto.Migration

  @moduledoc """
  Optional display name for a library. Without one the UI shows the folder
  name. Nullable, so it is a plain ADD COLUMN on both adapters.
  """

  def change do
    alter table(:library_paths) do
      add :name, :text
    end
  end
end
