defmodule Mydia.Repo.Migrations.AddDefaultFlagsToLibraryPaths do
  use Ecto.Migration

  @moduledoc """
  Marks one library per media kind as the default download target.

  Two flags rather than one because a :mixed library serves both kinds. With a
  single flag, a flagged :movies library and a flagged :mixed library would
  both be "the default" for a movie and the tie would be arbitrary.

  The column is not named `default`: it is a reserved word requiring quoting on
  both adapters.

  Partial unique indexes are supported by both SQLite (3.8+) and PostgreSQL.
  """

  def change do
    alter table(:library_paths) do
      add :default_for_movies, :boolean, default: false, null: false
      add :default_for_series, :boolean, default: false, null: false
    end

    create unique_index(:library_paths, [:default_for_movies],
             where: "default_for_movies = true",
             name: :library_paths_single_default_for_movies
           )

    create unique_index(:library_paths, [:default_for_series],
             where: "default_for_series = true",
             name: :library_paths_single_default_for_series
           )
  end
end
