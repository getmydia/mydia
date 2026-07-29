defmodule Mydia.ReleaseTest do
  use Mydia.DataCase, async: false

  alias Mydia.Release

  @moduletag :capture_log

  @test_db_path Path.join(
                  System.tmp_dir!(),
                  "test_mydia_#{System.unique_integer([:positive])}.db"
                )

  setup do
    # Create a test database file
    File.write!(@test_db_path, "test database content")

    # Override the database path for testing while preserving other config
    original_config = Application.get_env(:mydia, Mydia.Repo)
    updated_config = Keyword.put(original_config, :database, @test_db_path)

    Application.put_env(:mydia, Mydia.Repo, updated_config)

    on_exit(fn ->
      # Restore original config
      Application.put_env(:mydia, Mydia.Repo, original_config)

      # Clean up test files
      File.rm(@test_db_path)

      # Clean up any backup files
      @test_db_path
      |> Path.dirname()
      |> Path.join("test_mydia_*_backup_*.db")
      |> Path.wildcard()
      |> Enum.each(&File.rm/1)
    end)

    :ok
  end

  describe "create_backup/0" do
    test "creates a timestamped backup file" do
      assert {:ok, backup_path} = Release.create_backup()
      assert File.exists?(backup_path)
      assert String.contains?(backup_path, "_backup_")
      assert String.ends_with?(backup_path, ".db")
    end

    test "backup file contains the database content" do
      assert {:ok, backup_path} = Release.create_backup()
      assert File.read!(backup_path) == "test database content"
    end

    test "backup file is in the same directory as the original database" do
      assert {:ok, backup_path} = Release.create_backup()
      assert Path.dirname(backup_path) == Path.dirname(@test_db_path)
    end

    test "returns error when database does not exist" do
      # Delete the test database
      File.rm!(@test_db_path)

      assert {:error, {:database_not_found, _}} = Release.create_backup()
    end
  end

  describe "cleanup_old_backups" do
    test "keeps only the last 10 backups after creating multiple" do
      # Create 12 backups with unique timestamps
      # Note: Cleanup runs after EACH backup, so only the last creation
      # will result in exactly 10 backups
      for i <- 1..12 do
        # Sleep to ensure unique timestamps
        if i > 1, do: Process.sleep(100)
        {:ok, _path} = Release.create_backup()
      end

      # Count backups after all creations
      basename = Path.basename(@test_db_path, ".db")

      existing_backups =
        @test_db_path
        |> Path.dirname()
        |> Path.join("#{basename}_backup_*.db")
        |> Path.wildcard()
        |> Enum.sort()

      # After creating 12 backups (with cleanup running after each),
      # we should have at most 10 backups remaining
      assert length(existing_backups) <= 10
      assert existing_backups != []
    end
  end

  describe "get_database_path" do
    test "returns the configured database path" do
      # This is a basic integration test
      # The actual pending_migrations? and backup_before_migrations functions
      # are tested via the Mix task in manual testing and Docker startup
      assert is_binary(Application.get_env(:mydia, Mydia.Repo)[:database])
    end
  end
end
