defmodule Mydia.ReleaseTest do
  use Mydia.DataCase, async: false

  alias Mydia.Release
  alias Mydia.SqliteFixtures

  @moduletag :capture_log

  @marker "row-committed-before-the-backup"

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "test_mydia_#{System.unique_integer([:positive])}.db"
      )

    # A real SQLite database in WAL mode with a live writer, because that is what
    # the backup runs against in production. The connection stays open for the
    # whole test: closing the last one checkpoints the WAL into the main file and
    # would quietly destroy the condition under test.
    conn = SqliteFixtures.create!(db_path)
    SqliteFixtures.insert!(conn, @marker)

    original_config = Application.get_env(:mydia, Mydia.Repo)
    original_adapter = Application.get_env(:mydia, :database_adapter)

    Application.put_env(:mydia, Mydia.Repo, Keyword.put(original_config, :database, db_path))

    # Forced so both the SQLite and the PostgreSQL CI job exercise this. Nothing
    # here touches Mydia.Repo: the backup opens its own connection to the file
    # above, so the adapter the suite happens to run under is irrelevant.
    Application.put_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3)

    on_exit(fn ->
      SqliteFixtures.close(conn)
      Application.put_env(:mydia, Mydia.Repo, original_config)
      Application.put_env(:mydia, :database_adapter, original_adapter)

      SqliteFixtures.cleanup(db_path)
      Enum.each(backups(db_path), &File.rm/1)
    end)

    {:ok, db_path: db_path, conn: conn}
  end

  defp backups(db_path) do
    basename = Path.basename(db_path, ".db")

    db_path
    |> Path.dirname()
    |> Path.join("#{basename}_backup_*.db")
    |> Path.wildcard()
  end

  describe "create_backup/0" do
    test "creates a timestamped backup file" do
      assert {:ok, backup_path} = Release.create_backup()
      assert File.exists?(backup_path)
      assert String.contains?(backup_path, "_backup_")
      assert String.ends_with?(backup_path, ".db")
    end

    test "the backup is a valid SQLite database, not merely a non-empty file" do
      assert {:ok, backup_path} = Release.create_backup()
      assert binary_part(File.read!(backup_path), 0, 16) == "SQLite format 3\0"
    end

    test "captures rows that are still only in the write-ahead log", %{db_path: db_path} do
      # The reason this uses VACUUM INTO rather than a file copy. The row is
      # committed, so it has to be in the backup, but it is sitting in the -wal
      # sidecar and is not in the main database file yet. A File.cp of the .db
      # would produce a backup that silently loses it.
      assert SqliteFixtures.wal_size(db_path) > 0
      refute File.read!(db_path) =~ @marker

      assert {:ok, backup_path} = Release.create_backup()

      assert SqliteFixtures.markers(backup_path) == [@marker]
    end

    test "captures rows committed after an earlier backup", %{db_path: db_path, conn: conn} do
      assert {:ok, first} = Release.create_backup()
      assert SqliteFixtures.markers(first) == [@marker]

      SqliteFixtures.insert!(conn, "a-later-row")
      Enum.each(backups(db_path), &File.rm/1)

      assert {:ok, second} = Release.create_backup()
      assert SqliteFixtures.markers(second) == ["a-later-row", @marker]
    end

    test "backup file is in the same directory as the original database", %{db_path: db_path} do
      assert {:ok, backup_path} = Release.create_backup()
      assert Path.dirname(backup_path) == Path.dirname(db_path)
    end

    test "returns error when database does not exist", %{db_path: db_path, conn: conn} do
      SqliteFixtures.close(conn)
      SqliteFixtures.cleanup(db_path)

      assert {:error, {:database_not_found, _}} = Release.create_backup()
    end

    test "returns error when the configured database is not a SQLite file", %{
      db_path: db_path,
      conn: conn
    } do
      SqliteFixtures.close(conn)
      SqliteFixtures.cleanup(db_path)
      File.write!(db_path, "this is not a database")

      assert {:error, {:source_not_a_database, ^db_path}} = Release.create_backup()
    end

    test "reports an unwritable backup target rather than a bare failure" do
      # A target the filesystem will not open. A read-only directory would be
      # the natural stand-in for the full-disk case, but chmod does not restrain
      # root and CI containers sometimes run as one. An over-long name is
      # refused for everybody. 240 is chosen so the source and its -wal sidecar
      # stay inside NAME_MAX (255) while the generated backup name, which adds
      # "_backup_YYYYMMDD_HHMMSS", does not.
      dir = Path.join(System.tmp_dir!(), "long_name_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      long_db = Path.join(dir, String.duplicate("n", 240) <> ".db")
      conn = SqliteFixtures.create!(long_db)

      original = Application.get_env(:mydia, Mydia.Repo)
      Application.put_env(:mydia, Mydia.Repo, Keyword.put(original, :database, long_db))

      on_exit(fn ->
        SqliteFixtures.close(conn)
        Application.put_env(:mydia, Mydia.Repo, original)
        File.rm_rf!(dir)
      end)

      assert {:error, {:backup_path_unwritable, _path, _message}} = Release.create_backup()
    end

    test "refuses to run against a non-SQLite adapter" do
      Application.put_env(:mydia, :database_adapter, Ecto.Adapters.Postgres)

      assert {:error, {:unsupported_adapter, :postgres}} = Release.create_backup()
    end
  end

  describe "create_backup/0 called twice in the same second" do
    test "reuses the existing snapshot instead of failing on the collision", %{db_path: db_path} do
      # Backup filenames are stamped to the second and VACUUM INTO refuses to
      # overwrite its target, so a second caller in the same boot would fail
      # without the reuse path. Aligning to a second boundary leaves the best
      # part of a second for two snapshots of a tiny database, so both calls
      # land on the same stamp.
      align_to_second_boundary()

      assert {:ok, first} = Release.create_backup()
      assert {:ok, second} = Release.create_backup()

      assert second == first
      assert length(backups(db_path)) == 1
      assert SqliteFixtures.markers(first) == [@marker]
    end
  end

  describe "cleanup_old_backups" do
    test "keeps only the 10 most recent backups", %{db_path: db_path} do
      # Seeded directly rather than by taking 12 real backups: filenames are
      # stamped to the second, so real ones would need 12 seconds of sleeping
      # to be distinct.
      basename = Path.basename(db_path, ".db")
      dir = Path.dirname(db_path)

      for i <- 1..12 do
        stamp = String.pad_leading("#{i}", 2, "0")
        File.write!(Path.join(dir, "#{basename}_backup_20240101_0000#{stamp}.db"), "old")
      end

      assert length(backups(db_path)) == 12

      assert {:ok, newest} = Release.create_backup()

      remaining = backups(db_path)
      assert length(remaining) == 10
      assert newest in remaining
    end
  end

  describe "get_database_path" do
    test "returns the configured database path" do
      assert is_binary(Application.get_env(:mydia, Mydia.Repo)[:database])
    end
  end

  describe "schema?/0" do
    test "is true against the migrated test repo" do
      assert Release.schema?() == true
    end
  end

  defp align_to_second_boundary do
    Process.sleep(1000 - rem(System.os_time(:millisecond), 1000))
  end
end
