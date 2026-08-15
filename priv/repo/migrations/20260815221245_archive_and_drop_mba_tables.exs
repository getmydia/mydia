defmodule Mydia.Repo.Migrations.ArchiveAndDropMbaTables do
  @moduledoc """
  Removes the music, books, and adult verticals.

  Archives every table that still holds rows to NDJSON BEFORE dropping
  anything, and aborts without dropping if archival fails.

  library_paths rows of the removed types are CONVERTED to :mixed and disabled,
  never deleted. media_files.library_path_id is on_delete: :delete_all, so
  deleting those rows would cascade into real user media: adult content lived
  in the shared media_files table, and music and book downloads left
  media_files rows behind with no parent at all.
  """
  use Ecto.Migration

  require Logger

  alias Mydia.Release.TableArchive
  alias Mydia.Repo.Migrations.Helpers

  # Children before parents. On SQLite a DROP fires the foreign key actions of
  # every table still referencing the dropped one, so a parent must never be
  # dropped while one of its children is still around.
  @tables ~w(
    playlist_tracks
    music_files
    playlists
    tracks
    albums
    artists
    book_files
    books
    authors
    adult_files
    scenes
    studios
  )

  def up do
    archive!()
    convert_library_paths()
    Enum.each(@tables, &drop_if_exists(table(&1)))
  end

  def down do
    raise Ecto.MigrationError,
      message: """
      This migration cannot be reversed. The music, books, and adult tables were
      archived to NDJSON before being dropped; restore from that archive if you
      need the data back.
      """
  end

  defp archive! do
    case tables_with_rows() do
      [] -> :ok
      tables -> archive!(tables)
    end
  end

  defp archive!(tables) do
    dir = Path.join(archive_root(), "mba-#{timestamp()}")

    case TableArchive.archive_tables(repo(), tables, dir) do
      {:ok, counts} ->
        total = counts |> Map.values() |> Enum.sum()

        Logger.warning("""
        [MBA removal] Archived #{total} rows from music/books/adult tables to:
          #{dir}
        These tables are now being dropped. Keep that directory if you want the data.
        """)

        :ok

      {:error, reason} ->
        raise Ecto.MigrationError,
          message:
            "Refusing to drop music/books/adult tables: archival failed with #{inspect(reason)}"
    end
  end

  # Only archive tables that exist and hold something. A fresh install has never
  # had them, and an install that enabled none of the three verticals has them
  # empty; neither should touch the disk, so neither can fail on a data
  # directory it cannot write to.
  defp tables_with_rows do
    Enum.filter(@tables, fn table -> table_exists?(table) and has_rows?(table) end)
  end

  # Existence is read from the catalog rather than probed by selecting from the
  # table. On PostgreSQL a failed statement poisons the surrounding transaction,
  # and migrations run inside one, so a probe that errors on a fresh install
  # would take the whole migration down with it.
  #
  # Both statements raise rather than answering "no" if they fail: a table whose
  # contents cannot be determined must not be dropped.
  #
  # Every interpolated table name comes from the compile-time @tables list.
  defp table_exists?(table) do
    sql =
      if Helpers.postgres?() do
        """
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = current_schema() AND table_name = '#{table}'
        """
      else
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '#{table}'"
      end

    match?(%{rows: [_ | _]}, repo().query!(sql))
  end

  defp has_rows?(table) do
    match?(%{rows: [_ | _]}, repo().query!(~s(SELECT 1 FROM "#{table}" LIMIT 1)))
  end

  defp convert_library_paths do
    %{num_rows: converted} =
      repo().query!("""
      UPDATE library_paths
         SET type = 'mixed', disabled = #{Helpers.to_db_value(true)}
       WHERE type IN ('music', 'books', 'adult')
      """)

    if converted > 0 do
      Logger.warning("""
      [MBA removal] Converted #{converted} music/books/adult library path(s) to
      type 'mixed' and disabled them. Their media files were NOT touched.
      Re-enable them from Settings if you want them scanned as video libraries.
      """)
    end
  end

  # An archive is only worth writing if the operator can still find it after the
  # upgrade that wrote it. On SQLite the database file sits on a durable,
  # writable volume by construction (/config in the official image), so the
  # archive goes beside it. PostgreSQL deployments have no such local anchor and
  # fall back to the release's own data directory. Either way the migration logs
  # the full path it used.
  defp archive_root do
    Path.join(data_dir(), "archives")
  end

  defp data_dir do
    if Helpers.sqlite?() do
      sqlite_database_dir() || "priv/data"
    else
      "priv/data"
    end
  end

  # The open database is asked where it lives rather than the repo config being
  # read, so this follows the file the migration is actually running against.
  # An in-memory database reports an empty file and falls through.
  defp sqlite_database_dir do
    case repo().query("PRAGMA database_list") do
      {:ok, %{rows: rows}} ->
        Enum.find_value(rows, fn
          [_seq, "main", file] when is_binary(file) and file != "" -> Path.dirname(file)
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
  end
end
