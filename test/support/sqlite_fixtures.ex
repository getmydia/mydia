defmodule Mydia.SqliteFixtures do
  @moduledoc """
  Throwaway SQLite database files for tests that exercise Mydia's file-level
  database operations, meaning the pre-migration backup.

  Deliberately always SQLite, even when the suite runs against PostgreSQL,
  because the behaviour under test is SQLite-specific. Same reasoning as
  `Mydia.MigrationTestRepo`.

  Databases are created in write-ahead-log mode, matching production
  (`config/runtime.exs`). That matters: a backup taken while committed rows are
  still sitting in the `-wal` sidecar has to include them, and only a database
  in WAL mode with a live connection can put a test in that state.
  """

  alias Exqlite.Sqlite3

  @table "backup_probe"

  @doc """
  Creates a WAL-mode database at `path` with a single `#{@table}` table.

  Returns the open connection. Keep it open: closing the last connection to a
  SQLite database checkpoints the WAL into the main file, which is exactly the
  condition a test wants to avoid reproducing by accident. Production keeps the
  repo pool open for the same reason.
  """
  @spec create!(String.t()) :: Sqlite3.db()
  def create!(path) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(conn, "CREATE TABLE #{@table} (marker TEXT NOT NULL)")
    conn
  end

  @doc """
  Commits `marker` through `conn`, leaving it in the write-ahead log.
  """
  @spec insert!(Sqlite3.db(), String.t()) :: :ok
  def insert!(conn, marker) do
    :ok = Sqlite3.execute(conn, "INSERT INTO #{@table} VALUES ('#{marker}')")
  end

  @doc """
  Reads every marker out of the database at `path` using a fresh connection.

  Used to assert against a backup, which is a standalone database file.
  """
  @spec markers(String.t()) :: [String.t()]
  def markers(path) do
    {:ok, conn} = Sqlite3.open(path, mode: [:readonly])

    try do
      {:ok, statement} = Sqlite3.prepare(conn, "SELECT marker FROM #{@table} ORDER BY marker")
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      List.flatten(rows)
    after
      Sqlite3.close(conn)
    end
  end

  @doc """
  Size of the `-wal` sidecar beside `path`, or 0 when there is none.
  """
  @spec wal_size(String.t()) :: non_neg_integer()
  def wal_size(path) do
    case File.stat(path <> "-wal") do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> 0
    end
  end

  @doc """
  Closes a connection returned by `create!/1`.
  """
  @spec close(Sqlite3.db()) :: :ok
  def close(conn), do: Sqlite3.close(conn)

  @doc """
  Removes a fixture database and its WAL sidecars.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(path) do
    Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    :ok
  end
end
