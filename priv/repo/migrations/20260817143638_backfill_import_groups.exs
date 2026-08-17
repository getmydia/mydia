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

  def up do
    # Migrations run outside the app's supervision tree in a release, but the
    # Repo is started by the migrator, which is all these functions need.
    #
    # `String.to_existing_atom/1` below leans on Mydia.Settings.LibraryPath's
    # Ecto.Enum atoms already being registered in the VM's atom table. Nothing
    # else in a bare `mix ecto.migrate` (or a release's migrator) is
    # guaranteed to have loaded that module first, so force it explicitly
    # instead of relying on incidental load order elsewhere in the app.
    Code.ensure_loaded!(Mydia.Settings.LibraryPath)

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
          type: String.to_existing_atom(row.type)
        })

      {:ok, result} = Mydia.ImportGroups.upsert_for_library(library_path)

      IO.puts(
        "[backfill_import_groups] #{row.path}: " <>
          "#{result.groups} groups over #{result.files} unresolved files"
      )
    end)
  end

  def down do
    execute("DELETE FROM import_groups")
    execute("UPDATE media_files SET import_group_id = NULL")
  end

  # SQLite returns binary_id columns as raw strings, Postgres as 16-byte
  # binaries. Ecto.UUID.load/1 normalizes both into the string form the schema
  # expects.
  defp normalize_id(id) when byte_size(id) == 16, do: Ecto.UUID.load!(id)
  defp normalize_id(id), do: id
end
