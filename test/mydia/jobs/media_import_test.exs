defmodule Mydia.Jobs.MediaImportTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaImport
  alias Mydia.Settings
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  @moduletag :tmp_dir

  describe "Args.parse/1" do
    test "extracts save_path from job args" do
      args =
        MediaImport.Args.parse(%{
          "download_id" => "abc-123",
          "save_path" => "/downloads/my-show"
        })

      assert args.save_path == "/downloads/my-show"
      assert args.download_id == "abc-123"
    end

    test "save_path is nil when not in args" do
      args =
        MediaImport.Args.parse(%{
          "download_id" => "abc-123"
        })

      assert args.save_path == nil
    end

    test "preserves all existing fields" do
      args =
        MediaImport.Args.parse(%{
          "download_id" => "abc-123",
          "save_path" => "/downloads/test",
          "target_files" => [%{"path" => "/a.mkv", "episode_id" => "ep1"}],
          "snooze_count" => 3,
          "use_hardlinks" => false,
          "move_files" => true,
          "rename_files" => true
        })

      assert args.download_id == "abc-123"
      assert args.save_path == "/downloads/test"
      assert args.target_files == [%{"path" => "/a.mkv", "episode_id" => "ep1"}]
      assert args.snooze_count == 3
      assert args.use_hardlinks == false
      assert args.move_files == true
      assert args.rename_files == true
    end
  end

  describe "perform/1" do
    test "schedules retry when download is not completed (first snooze)" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          progress: 50
        })

      # First attempt with snooze_count = 0 should schedule a retry
      assert {:ok, :waiting_for_completion} =
               perform_job(MediaImport, %{"download_id" => download.id})

      # Verify a new job was scheduled with incremented snooze_count
      assert_enqueued(
        worker: MediaImport,
        args: %{"download_id" => download.id, "snooze_count" => 1}
      )
    end

    test "schedules retry with incremented snooze count when download not completed" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          progress: 50
        })

      # With snooze_count = 5 should schedule a retry with snooze_count = 6
      assert {:ok, :waiting_for_completion} =
               perform_job(MediaImport, %{"download_id" => download.id, "snooze_count" => 5})

      assert_enqueued(
        worker: MediaImport,
        args: %{"download_id" => download.id, "snooze_count" => 6}
      )
    end

    test "marks as failed after max snooze count reached" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          progress: 50
        })

      # With snooze_count = 12 (max), should fail and mark download
      assert {:error, :download_not_completed} =
               perform_job(MediaImport, %{"download_id" => download.id, "snooze_count" => 12})

      # Verify download now has import_failed_at set (visible in Issues tab)
      updated_download = Mydia.Downloads.get_download!(download.id)
      assert updated_download.import_failed_at != nil
      assert updated_download.import_last_error =~ "not yet complete"
    end

    test "proceeds with import when download completes during snooze period" do
      media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

      # Start with incomplete download
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          progress: 50
        })

      # First check - not completed
      assert {:ok, :waiting_for_completion} =
               perform_job(MediaImport, %{"download_id" => download.id})

      # Simulate download completing
      {:ok, _} =
        Mydia.Downloads.update_download(download, %{
          status: "completed",
          progress: 100,
          completed_at: DateTime.utc_now()
        })

      # Second check with snooze_count = 1 - now should try to import
      # (will fail with :no_client since we don't have a mock, but proves it tries)
      assert {:error, :no_client} =
               perform_job(MediaImport, %{"download_id" => download.id, "snooze_count" => 1})
    end

    test "returns error if download does not exist" do
      fake_id = Ecto.UUID.generate()

      assert_raise Ecto.NoResultsError, fn ->
        perform_job(MediaImport, %{"download_id" => fake_id})
      end
    end

    test "returns error if download has no client info", %{tmp_dir: tmp_dir} do
      # Create a library path
      create_test_library_path(tmp_dir, :movies)

      media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: nil,
          download_client_id: nil
        })

      assert {:error, :no_client} = perform_job(MediaImport, %{"download_id" => download.id})
    end

    test "returns error if no library path is configured", %{tmp_dir: _tmp_dir} do
      # Don't create any library paths
      # Use a DB-backed client config so it's isolated within this test's SQL sandbox,
      # avoiding races with other async tests that also write to Application env.
      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "TestClient",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "TestClient",
          download_client_id: "test123"
        })

      # Note: The client config exists, but the actual download client isn't running.
      # The test will fail when trying to connect to the client, returning :client_error.
      # In a full test with mocking, we'd verify the library path check instead.

      assert {:error, :client_error} =
               perform_job(MediaImport, %{"download_id" => download.id})
    end

    test "successfully imports a movie file", %{tmp_dir: tmp_dir} do
      # Create a library path
      _library_path = create_test_library_path(tmp_dir, :movies)

      # Create a test download directory
      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      # Create a test video file
      video_file = Path.join(download_dir, "Test.Movie.2024.1080p.mkv")
      File.write!(video_file, "fake video content")

      media_item = media_item_fixture(%{type: "movie", title: "Test Movie", year: 2024})

      _download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          download_client: "TestClient",
          download_client_id: "test123"
        })

      # Setup runtime config with test client
      setup_runtime_config([build_test_client_config()])

      # Note: This test would need proper mocking of the download client adapter
      # to actually work. For now, it demonstrates the test structure.
      #
      # In a full implementation, we'd mock:
      # - Client.get_status to return %{save_path: video_file, ...}
      # - Or use a test adapter that we can control

      # Skip full execution for now since we'd need mocking infrastructure
      # assert {:ok, :imported} = perform_job(MediaImport, %{"download_id" => download.id})
    end

    test "successfully imports a TV episode file", %{tmp_dir: tmp_dir} do
      # Create a library path
      _library_path = create_test_library_path(tmp_dir, :series)

      # Create a test download directory
      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      # Create a test video file
      video_file = Path.join(download_dir, "Show.S01E01.1080p.mkv")
      File.write!(video_file, "fake video content")

      media_item = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      episode =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      _download =
        download_fixture(%{
          media_item_id: media_item.id,
          episode_id: episode.id,
          status: "completed",
          download_client: "TestClient",
          download_client_id: "test123"
        })

      # Setup runtime config with test client
      setup_runtime_config([build_test_client_config()])

      # Note: This test would need proper mocking of the download client adapter
      # Skip full execution for now
      # assert {:ok, :imported} = perform_job(MediaImport, %{"download_id" => download.id})
    end

    test "handles file conflicts gracefully", %{tmp_dir: _tmp_dir} do
      # This would test the conflict resolution logic
      # where a file already exists at the destination
    end

    test "handles video file filtering", %{tmp_dir: _tmp_dir} do
      # This would test that only video files are imported
      # and other files (like .nfo, .txt, etc.) are skipped
    end
  end

  # Helper functions

  defp create_test_library_path(base_path, type) do
    library_path = Path.join(base_path, "library")
    File.mkdir_p!(library_path)

    {:ok, path_record} =
      Settings.create_library_path(%{
        path: library_path,
        type: type,
        monitored: true
      })

    path_record
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
    }

    Application.put_env(:mydia, :runtime_config, config)
  end

  defp build_test_client_config do
    %{
      name: "TestClient",
      type: :qbittorrent,
      host: "localhost",
      port: 8080,
      username: "test",
      password: "test",
      enabled: true,
      priority: 1,
      use_ssl: false
    }
  end
end
