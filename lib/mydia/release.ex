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

  alias Mydia.DB

  @app :mydia
  @max_backups 10
  @docs_url "https://docs.mydia.dev/latest/using/how-to/backup-restore/"

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

  The file-copy strategy this module implements is only valid for SQLite, where
  the whole database is one file. On PostgreSQL no backup is taken and the
  operator is told so, loudly: Mydia deliberately does not shell out to
  `pg_dump`, which is not guaranteed to exist in the container, because an
  unreliable backup is worse than an honest absence of one.

  Set `SKIP_BACKUPS=true` to opt out entirely. Copying a multi-gigabyte SQLite
  file on every upgrade is a real cost, and some operators back up out of band.

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
        checkpoint_wal()
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
  Creates a timestamped backup of the database file.
  """
  def create_backup do
    with {:ok, db_path} <- get_database_path(),
         :ok <- ensure_database_exists(db_path),
         {:ok, backup_path} <- generate_backup_path(db_path),
         :ok <- copy_database(db_path, backup_path),
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

  defp warn_no_postgres_backup do
    Logger.warning("""
    Pending database migrations are about to run and NO BACKUP WAS TAKEN.

    Mydia's automatic pre-migration backup copies the SQLite database file, which
    has no PostgreSQL equivalent, and Mydia will not shell out to pg_dump because
    it is not guaranteed to be installed alongside the server.

    Back up your database before every upgrade:

        pg_dump -h HOST -U USER DBNAME > mydia_backup.sql

    If you have not, stop Mydia now and take one before it finishes starting.
    #{@docs_url}
    """)
  end

  # Production SQLite runs in WAL mode (see config/runtime.exs), so freshly
  # committed transactions can still live in the -wal sidecar file. Copying only
  # the .db would produce a backup that silently omits them. Folding the WAL back
  # into the main file first makes the copy self-contained.
  #
  # Keyed off the live repo's adapter rather than :database_adapter so a test
  # that forces the SQLite branch never issues this against a PostgreSQL repo.
  defp checkpoint_wal do
    if Mydia.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      Ecto.Adapters.SQL.query(Mydia.Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [])
    end

    :ok
  rescue
    error ->
      Logger.debug("WAL checkpoint before backup did not run: #{inspect(error)}")
      :ok
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

  defp copy_database(source, dest) do
    case File.cp(source, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:copy_failed, reason}}
    end
  end

  defp verify_backup(backup_path) do
    case File.stat(backup_path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        :ok

      {:ok, %File.Stat{size: 0}} ->
        {:error, :backup_empty}

      {:error, reason} ->
        {:error, {:backup_verify_failed, reason}}
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
