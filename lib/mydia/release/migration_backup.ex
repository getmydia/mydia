defmodule Mydia.Release.MigrationBackup do
  @moduledoc """
  Takes a database backup at boot, before `Ecto.Migrator` applies anything.

  Self-hosted operators upgrade Mydia by pulling a new image and restarting.
  Migrations then run unattended from the supervision tree, so the only moment a
  pre-migration backup can happen is during startup.

  This is a supervision child placed between `Mydia.Repo` and `Ecto.Migrator`:
  `init/1` needs a live repo to ask whether migrations are pending, and must
  finish before the migrator starts. It does its work synchronously in `init/1`
  and then returns `:ignore`, so no process lingers once the backup is done.

  ## Failure policy

  A failed backup logs loudly and startup continues. Refusing to boot would lock
  an operator out of their own instance for a condition they cannot fix from
  inside it (a full disk being the obvious one), and a container that will not
  start is a worse outage than a migration applied without a backup. The failure
  is logged at `:error` with an explicit statement that migrations are about to
  run unprotected, so it is never silent.

  Set `SKIP_BACKUPS=true` to opt out.
  """

  use GenServer

  require Logger

  alias Mydia.Release

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    run(opts)
    :ignore
  end

  @doc """
  Runs the pre-migration backup and reports what happened.

  Never raises: a backup is a safety net, not a boot requirement, so every
  failure mode is logged and swallowed here.

  ## Options

    * `:skip` - when true, migrations are not going to run either, so there is
      nothing to back up. Mirrors `Ecto.Migrator`'s option of the same name.
    * `:pending_migrations?` - forwarded to
      `Mydia.Release.backup_before_migrations/1`.
    * `:schema?` - forwarded to `Mydia.Release.backup_before_migrations/1`.
  """
  @spec run(keyword()) ::
          {:ok,
           String.t()
           | :no_migrations
           | :no_schema
           | :skipped
           | :unsupported_adapter
           | :migrations_skipped}
          | {:error, term()}
  def run(opts \\ []) do
    if Keyword.get(opts, :skip, false) do
      {:ok, :migrations_skipped}
    else
      backup(opts)
    end
  end

  defp backup(opts) do
    case Release.backup_before_migrations(opts) do
      {:error, reason} = error ->
        log_failure(reason)
        error

      {:ok, _} = ok ->
        ok
    end
  rescue
    error ->
      log_failure(error)
      {:error, error}
  catch
    kind, reason ->
      log_failure({kind, reason})
      {:error, {kind, reason}}
  end

  defp log_failure(reason) do
    Logger.error("""
    THE PRE-MIGRATION DATABASE BACKUP FAILED: #{explain(reason)}

    Mydia is continuing to start and WILL apply pending migrations without a
    backup. If a migration goes wrong there is no automatic snapshot to restore
    from.

    Stop Mydia now if you want to take one by hand first.

    https://docs.mydia.dev/latest/using/how-to/backup-restore/

    (#{inspect(reason)})
    """)
  end

  # Name what actually went wrong. "VACUUM INTO failed" tells an operator
  # nothing they can act on; "there was not enough free space" does.
  defp explain({:disk_full, path}) do
    "there was not enough free space to write #{path}. Free some disk beside the database and restart."
  end

  defp explain({:backup_path_unwritable, path, _message}) do
    "#{path} could not be opened for writing. Check that the directory exists and is writable by the user Mydia runs as."
  end

  defp explain({:backup_already_exists, path}) do
    "#{path} already exists and was not overwritten. Move or delete it and restart."
  end

  defp explain({:source_not_a_database, path}) do
    "#{path} is not a SQLite database file. Check DATABASE_PATH points at the right file."
  end

  defp explain({:database_not_found, path}) do
    "there is no database file at #{path}."
  end

  defp explain({:database_open_failed, path, _reason}) do
    "the database at #{path} could not be opened to snapshot it."
  end

  defp explain({:backup_empty, path}) do
    "#{path} was written but is empty."
  end

  defp explain({:backup_not_a_database, path}) do
    "#{path} was written but is not a valid SQLite database."
  end

  defp explain({:unsupported_adapter, adapter}) do
    "the automatic backup does not support #{adapter}."
  end

  defp explain(other), do: "the backup step failed with #{inspect(other)}."
end
