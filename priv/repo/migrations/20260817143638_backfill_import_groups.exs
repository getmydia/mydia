defmodule Mydia.Repo.Migrations.BackfillImportGroups do
  @moduledoc """
  Populates `import_groups` for an install that upgraded into the grouped
  review page, so no rescan is needed to make the page usable.

  Deliberately calls the runtime context rather than reimplementing the
  clustering in SQL. That couples the migration to application code, which is
  normally worth avoiding, but the alternative is a second implementation of
  `PathAnchor` in SQL that would silently drift from the real one. The context
  call is idempotent and chunked, so re-running after a partial failure is safe.
  """
  use Ecto.Migration

  import Ecto.Query

  # Without this, Ecto.Migrator wraps the entire up/0 body in one
  # repo.transaction/2 (SQLite's adapter reports supports_ddl_transaction?
  # true, same as PostgreSQL), which holds SQLite's single global write lock
  # for the whole backfill and defeats the point of upsert_for_library/2's
  # keyset chunking: a crash partway through would roll back every library
  # already processed instead of leaving their groups in place, and "resumable
  # after a partial failure" (see moduledoc) would be false. Disabling it makes
  # each Repo call its own commit, so a failure partway through leaves earlier
  # libraries' groups intact and a re-run only has to redo the rest.
  @disable_ddl_transaction true

  def up do
    # Migrations run outside the app's supervision tree in a release, but the
    # Repo is started by the migrator, which is all these functions need.
    Mydia.Repo.all(
      from(lp in "library_paths",
        where: lp.type in ["series", "movies"],
        select: %{id: lp.id, path: lp.path, type: lp.type}
      )
    )
    |> Enum.each(fn row ->
      library_path =
        struct(Mydia.Settings.LibraryPath, %{
          id: normalize_id(row.id),
          path: row.path,
          type: path_type(row.type)
        })

      {:ok, result} = Mydia.ImportGroups.upsert_for_library(library_path)

      IO.puts(
        "[backfill_import_groups] #{row.path}: " <>
          "#{result.groups} groups over #{result.files} unresolved files"
      )
    end)
  end

  def down do
    # Deliberately a no-op. up/0 stamps no marker distinguishing rows it
    # created from rows created afterward, and by the time anyone rolls this
    # back the import pipeline creates a group on every run -- groups now
    # carry human decisions (accepted, ignored, local shows). A DELETE FROM
    # import_groups here would destroy that live state, not just undo a
    # backfill, so there is no rollback that is both selective and correct.
    :ok
  end

  # SQLite returns binary_id columns as raw strings, Postgres as 16-byte
  # binaries. Ecto.UUID.load/1 normalizes both into the string form the schema
  # expects.
  defp normalize_id(id) when byte_size(id) == 16, do: Ecto.UUID.load!(id)
  defp normalize_id(id), do: id

  # A direct mapping instead of String.to_existing_atom/1: the query above
  # already constrains row.type to exactly these two values, so this needs no
  # reliance on some other module having interned the atom first into the
  # VM's atom table, which a bare `mix ecto.migrate` does not guarantee. No
  # catch-all is deliberate: if the query's `where` ever grows a third type,
  # this raises immediately instead of silently mis-typing a library.
  defp path_type("series"), do: :series
  defp path_type("movies"), do: :movies
end
