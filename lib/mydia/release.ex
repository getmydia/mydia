defmodule Mydia.Release do
  @moduledoc """
  Database backup and migration utilities for release management.

  This module provides functions for:
  - Running database migrations
  - Checking for pending migrations
  - Creating timestamped database backups before migrations
  - Cleaning up old backup files

  `backup_before_migrations/1` is the entry point used both by the dev shell
  (`mix mydia.backup_before_migrate`) and by the release boot path
  (`Mydia.Release.MigrationBackup`, a supervision child that runs between
  `Mydia.Repo` and `Ecto.Migrator`).
  """

  require Logger

  alias Exqlite.Sqlite3
  alias Mydia.DB

  @app :mydia
  @max_backups 10
  @docs_url "https://docs.mydia.dev/latest/using/how-to/backup-restore/"

  # The magic string every SQLite database file starts with, used to verify a
  # backup is a real database rather than an empty or truncated file.
  @sqlite_header "SQLite format 3\0"

  @doc """
  Runs pending database migrations.

  This is the standard function called by release scripts and entrypoints
  to ensure the database schema is up to date.

  Takes the same pre-migration backup the supervision tree takes on container
  boot. `eval` callers (the NixOS unit runs this from `ExecStartPre`) never reach
  the supervision tree, so without this they would migrate unprotected.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Mydia.Release.MigrationBackup.run()
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  @doc """
  Rolls back the last migration.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  @doc """
  Creates a database backup if there are pending migrations.

  The `VACUUM INTO` snapshot this module takes is only valid for SQLite, where
  the whole database is one file. On PostgreSQL no backup is taken and the
  operator is told so, loudly: Mydia deliberately does not shell out to
  `pg_dump`, which is not guaranteed to exist in the container, because an
  unreliable backup is worse than an honest absence of one.

  Set `SKIP_BACKUPS=true` to opt out entirely. Snapshotting a multi-gigabyte
  SQLite database on every upgrade is a real cost, and some operators back up
  out of band.

  ## Options

    * `:pending_migrations?` - override the pending-migration check. Defaults to
      `pending_migrations?/0`. Exists so the boot path and its tests can decide
      migration status without a live migration being pending.

  ## Returns

    * `{:ok, backup_path}` - a backup was written
    * `{:ok, :no_migrations}` - nothing is pending, so nothing was backed up
    * `{:ok, :skipped}` - `SKIP_BACKUPS` is set
    * `{:ok, :unsupported_adapter}` - PostgreSQL, operator warned
    * `{:error, reason}` - the backup was attempted and failed
  """
  @spec backup_before_migrations(keyword()) ::
          {:ok, String.t() | :no_migrations | :skipped | :unsupported_adapter} | {:error, term()}
  def backup_before_migrations(opts \\ []) do
    cond do
      skip_backups?() ->
        Logger.info(
          "SKIP_BACKUPS is set, so no pre-migration database backup will be taken. " <>
            "Back up before upgrading: #{@docs_url}"
        )

        {:ok, :skipped}

      not Keyword.get_lazy(opts, :pending_migrations?, &pending_migrations?/0) ->
        Logger.info("No pending migrations detected, skipping backup")
        {:ok, :no_migrations}

      DB.sqlite?() ->
        create_backup()

      true ->
        warn_no_postgres_backup()
        {:ok, :unsupported_adapter}
    end
  end

  @doc """
  Returns true when the operator has opted out of automatic backups via
  `SKIP_BACKUPS`.
  """
  @spec skip_backups?() :: boolean()
  def skip_backups? do
    Mydia.Settings.parse_setting_boolean(System.get_env("SKIP_BACKUPS"))
  end

  @doc """
  Checks if there are pending migrations.
  """
  def pending_migrations? do
    repos = Application.get_env(@app, :ecto_repos, [])

    Enum.any?(repos, fn repo ->
      versions = Ecto.Migrator.migrations(repo)

      Enum.any?(versions, fn {status, _version, _name} ->
        status == :down
      end)
    end)
  end

  @doc """
  Creates a timestamped snapshot of the SQLite database.

  Uses SQLite's `VACUUM INTO`, which writes a consistent, self-contained copy of
  the database in one statement. A plain file copy is not good enough here:
  production runs in WAL mode (see `config/runtime.exs`), so committed
  transactions can still be sitting in the `-wal` sidecar, and copying only the
  main file yields a backup that is silently short of where the database
  actually was. `VACUUM INTO` reads through the WAL, cannot produce a torn file,
  and compacts the result as a side effect.

  SQLite only, and refuses to run under any other adapter.
  """
  @spec create_backup() :: {:ok, String.t()} | {:error, term()}
  def create_backup do
    with :ok <- ensure_sqlite(),
         {:ok, db_path} <- get_database_path(),
         :ok <- ensure_database_exists(db_path),
         {:ok, backup_path} <- generate_backup_path(db_path),
         :ok <- write_backup(db_path, backup_path),
         :ok <- verify_backup(backup_path) do
      Logger.info("Created database backup: #{backup_path}")
      cleanup_old_backups(db_path)
      {:ok, backup_path}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create database backup: #{inspect(reason)}")
        error
    end
  end

  # Private functions

  defp ensure_sqlite do
    if DB.sqlite?() do
      :ok
    else
      {:error, {:unsupported_adapter, DB.adapter_type()}}
    end
  end

  # `VACUUM INTO` refuses to overwrite its target, and more than one caller can
  # ask for a backup in a single boot: the NixOS unit migrates from
  # ExecStartPre, then the supervision child looks again when the server starts.
  # A file already stamped for this second is the one we would have written, so
  # reusing it makes the whole operation idempotent instead of turning a
  # duplicate call into a scary failure.
  defp write_backup(db_path, backup_path) do
    if File.exists?(backup_path) do
      Logger.info("Database backup for this timestamp already exists: #{backup_path}")
      :ok
    else
      vacuum_into(db_path, backup_path)
    end
  end

  defp vacuum_into(db_path, backup_path) do
    # A dedicated connection, not the repo pool: `VACUUM INTO` cannot run inside
    # a transaction or with statements in progress, and the backup has to work
    # from any process regardless of connection ownership. A second connection
    # to a WAL database sees everything the pool has committed.
    case Sqlite3.open(db_path, mode: [:readwrite]) do
      {:ok, conn} ->
        try do
          conn
          |> Sqlite3.execute("VACUUM INTO '#{escape_sql_string(backup_path)}'")
          |> classify_vacuum(db_path, backup_path)
        after
          Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, {:database_open_failed, db_path, reason}}
    end
  end

  # The path comes from configuration rather than user input, but a literal is
  # the only way to pass it to VACUUM INTO through `execute/2`, so quote it
  # properly rather than assuming.
  defp escape_sql_string(value), do: String.replace(value, "'", "''")

  defp classify_vacuum(:ok, _db_path, _backup_path), do: :ok

  defp classify_vacuum({:error, message}, db_path, backup_path) when is_binary(message) do
    cond do
      message =~ "output file already exists" ->
        {:error, {:backup_already_exists, backup_path}}

      message =~ "disk is full" or message =~ "database or disk is full" ->
        {:error, {:disk_full, backup_path}}

      message =~ "unable to open database" or message =~ "readonly" ->
        {:error, {:backup_path_unwritable, backup_path, message}}

      message =~ "not a database" or message =~ "file is encrypted" ->
        {:error, {:source_not_a_database, db_path}}

      true ->
        {:error, {:vacuum_failed, message}}
    end
  end

  defp classify_vacuum({:error, reason}, _db_path, _backup_path),
    do: {:error, {:vacuum_failed, reason}}

  defp warn_no_postgres_backup do
    Logger.warning("""
    Pending database migrations are about to run and NO BACKUP WAS TAKEN.

    Mydia's automatic pre-migration backup snapshots the SQLite database with
    VACUUM INTO, which has no PostgreSQL equivalent, and Mydia will not shell out
    to pg_dump because it is not guaranteed to be installed alongside the server.

    Back up your database before every upgrade:

        pg_dump -h HOST -U USER DBNAME > mydia_backup.sql

    If you have not, stop Mydia now and take one before it finishes starting.
    #{@docs_url}
    """)
  end

  defp get_database_path do
    case Application.get_env(@app, Mydia.Repo)[:database] do
      nil ->
        {:error, :no_database_configured}

      path when is_binary(path) ->
        {:ok, path}

      path ->
        {:error, {:invalid_database_path, path}}
    end
  end

  defp ensure_database_exists(db_path) do
    if File.exists?(db_path) do
      :ok
    else
      {:error, {:database_not_found, db_path}}
    end
  end

  defp generate_backup_path(db_path) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    dir = Path.dirname(db_path)
    basename = Path.basename(db_path, ".db")
    backup_name = "#{basename}_backup_#{timestamp}.db"
    backup_path = Path.join(dir, backup_name)

    {:ok, backup_path}
  end

  # Every SQLite database begins with the same 16 byte magic string. Reading it
  # back proves the file on disk is a database and not a truncated or empty
  # result, which a size check alone cannot tell you.
  defp verify_backup(backup_path) do
    case File.open(backup_path, [:read, :binary], &IO.binread(&1, byte_size(@sqlite_header))) do
      {:ok, @sqlite_header} ->
        :ok

      {:ok, :eof} ->
        {:error, {:backup_empty, backup_path}}

      {:ok, _unexpected} ->
        {:error, {:backup_not_a_database, backup_path}}

      {:error, reason} ->
        {:error, {:backup_verify_failed, backup_path, reason}}
    end
  end

  defp cleanup_old_backups(db_path) do
    # Get the base name of the database file (without extension)
    basename = Path.basename(db_path, ".db")
    dir = Path.dirname(db_path)
    backup_pattern = Path.join(dir, "#{basename}_backup_*.db")

    backup_pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.drop(@max_backups)
    |> Enum.each(fn old_backup ->
      case File.rm(old_backup) do
        :ok ->
          Logger.info("Cleaned up old backup: #{old_backup}")

        {:error, reason} ->
          Logger.warning("Failed to remove old backup #{old_backup}: #{inspect(reason)}")
      end
    end)
  end
end
