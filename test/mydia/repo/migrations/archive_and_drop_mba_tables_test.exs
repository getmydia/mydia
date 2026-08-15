defmodule Mydia.Repo.Migrations.ArchiveAndDropMbaTablesTest do
  @moduledoc """
  Runs the real migration against a throwaway database.

  The sibling `mba_removal_test.exs` describes the world after the suite's own
  database has been migrated. This one drives `up/0` itself, so it can prove the
  two properties that matter: rows reach the archive before the tables holding
  them are dropped, and a music library path is converted rather than deleted
  while a media_files row hangs off it through an ON DELETE CASCADE foreign key.
  """
  use Mydia.MigrationCase

  Code.require_file("priv/repo/migrations/20260815221245_archive_and_drop_mba_tables.exs")

  @migration Mydia.Repo.Migrations.ArchiveAndDropMbaTables
  @version 20_260_815_221_245

  @dropped ~w(playlist_tracks music_files playlists tracks albums artists
              book_files books authors adult_files scenes studios)

  # Only the shape that matters is recreated here: the library_paths row the
  # migration converts, and the media_files row that a delete would take with
  # it. The cascade is the real one from
  # 20251114212620_add_relative_path_columns_to_media_files.exs, and
  # Mydia.MigrationCase starts the repo with foreign keys enforced.
  defp build_library_schema do
    sql!("""
    CREATE TABLE library_paths (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL,
      type TEXT NOT NULL,
      disabled INTEGER NOT NULL DEFAULT 0
    )
    """)

    sql!("""
    CREATE TABLE media_files (
      id TEXT PRIMARY KEY,
      relative_path TEXT NOT NULL,
      library_path_id TEXT REFERENCES library_paths(id) ON DELETE CASCADE
    )
    """)
  end

  defp build_music_schema do
    sql!("CREATE TABLE artists (id TEXT PRIMARY KEY, name TEXT NOT NULL)")

    sql!("""
    CREATE TABLE albums (
      id TEXT PRIMARY KEY,
      title TEXT,
      artist_id TEXT NOT NULL REFERENCES artists(id) ON DELETE CASCADE
    )
    """)

    sql!("""
    CREATE TABLE tracks (
      id TEXT PRIMARY KEY,
      title TEXT,
      album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE
    )
    """)
  end

  # The migration writes beside the database file on SQLite, which under
  # Mydia.MigrationCase is the test's own temp directory.
  defp archive_dir(tmp_dir) do
    case Path.wildcard(Path.join([tmp_dir, "archives", "mba-*"])) do
      [dir] -> dir
      other -> flunk("expected exactly one archive directory, got #{inspect(other)}")
    end
  end

  defp ndjson(dir, table) do
    dir
    |> Path.join("#{table}.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @tag :tmp_dir
  test "archives every row before dropping the tables that held them", %{tmp_dir: tmp_dir} do
    build_library_schema()
    build_music_schema()

    # Neither name is exactly 16 bytes long: Mydia.Release.TableArchive reads
    # any 16-byte binary as a PostgreSQL binary_id and rewrites it as a UUID
    # string, which mangles text of that length coming out of SQLite.
    sql!("INSERT INTO artists (id, name) VALUES ('a1', 'Portishead'), ('a2', 'Autechre')")
    sql!("INSERT INTO albums (id, title, artist_id) VALUES ('b1', 'Dummy', 'a1')")

    run_migration!(@migration, @version)

    dir = archive_dir(tmp_dir)

    assert [%{"id" => "a1", "name" => "Portishead"}, %{"id" => "a2", "name" => "Autechre"}] =
             Enum.sort_by(ndjson(dir, "artists"), & &1["id"])

    assert [%{"id" => "b1", "title" => "Dummy", "artist_id" => "a1"}] = ndjson(dir, "albums")

    # tracks existed but was empty, so it is skipped rather than archived empty.
    refute File.exists?(Path.join(dir, "tracks.ndjson"))

    for table <- @dropped do
      assert {:error, _} = Mydia.MigrationTestRepo.query(~s(SELECT 1 FROM "#{table}" LIMIT 1))
    end
  end

  @tag :tmp_dir
  test "converts a music library path instead of deleting it" do
    build_library_schema()
    build_music_schema()

    sql!("INSERT INTO library_paths (id, path, type) VALUES ('lp1', '/media/music', 'music')")
    sql!("INSERT INTO library_paths (id, path, type) VALUES ('lp2', '/media/movies', 'movies')")

    sql!("""
    INSERT INTO media_files (id, relative_path, library_path_id)
    VALUES ('mf1', 'song.flac', 'lp1'), ('mf2', 'film.mkv', 'lp2')
    """)

    run_migration!(@migration, @version)

    assert %{rows: [["mixed", 1]]} =
             sql!("SELECT type, disabled FROM library_paths WHERE id = 'lp1'")

    assert %{rows: [["movies", 0]]} =
             sql!("SELECT type, disabled FROM library_paths WHERE id = 'lp2'")

    # The point of the whole exercise: the cascade never fired.
    assert %{rows: [["mf1"], ["mf2"]]} = sql!("SELECT id FROM media_files ORDER BY id")
  end

  @tag :tmp_dir
  test "runs on a database that never had the tables and writes nothing", %{tmp_dir: tmp_dir} do
    build_library_schema()

    run_migration!(@migration, @version)

    refute File.exists?(Path.join(tmp_dir, "archives"))
  end
end
