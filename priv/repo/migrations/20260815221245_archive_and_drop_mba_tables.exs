defmodule Mydia.Repo.Migrations.ArchiveAndDropMbaTables do
  @moduledoc """
  Removes the music, books, and adult verticals.

  Archives every table that still holds rows to NDJSON BEFORE dropping
  anything, and aborts without dropping if archival fails.

  library_paths rows of the removed types are CONVERTED to :mixed and left
  unmonitored, never deleted. media_files.library_path_id is on_delete:
  :delete_all, so deleting those rows would cascade into real user media: adult
  content lived in the shared media_files table, and music and book downloads
  left media_files rows behind with no parent at all.

  They are unmonitored rather than disabled so the operator can still see them
  on the Library Paths screen and decide what to do with them. A disabled path
  is filtered out of Mydia.Settings.list_library_paths/1 and never reaches the
  UI at all, which would hide the conversion entirely.

  Monitoring must stay off. A :mixed scan collects video extensions only, and
  Scanner.detect_changes/3 classifies every existing media_file the scan did not
  find as deleted, which sends it through Library.trash_media_file/1 and moves
  the bytes into the trash store. Monitoring a music, book, or image directory
  as :mixed would therefore move its contents out from under the operator. The
  safe resolutions are to remove the library path or repoint it at video
  content.
  """
  use Ecto.Migration

  require Logger

  alias Mydia.Release.TableArchive
  alias Mydia.Repo.Migrations.Helpers

  # Declared volumes in the official image. /config is reached through the
  # SQLite database path rather than named here, because a PostgreSQL
  # deployment has nothing in it.
  @volume_data_dir "/data"

  # Inside the release, replaced by the next image pull.
  @release_data_dir "priv/data"

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
    dir = archive_dir()

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
          message: """
          Refusing to drop music/books/adult tables: archival failed with #{inspect(reason)}
          while writing to:
            #{dir}
          The tables were left in place and nothing was deleted. Set MYDIA_DATA_DIR
          to a directory this instance can write to, then start it again to retry
          the upgrade.
          """
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
         SET type = 'mixed', monitored = #{Helpers.to_db_value(false)}
       WHERE type IN ('music', 'books', 'adult')
      """)

    if converted > 0 do
      Logger.warning("""
      [MBA removal] Converted #{converted} music/books/adult library path(s) to
      type 'mixed' and stopped monitoring them. Their media files were NOT
      touched. These directories hold media Mydia no longer indexes, so leave
      them unmonitored: a monitored 'mixed' library scans for video files only,
      and every other file in the directory would be treated as deleted and
      moved to the trash store. They are still listed under Settings > Library
      Paths. Remove the library path there, or point it at video content.
      """)
    end
  end

  # An archive is only worth writing where the operator can still find it after
  # the upgrade that wrote it, and only worth attempting where it can actually
  # be created. Candidates are tried in order and the first one that accepts the
  # directory wins.
  #
  # Resolution itself never raises. If no candidate accepts it, the last one is
  # returned anyway so the failure surfaces through TableArchive as a refusal to
  # drop, rather than as an exception from this function.
  defp archive_dir do
    leaf = Path.join("archives", "mba-#{timestamp()}")
    candidates = data_dir_candidates()

    created =
      Enum.find_value(candidates, fn root ->
        dir = Path.join(root, leaf)
        if File.mkdir_p(dir) == :ok, do: dir
      end)

    created || Path.join(List.last(candidates), leaf)
  end

  defp data_dir_candidates do
    __data_dir_candidates__(if Helpers.sqlite?(), do: sqlite_database_dir())
  end

  # Public so the ordering can be asserted directly, including the PostgreSQL
  # case (a nil database directory), which cannot be reached through a migration
  # test: the throwaway repo in Mydia.MigrationCase is always SQLite.
  @doc false
  def __data_dir_candidates__(sqlite_database_dir) do
    [
      # 1. What the operator configured. Explicit intent beats any location this
      #    code could infer, on either adapter.
      configured_data_dir(),
      # 2. On SQLite, the directory holding the database file: durable by
      #    construction (/config in the official image, a declared volume) and
      #    provably writable, since the migration is writing to the database
      #    sitting in it. nil on PostgreSQL, which has no local anchor.
      sqlite_database_dir,
      # 3. The image's other declared volume, and only when it already exists,
      #    so a migration running as root on a bare-metal host never creates a
      #    stray /data at the filesystem root.
      if(File.dir?(@volume_data_dir), do: @volume_data_dir),
      # 4. The release's own data directory. An image pull replaces it, so an
      #    archive here does not survive the next upgrade: last resort, never
      #    the default.
      @release_data_dir
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp configured_data_dir do
    case System.get_env("MYDIA_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
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
