defmodule Mix.Tasks.Mydia.BackupBeforeMigrate do
  @moduledoc """
  Creates a timestamped database backup if there are pending migrations.

  This task backs up the development database from the dev shell. Release builds
  do not use it: they back up from the supervision tree via
  `Mydia.Release.MigrationBackup`, which runs before `Ecto.Migrator`.

  It will:
  1. Start only `Mydia.Repo`, never the full supervision tree
  2. Check if there are pending migrations
  3. If the database already has applied migrations, create a timestamped
     backup of it (SQLite only)
  4. Clean up old backups (keeping the last 10)
  5. Exit with status 0 if successful, 1 if failed

  ## Examples

      mix mydia.backup_before_migrate

  """
  use Mix.Task

  @shortdoc "Creates a database backup if there are pending migrations"

  @impl Mix.Task
  def run(_args) do
    # Load configuration WITHOUT booting the supervision tree.
    #
    # `app.start` here was fatal on a fresh database: ClientHealth.init/1 queries
    # download_client_configs synchronously, so the boot died with "no such
    # table", took the surrounding `ecto.create && … && ecto.migrate` chain down
    # with it, and left the database permanently unmigrated. A backup needs the
    # repo and nothing else, so start exactly that.
    Mix.Task.run("app.config")

    case Ecto.Migrator.with_repo(Mydia.Repo, fn _repo ->
           Mydia.Release.backup_before_migrations()
         end) do
      {:ok, result, _started_apps} -> report(result)
      {:error, reason} -> report({:error, {:repo_not_started, reason}})
    end
  end

  defp report({:ok, backup_path}) when is_binary(backup_path) do
    Mix.shell().info("✓ Database backup created: #{backup_path}")
  end

  defp report({:ok, :no_migrations}) do
    Mix.shell().info("✓ No pending migrations, skipping backup")
  end

  defp report({:ok, :no_schema}) do
    Mix.shell().info("✓ Database has no applied migrations yet, nothing to back up")
  end

  defp report({:ok, :skipped}) do
    Mix.shell().info("✓ SKIP_BACKUPS is set, no backup taken")
  end

  defp report({:ok, :unsupported_adapter}) do
    Mix.shell().info("✓ PostgreSQL: no automatic backup, see the logged warning")
  end

  defp report({:error, reason}) do
    Mix.shell().error("✗ Failed to create backup: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
