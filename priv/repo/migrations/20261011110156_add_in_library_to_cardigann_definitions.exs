defmodule Mydia.Repo.Migrations.AddInLibraryToCardigannDefinitions do
  @moduledoc """
  Separates "added to my indexers" from "used in searches".

  Until now `enabled` meant both, so switching a library indexer off also took
  it off the Indexers page. Every enabled definition is in the library; a
  disabled one was indistinguishable from one never added, so it starts out of
  the library, which is exactly where the page already showed it.
  """

  use Ecto.Migration

  def up do
    alter table(:cardigann_definitions) do
      add :in_library, :boolean, null: false, default: false
    end

    execute "UPDATE cardigann_definitions SET in_library = enabled"
  end

  def down do
    alter table(:cardigann_definitions) do
      remove :in_library
    end
  end
end
