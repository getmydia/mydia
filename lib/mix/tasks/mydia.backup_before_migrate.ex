defmodule Mix.Tasks.Mydia.BackupBeforeMigrate do
  @moduledoc """
  Creates a timestamped database backup if there are pending migrations.

  This task backs up the development database from the dev shell. Release builds
  do not use it: they back up from the supervision tree via
  `Mydia.Release.MigrationBackup`, which runs before `Ecto.Migrator`.

  It will:
  1. Check if there are pending migrations
  2. If yes, create a timestamped backup of the database (SQLite only)
  3. Clean up old backups (keeping the last 10)
  4. Exit with status 0 if successful, 1 if failed

  ## Examples

      mix mydia.backup_before_migrate

  """
  use Mix.Task

  @shortdoc "Creates a database backup if there are pending migrations"

  @impl Mix.Task
  def run(_args) do
    # Start the application to load configuration
    Mix.Task.run("app.start")

    case Mydia.Release.backup_before_migrations() do
      {:ok, backup_path} when is_binary(backup_path) ->
        Mix.shell().info("✓ Database backup created: #{backup_path}")
        :ok

      {:ok, :no_migrations} ->
        Mix.shell().info("✓ No pending migrations, skipping backup")
        :ok

      {:ok, :skipped} ->
        Mix.shell().info("✓ SKIP_BACKUPS is set, no backup taken")
        :ok

      {:ok, :unsupported_adapter} ->
        Mix.shell().info("✓ PostgreSQL: no automatic backup, see the logged warning")
        :ok

      {:error, reason} ->
        Mix.shell().error("✗ Failed to create backup: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
