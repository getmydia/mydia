defmodule Mydia.Release.MigrationBackupTest do
  # async: false because these tests override application environment
  # (the repo's :database path and :database_adapter) and the SKIP_BACKUPS
  # environment variable, all of which are global.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Release.MigrationBackup
  alias Mydia.SqliteFixtures

  @moduletag :capture_log

  @marker "row-committed-before-the-backup"

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "test_migration_backup_#{System.unique_integer([:positive])}.db"
      )

    # A real WAL-mode database with a live writer, matching production. The
    # backup opens its own connection to this file and never touches Mydia.Repo.
    conn = SqliteFixtures.create!(db_path)
    SqliteFixtures.insert!(conn, @marker)

    original_repo_config = Application.get_env(:mydia, Mydia.Repo)
    original_adapter = Application.get_env(:mydia, :database_adapter)
    original_skip = System.get_env("SKIP_BACKUPS")

    Application.put_env(
      :mydia,
      Mydia.Repo,
      Keyword.put(original_repo_config, :database, db_path)
    )

    on_exit(fn ->
      SqliteFixtures.close(conn)
      Application.put_env(:mydia, Mydia.Repo, original_repo_config)
      Application.put_env(:mydia, :database_adapter, original_adapter)

      if original_skip do
        System.put_env("SKIP_BACKUPS", original_skip)
      else
        System.delete_env("SKIP_BACKUPS")
      end

      SqliteFixtures.cleanup(db_path)
      Enum.each(backups(db_path), &File.rm/1)
    end)

    {:ok, db_path: db_path, conn: conn}
  end

  # The adapter is forced explicitly in every test so both the SQLite and the
  # PostgreSQL CI job exercise both branches. Nothing here queries the database,
  # so the forced value never has to match the repo actually running.
  defp force_adapter(adapter) do
    Application.put_env(:mydia, :database_adapter, adapter)
  end

  defp backups(db_path) do
    basename = Path.basename(db_path, ".db")

    db_path
    |> Path.dirname()
    |> Path.join("#{basename}_backup_*.db")
    |> Path.wildcard()
  end

  describe "run/1 on SQLite" do
    test "creates a backup when migrations are pending", %{db_path: db_path} do
      force_adapter(Ecto.Adapters.SQLite3)

      assert {:ok, backup_path} = MigrationBackup.run(pending_migrations?: true)

      assert is_binary(backup_path)
      assert File.exists?(backup_path)
      assert SqliteFixtures.markers(backup_path) == [@marker]
      assert Path.dirname(backup_path) == Path.dirname(db_path)
    end

    test "backs up nothing when no migrations are pending", %{db_path: db_path} do
      force_adapter(Ecto.Adapters.SQLite3)

      assert {:ok, :no_migrations} = MigrationBackup.run(pending_migrations?: false)
      assert backups(db_path) == []
    end
  end

  describe "run/1 on PostgreSQL" do
    test "takes no backup and tells the operator to take one", %{db_path: db_path} do
      force_adapter(Ecto.Adapters.Postgres)

      log =
        capture_log(fn ->
          assert {:ok, :unsupported_adapter} = MigrationBackup.run(pending_migrations?: true)
        end)

      assert backups(db_path) == []
      assert log =~ "NO BACKUP WAS TAKEN"
      assert log =~ "pg_dump"
      assert log =~ "docs.mydia.dev"
    end

    test "stays quiet when no migrations are pending", %{db_path: db_path} do
      force_adapter(Ecto.Adapters.Postgres)

      log =
        capture_log(fn ->
          assert {:ok, :no_migrations} = MigrationBackup.run(pending_migrations?: false)
        end)

      assert backups(db_path) == []
      refute log =~ "NO BACKUP WAS TAKEN"
    end
  end

  describe "SKIP_BACKUPS" do
    setup do
      force_adapter(Ecto.Adapters.SQLite3)
      :ok
    end

    for value <- ["true", "1", "yes", "on"] do
      test "#{value} suppresses the backup", %{db_path: db_path} do
        System.put_env("SKIP_BACKUPS", unquote(value))

        assert {:ok, :skipped} = MigrationBackup.run(pending_migrations?: true)
        assert backups(db_path) == []
      end
    end

    test "false does not suppress the backup" do
      System.put_env("SKIP_BACKUPS", "false")

      assert {:ok, backup_path} = MigrationBackup.run(pending_migrations?: true)
      assert File.exists?(backup_path)
    end

    test "unset does not suppress the backup" do
      System.delete_env("SKIP_BACKUPS")

      assert {:ok, backup_path} = MigrationBackup.run(pending_migrations?: true)
      assert File.exists?(backup_path)
    end
  end

  describe "run/1 when migrations are skipped" do
    test "does no work at all", %{db_path: db_path} do
      force_adapter(Ecto.Adapters.SQLite3)

      assert {:ok, :migrations_skipped} =
               MigrationBackup.run(skip: true, pending_migrations?: true)

      assert backups(db_path) == []
    end
  end

  describe "a failed backup" do
    setup %{db_path: db_path, conn: conn} do
      force_adapter(Ecto.Adapters.SQLite3)
      # Nothing to snapshot: the closest deterministic stand-in for a backup
      # that cannot be written.
      SqliteFixtures.close(conn)
      SqliteFixtures.cleanup(db_path)
      :ok
    end

    test "reports the error and says migrations will run unprotected" do
      log =
        capture_log(fn ->
          assert {:error, {:database_not_found, _}} =
                   MigrationBackup.run(pending_migrations?: true)
        end)

      assert log =~ "THE PRE-MIGRATION DATABASE BACKUP FAILED"
      assert log =~ "WILL apply pending migrations without a"
      # Names the cause instead of dumping a tuple at the operator.
      assert log =~ "there is no database file at"
    end

    test "does not stop the boot: init/1 still returns :ignore" do
      assert capture_log(fn ->
               assert :ignore = MigrationBackup.init(pending_migrations?: true)
             end) =~ "THE PRE-MIGRATION DATABASE BACKUP FAILED"
    end

    test "does not stop the boot: the supervisor still starts" do
      capture_log(fn ->
        assert {:ok, sup} =
                 Supervisor.start_link(
                   [{MigrationBackup, pending_migrations?: true}],
                   strategy: :one_for_one
                 )

        Supervisor.stop(sup)
      end)
    end
  end

  describe "as a supervision child" do
    test "starts, does its work, and leaves no process behind" do
      assert {:ok, sup} =
               Supervisor.start_link([{MigrationBackup, skip: true}], strategy: :one_for_one)

      assert [{MigrationBackup, :undefined, _, _}] = Supervisor.which_children(sup)
      refute Process.whereis(MigrationBackup)

      Supervisor.stop(sup)
    end
  end

  describe "init/1" do
    test "returns :ignore after a successful backup so no process lingers" do
      force_adapter(Ecto.Adapters.SQLite3)

      assert :ignore = MigrationBackup.init(pending_migrations?: true)
    end

    test "returns :ignore when migrations are skipped" do
      assert :ignore = MigrationBackup.init(skip: true)
    end
  end
end
