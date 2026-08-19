defmodule Mydia.Jobs.MediaImportTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaImport
  alias Mydia.Library
  alias Mydia.Repo
  alias Mydia.Settings

  # Scene-style source filename used by the auto_rename describe block; the
  # standardized form differs from this, which is what those tests assert on.
  @rename_scene_name "The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv"
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  @moduletag :tmp_dir

  # `chmod 000` does not restrict the root user, so a permission-denied path is
  # unobservable when the suite runs as root (as it does in some Docker images).
  # Tests that depend on it are skipped there rather than asserting behaviour
  # that cannot occur.
  @running_as_root (case System.cmd("id", ["-u"]) do
                      {out, 0} -> String.trim(out) == "0"
                      _ -> false
                    end)

  describe "Args.parse/1" do
    test "parses save_path from job args" do
      args = MediaImport.Args.parse(%{"download_id" => "123", "save_path" => "/downloads/movie"})
      assert args.save_path == "/downloads/movie"
    end

    test "save_path is nil when not provided" do
      args = MediaImport.Args.parse(%{"download_id" => "123"})
      assert args.save_path == nil
    end

    test "save_path is nil when empty string is provided" do
      args = MediaImport.Args.parse(%{"download_id" => "123", "save_path" => ""})
      assert args.save_path == nil
    end

    test "preserves all other fields" do
      args =
        MediaImport.Args.parse(%{
          "download_id" => "123",
          "save_path" => "/path",
          "snooze_count" => 5,
          "use_hardlinks" => false,
          "move_files" => true,
          "rename_files" => true
        })

      assert args.download_id == "123"
      assert args.save_path == "/path"
      assert args.snooze_count == 5
      assert args.use_hardlinks == false
      assert args.move_files == true
      assert args.rename_files == true
    end
  end

  describe "detect_partial_pack/2" do
    test "returns 'partial_pack' when fewer episodes are imported than promised" do
      episode_id = Ecto.UUID.generate()

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01.Pack",
        metadata: %{"episode_count" => 3}
      }

      # Only 1 distinct episode imported, but 3 were promised
      imported_files = [%{episode_id: episode_id}]

      assert "partial_pack" == MediaImport.detect_partial_pack(download, imported_files)
    end

    test "returns nil when all promised episodes are delivered" do
      ids = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01.Pack",
        metadata: %{"episode_count" => 3}
      }

      imported_files = Enum.map(ids, fn id -> %{episode_id: id} end)

      assert nil == MediaImport.detect_partial_pack(download, imported_files)
    end

    test "returns nil when metadata has no episode_count" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01E01",
        metadata: %{}
      }

      imported_files = [%{episode_id: Ecto.UUID.generate()}]

      assert nil == MediaImport.detect_partial_pack(download, imported_files)
    end

    test "returns nil when download has no metadata" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01E01",
        metadata: nil
      }

      imported_files = [%{episode_id: Ecto.UUID.generate()}]

      assert nil == MediaImport.detect_partial_pack(download, imported_files)
    end

    test "deduplicates episode_ids before comparing counts" do
      episode_id = Ecto.UUID.generate()

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01.Pack",
        metadata: %{"episode_count" => 1}
      }

      # Two files pointing to the same episode — should count as 1 distinct episode
      imported_files = [%{episode_id: episode_id}, %{episode_id: episode_id}]

      assert nil == MediaImport.detect_partial_pack(download, imported_files)
    end

    test "ignores imported files without an episode_id (e.g. extras)" do
      episode_id = Ecto.UUID.generate()

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test.Show.S01.Pack",
        metadata: %{"episode_count" => 2}
      }

      # One real episode + one file with no episode_id (extra/featurette)
      imported_files = [%{episode_id: episode_id}, %{episode_id: nil}]

      assert "partial_pack" == MediaImport.detect_partial_pack(download, imported_files)
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

    test "self-heals when the download row has been deleted" do
      # If the download row is deleted between when the MediaImport job was
      # enqueued and when it runs, the row is gone. Returning :ok lets Oban
      # mark the job done so it stops retrying.
      fake_id = Ecto.UUID.generate()

      assert :ok = perform_job(MediaImport, %{"download_id" => fake_id})
    end

    @tag :tmp_dir
    test "cancels (no retry) when completed torrent has no importable files",
         %{tmp_dir: tmp_dir} do
      # Real bug from production: malware torrents named
      # `From.S04E05.1080p.WEB.h264-ETHEL.exe` slip past the indexer, finish
      # downloading, and then sit in the retry queue forever because the
      # importer keeps rejecting them with `:no_importable_files`. Re-scanning
      # the same finished torrent will deterministically produce the same
      # result — there's no recovery path, so the job must `:cancel` on the
      # first attempt instead of burning days of exponential backoff.
      _library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "ethel-malware")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Movie.2024.1080p.exe"), "not a video")

      media_item = media_item_fixture(%{type: "movie", title: "Malware Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "MalwareClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "MalwareClient",
          download_client_id: "ethel-1"
        })

      assert {:cancel, :no_importable_files} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)

      assert updated.import_failed_at != nil,
             "Terminal failures must still record import_failed_at for the Issues tab"

      assert is_nil(updated.import_next_retry_at),
             "Terminal failures must clear import_next_retry_at so the UI doesn't advertise a retry that won't fire"

      assert updated.import_last_error =~ "No importable files"
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

  describe "import with save_path fallback" do
    @tag :tmp_dir
    test "falls back to save_path when client query fails", %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      video_file = Path.join(download_dir, "Fallback.Movie.2024.1080p.mkv")
      File.write!(video_file, "fake video content")

      media_item = media_item_fixture(%{type: "movie", title: "Fallback Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "FallbackClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "FallbackClient",
          download_client_id: "test123"
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.imported_at != nil
    end

    @tag :tmp_dir
    test "returns client_error when client fails and save_path is missing" do
      media_item = media_item_fixture(%{type: "movie", title: "No Save Path Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "NoSavePathClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "NoSavePathClient",
          download_client_id: "test123"
        })

      assert {:error, :client_error} =
               perform_job(MediaImport, %{"download_id" => download.id})
    end

    @tag :tmp_dir
    test "returns client_error when client fails and save_path is empty string" do
      media_item = media_item_fixture(%{type: "movie", title: "Empty Path Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "EmptyPathClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "EmptyPathClient",
          download_client_id: "test123"
        })

      assert {:error, :client_error} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => ""
               })
    end

    @tag :tmp_dir
    test "TV file with parsable season but nil episodes is flagged as unresolved", %{
      tmp_dir: tmp_dir
    } do
      # Regression: a file whose name parses to season=N but no episode
      # number (e.g. `Show.S01.mkv` or `Show Season 1 Foo.mkv`) used to
      # crash `import_file/5` with `FunctionClauseError` in `List.first/2`
      # because the clause did `List.first(parsed.episodes) || 1` without
      # guarding for nil. The job must route the file to the Issues tab
      # (via match_status: "unresolved_files") instead of raising or
      # silently importing as episode 1.
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      # `Mystery.Show.S01.mkv` parses to season=1, episodes=nil.
      video_file = Path.join(download_dir, "Mystery.Show.S01.mkv")
      File.write!(video_file, "fake video content")

      media_item = media_item_fixture(%{type: "tv_show", title: "Mystery Show"})

      _episode =
        episode_fixture(%{
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 1
        })

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "NilEpisodesClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "NilEpisodesClient",
          download_client_id: "nilep123"
        })

      assert {:error, :all_files_unresolved} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.match_status == "unresolved_files"
      assert [unresolved] = updated.metadata["unresolved_files"]
      assert unresolved["name"] == "Mystery.Show.S01.mkv"
      assert unresolved["parsed_season"] == 1
      assert unresolved["parsed_episode"] == nil
    end

    @tag :tmp_dir
    test "classifies a path with no visible parent as a mapping mismatch and goes terminal",
         %{tmp_dir: _tmp_dir} do
      media_item =
        media_item_fixture(%{type: "movie", title: "Bad Path Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "BadPathClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "BadPathClient",
          download_client_id: "test123"
        })

      # Neither the leaf nor its parent are visible -> mount mismatch, terminal
      # on the first attempt (returns :cancel, not :error).
      assert {:cancel, {:path_mapping_mismatch, "/no/such/path/exists"}} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => "/no/such/path/exists"
               })

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_last_error =~ "can't access the download path"
      assert updated.import_failure_reason == "path_mapping_mismatch"
      assert updated.import_reported_path == "/no/such/path/exists"
    end

    @tag :tmp_dir
    test "cancels missing path after the third attempt and clears retry metadata", %{
      tmp_dir: tmp_dir
    } do
      media_item =
        media_item_fixture(%{type: "movie", title: "Bad Path Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "MissingPathTerminalClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "MissingPathTerminalClient",
          download_client_id: "missing-path-terminal"
        })

      # A deleted leaf whose parent directory IS visible stays :path_not_found
      # (a genuinely missing file), which retries up to three times before
      # going terminal.
      missing_leaf = Path.join(tmp_dir, "missing-leaf")

      assert {:cancel, {:path_not_found, ^missing_leaf}} =
               perform_job(
                 MediaImport,
                 %{
                   "download_id" => download.id,
                   "save_path" => missing_leaf
                 },
                 attempt: 3
               )

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_retry_count == 3
      assert is_nil(updated.import_next_retry_at)
      assert updated.import_last_error =~ "Download path not found"
    end

    @tag :tmp_dir
    @tag skip: @running_as_root and "chmod 000 does not restrict root; path stays accessible"
    test "cancels inaccessible path after the third attempt and clears retry metadata",
         %{tmp_dir: tmp_dir} do
      media_item =
        media_item_fixture(%{type: "movie", title: "Restricted Path Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "RestrictedPathTerminalClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      restricted_dir = Path.join(tmp_dir, "restricted-download")
      File.mkdir_p!(restricted_dir)
      File.write!(Path.join(restricted_dir, "movie.mkv"), "video")
      File.chmod!(restricted_dir, 0o000)
      on_exit(fn -> File.chmod!(restricted_dir, 0o755) end)

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "RestrictedPathTerminalClient",
          download_client_id: "restricted-path-terminal"
        })

      assert {:cancel, {:path_not_accessible, ^restricted_dir}} =
               perform_job(
                 MediaImport,
                 %{
                   "download_id" => download.id,
                   "save_path" => restricted_dir
                 },
                 attempt: 3
               )

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_retry_count == 3
      assert is_nil(updated.import_next_retry_at)
      assert updated.import_last_error =~ "Download path is not accessible"
    end

    @tag :tmp_dir
    test "records import failure (no silent crash) when destination dir cannot be created",
         %{tmp_dir: tmp_dir} do
      # Reproduces the production incident: a completed download whose import
      # failed because the destination directory could not be created (a
      # permission error on the media volume). Previously `File.mkdir_p!` raised
      # and crashed the Oban job, so the download row never recorded the error
      # and the UI showed a healthy "seeding" row for ~2.5h. The job must now
      # capture the failure as a handled {:error, ...} and persist it.
      library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "blocked-download")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Blocked Movie 2024 1080p.mkv"), "video")

      media_item = media_item_fixture(%{type: "movie", title: "Blocked Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "BlockedDestClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "BlockedDestClient",
          download_client_id: "blocked-dest-1"
        })

      # Occupy the destination directory path with a regular file so File.mkdir_p
      # fails deterministically — this works even when tests run as root (where a
      # chmod-based restriction would not).
      preloaded =
        Mydia.Downloads.get_download!(download.id,
          preload: [{:media_item, :episodes}, :episode, :library_path]
        )

      dest_dir = MediaImport.build_destination_path(preloaded, library_path)
      File.mkdir_p!(Path.dirname(dest_dir))
      File.write!(dest_dir, "occupied")

      # First attempt: a handled error (NOT a raised exception), with a retry
      # scheduled and the failure recorded on the download row. A destination
      # permission/disk problem is non-terminal so it can self-heal once the path
      # becomes writable.
      assert {:error, {:destination_not_accessible, ^dest_dir}} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_failed_at != nil
      assert updated.import_next_retry_at != nil
      assert updated.import_last_error =~ "library destination directory"
      assert is_nil(updated.imported_at)
    end

    @tag :tmp_dir
    @tag skip: @running_as_root and "chmod 000 does not restrict root; parent stays accessible"
    test "classifies a missing leaf under an inaccessible parent as path_not_accessible",
         %{tmp_dir: tmp_dir} do
      media_item =
        media_item_fixture(%{type: "movie", title: "Restricted Parent Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "RestrictedParentTerminalClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      restricted_parent = Path.join(tmp_dir, "restricted-parent")
      File.mkdir_p!(restricted_parent)
      File.chmod!(restricted_parent, 0o000)
      on_exit(fn -> File.chmod!(restricted_parent, 0o755) end)

      missing_leaf = Path.join(restricted_parent, "missing-leaf")

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "RestrictedParentTerminalClient",
          download_client_id: "restricted-parent-terminal"
        })

      assert {:cancel, {:path_not_accessible, ^missing_leaf}} =
               perform_job(
                 MediaImport,
                 %{
                   "download_id" => download.id,
                   "save_path" => missing_leaf
                 },
                 attempt: 3
               )
    end
  end

  describe "auto_rename from library path" do
    # MediaImport reads auto_rename from the resolved library path at execution
    # time (process_import/3) and overrides rename_files accordingly, so the
    # destination filename follows the library's policy rather than whatever the
    # job was enqueued with.
    @tag :tmp_dir
    test "renames to the standardized format when the library path enables auto_rename",
         %{tmp_dir: tmp_dir} do
      {_lp, download, download_dir} =
        seed_rename_import(tmp_dir, "RenameOnClient", "rename-on-1", true)

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      name = imported_basename()
      assert is_binary(name), "expected an imported .mkv file, found none"
      refute name == @rename_scene_name
      assert name =~ "The Matrix (1999)"
      assert String.ends_with?(name, ".mkv")
    end

    @tag :tmp_dir
    test "keeps the original filename when the library path disables auto_rename, even if the job requested renaming",
         %{tmp_dir: tmp_dir} do
      {_lp, download, download_dir} =
        seed_rename_import(tmp_dir, "RenameOffClient", "rename-off-1", false)

      # Enqueue with rename_files: true to prove the library path's
      # auto_rename: false overrides it at execution time.
      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir,
                 "rename_files" => true
               })

      assert imported_basename() == @rename_scene_name
    end
  end

  # Helper functions

  defp seed_rename_import(tmp_dir, client_name, download_id, auto_rename) do
    library_path = create_test_library_path(tmp_dir, :movies, auto_rename: auto_rename)

    download_dir = Path.join(tmp_dir, "downloads")
    File.mkdir_p!(download_dir)
    File.write!(Path.join(download_dir, @rename_scene_name), "fake video content for rename test")

    media_item = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})

    {:ok, _} =
      Settings.create_download_client_config(%{
        name: client_name,
        type: :qbittorrent,
        host: "nonexistent.invalid",
        port: 9999,
        username: "test",
        password: "test",
        enabled: true,
        priority: 1
      })

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        title: "The.Matrix.1999.1080p.BluRay.x264-GROUP",
        status: "completed",
        completed_at: DateTime.utc_now(),
        download_client: client_name,
        download_client_id: download_id
      })

    {library_path, download, download_dir}
  end

  defp imported_basename do
    Library.list_media_files()
    |> Enum.find(&String.ends_with?(&1.relative_path, ".mkv"))
    |> case do
      nil -> nil
      media_file -> Path.basename(media_file.relative_path)
    end
  end

  defp create_test_library_path(base_path, type, opts \\ []) do
    library_path = Path.join(base_path, "library")
    File.mkdir_p!(library_path)

    attrs = %{path: library_path, type: type, monitored: true}

    attrs =
      case Keyword.fetch(opts, :auto_rename) do
        {:ok, value} -> Map.put(attrs, :auto_rename, value)
        :error -> attrs
      end

    {:ok, path_record} = Settings.create_library_path(attrs)

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

    # Capture and restore the prior value. `:runtime_config` is global
    # Application state (test_helper.exs forces empty download_clients at boot);
    # leaving an enabled client here leaks into later tests, e.g. DownloadsLive,
    # whose queue-tab filter then hides the completed downloads they seed.
    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
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

  describe "idempotency" do
    test "short-circuits with :ok when download.imported_at is already set" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "AlreadyImportedClient",
          download_client_id: "imported-1"
        })

      {:ok, _} =
        Mydia.Downloads.update_download(download, %{
          completed_at: DateTime.utc_now(),
          imported_at: DateTime.utc_now()
        })

      # No client config exists; if we fell through to import_download/2 we
      # would hit {:error, :no_client}. The fact that we still return :ok
      # proves the short-circuit triggered first.
      assert :ok == perform_job(MediaImport, %{"download_id" => download.id})
    end

    # NB: the `unique:` constraint itself is enforced at production Oban
    # insert time; the test environment runs with `engine: false` so
    # `Oban.insert/1` cannot exercise it directly. The `imported_at`
    # short-circuit above is the user-visible safety net regardless of
    # whether duplicate jobs slip past the unique gate.
  end

  # Regression tests for the Good Omens "Complete S01-S03" pack incident.
  #
  # A torrent named `... 2019 S01 S03 Complete ...` was grabbed to satisfy
  # a single-episode request (S3E1). The pack contained S01E01..S03E01 in
  # /S01/, /S02/, /S03/ subdirs. The season-pack branch in import_file/5
  # hard-overrode every file's season with the download-level
  # `season_number=3`, so:
  #
  #   - S01/E01..E06 and S02/E01..E06 were either flagged as unresolved
  #     (when the parsed episode_number had no corresponding S3 episode)
  #     or wrongly imported onto S3E1 (when parsed episode_number happened
  #     to be 1) — multiple files collapsing onto the same episode row.
  #   - The partial-import path skipped setting `imported_at`, so
  #     DownloadMonitor's `list_stuck_downloads/1` kept matching the
  #     download forever and the UI showed "Import stalled - never ran"
  #     even though it had run ~28 times.
  describe "season pack with multi-season files (Good Omens regression)" do
    @tag :tmp_dir
    test "uses per-file parsed season instead of download-level season override",
         %{tmp_dir: tmp_dir} do
      # Setup: TV show with S1E1, S1E2, S2E1. Download is a "season 2 pack"
      # but the torrent actually contains files from S01 and S02. The
      # per-file filename is the authoritative season hint — the
      # download-level `season_number` is just the originally-requested
      # season, not what the file at hand belongs to.
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      s1_dir = Path.join(download_dir, "S01")
      s2_dir = Path.join(download_dir, "S02")
      File.mkdir_p!(s1_dir)
      File.mkdir_p!(s2_dir)

      s01e01 = Path.join(s1_dir, "Mystery.Show.S01E01.mkv")
      s01e02 = Path.join(s1_dir, "Mystery.Show.S01E02.mkv")
      s02e01 = Path.join(s2_dir, "Mystery.Show.S02E01.mkv")

      for f <- [s01e01, s01e02, s02e01], do: File.write!(f, "fake video")

      media_item = media_item_fixture(%{type: "tv_show", title: "Mystery Show"})

      ep_s1e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      ep_s1e2 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 2})

      ep_s2e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 2, episode_number: 1})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "MultiSeasonClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "MultiSeasonClient",
          download_client_id: "multiseason-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 2,
            "episode_count" => 1
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)

      # All three files must be matched to their actual episodes.
      refute updated.match_status == "unresolved_files",
             "Expected all files to resolve; got unresolved: #{inspect(updated.metadata["unresolved_files"])}"

      # Each parsed season's episode must end up with its own media_file row,
      # not collapsed onto a single S2E1 entry.
      files_by_episode =
        Mydia.Library.list_media_files()
        |> Enum.filter(&(&1.episode_id in [ep_s1e1.id, ep_s1e2.id, ep_s2e1.id]))
        |> Enum.group_by(& &1.episode_id)

      assert Map.has_key?(files_by_episode, ep_s1e1.id),
             "S1E1 must get its own media_file, not collapse onto S2E1"

      assert Map.has_key?(files_by_episode, ep_s1e2.id),
             "S1E2 must get its own media_file"

      assert Map.has_key?(files_by_episode, ep_s2e1.id),
             "S2E1 must get its own media_file"
    end

    @tag :tmp_dir
    test "different-season files with the same episode number don't collapse onto one row",
         %{tmp_dir: tmp_dir} do
      # The Bug D variant: three E01 files from three different seasons
      # were all rewritten to season=download.season_number, episode=1 and
      # all matched the single existing S3E1 row.
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      File.write!(Path.join(download_dir, "Show.S01E01.mkv"), "v")
      File.write!(Path.join(download_dir, "Show.S02E01.mkv"), "v")
      File.write!(Path.join(download_dir, "Show.S03E01.mkv"), "v")

      media_item = media_item_fixture(%{type: "tv_show", title: "Show"})

      ep_s1e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      ep_s2e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 2, episode_number: 1})

      ep_s3e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 3, episode_number: 1})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "ThreeE01Client",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "ThreeE01Client",
          download_client_id: "three-e01-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 3,
            "episode_count" => 1
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      episode_ids_with_files =
        Mydia.Library.list_media_files()
        |> Enum.map(& &1.episode_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> MapSet.new()

      expected = MapSet.new([ep_s1e1.id, ep_s2e1.id, ep_s3e1.id])

      assert MapSet.equal?(episode_ids_with_files, expected),
             "Expected exactly the three E01 episodes to be referenced once each, got: #{inspect(MapSet.to_list(episode_ids_with_files))}"
    end
  end

  describe "season pack containing episodes that already have files" do
    @tag :tmp_dir
    test "skips the overlapping file, imports the missing one, no partial_pack",
         %{tmp_dir: tmp_dir} do
      # A pack legitimately contains episodes we already have, now that the grab
      # guard only blocks a pack whose every targeted episode is on disk.
      # Importing the overlap would leave two live media_files rows for one
      # episode, with no quality gate to reconcile them: the importer's only
      # existence check is on the destination path.
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      for name <- ["Overlap.Show.S03E01.mkv", "Overlap.Show.S03E02.mkv"] do
        File.write!(Path.join(download_dir, name), "fake video")
      end

      media_item = media_item_fixture(%{type: "tv_show", title: "Overlap Show"})

      ep1 = episode_fixture(%{media_item_id: media_item.id, season_number: 3, episode_number: 1})
      ep2 = episode_fixture(%{media_item_id: media_item.id, season_number: 3, episode_number: 2})

      # E01 is already on disk. E02 is the one the pack was grabbed for.
      media_file_fixture(%{episode_id: ep1.id})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "OverlapClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "OverlapClient",
          download_client_id: "overlap-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 3,
            # episode_count is the count of MISSING episodes the search wanted,
            # not the season total. Only E02 was missing.
            "episode_count" => 1,
            "episode_ids" => [ep2.id]
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      files_by_episode =
        Library.list_media_files()
        |> Enum.filter(&(&1.episode_id in [ep1.id, ep2.id]))
        |> Enum.group_by(& &1.episode_id)

      assert length(Map.get(files_by_episode, ep1.id, [])) == 1,
             "E01 already had a file; the pack's copy must be skipped, not added"

      assert length(Map.get(files_by_episode, ep2.id, [])) == 1,
             "E02 was missing and must be imported"

      updated = Mydia.Downloads.get_download!(download.id)

      refute updated.match_status == "partial_pack",
             "1 imported vs episode_count 1 must not read as a short pack"
    end

    @tag :tmp_dir
    test "an upgrade pack still imports over an episode that already has a file",
         %{tmp_dir: tmp_dir} do
      # Upgrades target episodes that already have files by definition, so the
      # skip must not apply or UpgradeSweep breaks entirely.
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Upgrade.Show.S03E01.mkv"), "fake video")

      media_item = media_item_fixture(%{type: "tv_show", title: "Upgrade Show"})
      ep1 = episode_fixture(%{media_item_id: media_item.id, season_number: 3, episode_number: 1})
      existing = media_file_fixture(%{episode_id: ep1.id})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "UpgradeClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "UpgradeClient",
          download_client_id: "upgrade-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 3,
            "episode_count" => 1,
            # The discriminator supersede_target/3 keys on.
            "upgrade_target_media_file_id" => existing.id
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      count = Library.list_media_files() |> Enum.count(&(&1.episode_id == ep1.id))

      assert count == 2,
             "an upgrade must import alongside the file it supersedes, not be skipped"
    end
  end

  # Regression for the partial-import retry loop (Bug C).
  #
  # When a season-pack import resolves some files but flags others as
  # unresolved, the historical behaviour skipped setting `imported_at`,
  # which left the download permanently matching
  # `Downloads.list_stuck_downloads/1`. DownloadMonitor then re-enqueued
  # `MediaImport` every 2 minutes forever, and the user-facing Issues tab
  # rendered the misleading "Import stalled - never ran" message even
  # though dozens of import attempts had succeeded.
  describe "partial import retry-loop (stalled detector)" do
    @tag :tmp_dir
    test "marks imported_at even when some files remain unresolved",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      # One file matches an existing episode; one file is unparseable
      # for episode number and must end up unresolved.
      File.write!(Path.join(download_dir, "Show.S01E01.mkv"), "v")
      File.write!(Path.join(download_dir, "Show.S01.mkv"), "v")

      media_item = media_item_fixture(%{type: "tv_show", title: "Show"})

      _ep =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "PartialClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      # Make completed_at older than list_stuck_downloads' 60-min threshold
      # so the stuck detector would re-fire if imported_at stayed nil.
      old_completion = DateTime.add(DateTime.utc_now(), -2, :hour)

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: old_completion,
          download_client: "PartialClient",
          download_client_id: "partial-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2
          }
        })

      # `:partial_import` is the contract result when some files resolve and
      # others don't — that's expected here. The bug is that `imported_at`
      # stayed nil on this path, which is what we assert below.
      assert {:ok, result} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      assert result in [:imported, :partial_import]

      updated = Mydia.Downloads.get_download!(download.id)

      assert updated.imported_at != nil,
             "Partial imports must set imported_at to break the stuck-detector retry loop"

      assert updated.match_status == "unresolved_files",
             "match_status must still surface the partial result to the Issues tab"

      stuck = Mydia.Downloads.list_stuck_downloads()
      stuck_ids = Enum.map(stuck, & &1.id)

      refute download.id in stuck_ids,
             "list_stuck_downloads must not re-flag a download whose import already ran"
    end
  end

  # Regression for the metadata-relay hammer (Bug A).
  #
  # The season-pack branch in `import_file/5` called
  # `Media.refresh_episodes_for_tv_show(media_item)` on every unmatched
  # file, passing the same in-memory media_item struct each time. Even
  # though `refresh_episodes_for_tv_show` has a `should_skip_season_refresh?`
  # threshold check, the in-memory `seasons_refreshed_at` stayed stale
  # across the per-file loop, so the threshold never tripped and the
  # function refetched from the metadata-relay once per unresolved file.
  # A 10-file Good Omens import hit the relay 10× per job, and the
  # MediaImport job re-ran every 2 minutes from the stall-detector loop.
  describe "metadata-relay refresh deduplication" do
    @tag :tmp_dir
    test "refresh_episodes_for_tv_show is called at most once per import",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :series)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      # Five files for a season whose episodes don't exist in the DB. Each
      # missing lookup would historically trigger a fresh refresh round-trip.
      for i <- 1..5 do
        File.write!(Path.join(download_dir, "Show.S99E0#{i}.mkv"), "v")
      end

      media_item = media_item_fixture(%{type: "tv_show", title: "Show"})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "RefreshDedupClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "RefreshDedupClient",
          download_client_id: "refresh-dedup-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 99,
            "episode_count" => 5
          }
        })

      # Point metadata relay at an unreachable URL so every refresh call
      # fails quickly without creating episodes. Without dedup the import
      # would invoke refresh once per file (5 times); with dedup it's at
      # most once for the whole job regardless of how many files miss.
      # `Mydia.Metadata.metadata_relay_url/0` reads from System env, not
      # Application config, so we have to override there.
      previous_env = System.get_env("METADATA_RELAY_URL")
      System.put_env("METADATA_RELAY_URL", "http://127.0.0.1:1")

      on_exit(fn ->
        if previous_env do
          System.put_env("METADATA_RELAY_URL", previous_env)
        else
          System.delete_env("METADATA_RELAY_URL")
        end
      end)

      # Count "Failed to refresh episodes" — that line only fires inside
      # the refresh attempt itself, so its count equals the number of
      # actual `Media.refresh_episodes_for_tv_show/1` invocations. (The
      # outer "Episode still not found …" warning fires per file
      # regardless of dedup and is not a reliable counter.)
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          perform_job(MediaImport, %{
            "download_id" => download.id,
            "save_path" => download_dir
          })
        end)

      refresh_attempts =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "Failed to refresh episodes"))

      assert refresh_attempts <= 1,
             "refresh_episodes_for_tv_show should be invoked at most once per import job; got #{refresh_attempts} attempts across 5 unresolved files"
    end
  end

  describe "partial import error surfacing" do
    @tag :tmp_dir
    test "exposes the underlying per-file error instead of only a generic hint",
         %{tmp_dir: tmp_dir} do
      # Regression for the production incident where season-pack imports
      # failed with only the generic "Some files could not be imported. Check
      # library path permissions and available disk space." while the real
      # cause was duplicate media_files rows making Repo.one/1 raise
      # "expected at most one result" on the reuse-existing-file path.
      {download, download_dir} = duplicate_media_file_scenario(tmp_dir)

      assert {:error, _reason} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      updated = Mydia.Downloads.get_download!(download.id)

      # The classification tag stays stable for Issues-tab filtering...
      assert updated.import_failure_reason == "partial_import"

      # ...but the human message must name the real underlying error, not
      # just the generic permissions/disk-space hint.
      assert updated.import_last_error =~ "Some files could not be imported"
      assert updated.import_last_error =~ "First error: expected at most one result"
      refute updated.import_last_error =~ "Check library path permissions"
    end

    @tag :tmp_dir
    test "still goes terminal after three attempts once the reason is attached",
         %{tmp_dir: tmp_dir} do
      # Attaching the underlying reason turns the error from the bare atom
      # :partial_import into {:partial_import, reason}. terminal_failure?/2
      # must match the tuple too — otherwise an unfixable partial import falls
      # through to the catch-all, never cancels, and re-walks the whole
      # download for all 1000 of Oban's attempts.
      {download, download_dir} = duplicate_media_file_scenario(tmp_dir)

      assert {:cancel, {:partial_import, _reason}} =
               perform_job(
                 MediaImport,
                 %{"download_id" => download.id, "save_path" => download_dir},
                 attempt: 3
               )
    end

    # Builds the production shape: a two-episode season pack where S01E01's
    # destination already exists and carries TWO media_files rows for the same
    # (library_path_id, relative_path), so the reuse-existing-file path raises
    # while S01E02 imports cleanly — i.e. a genuine partial import.
    defp duplicate_media_file_scenario(tmp_dir) do
      library_path = create_test_library_path(tmp_dir, :series, auto_rename: false)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      File.write!(Path.join(download_dir, "Mystery.Show.S01E01.mkv"), "fake video 1")
      File.write!(Path.join(download_dir, "Mystery.Show.S01E02.mkv"), "fake video 2")

      media_item = media_item_fixture(%{type: "tv_show", title: "Mystery Show"})

      ep_s1e1 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      _ep_s1e2 =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 2})

      dest_dir =
        Path.join(MediaImport.build_series_base_path(media_item, library_path), "Season 01")

      File.mkdir_p!(dest_dir)
      dest_file = Path.join(dest_dir, "Mystery.Show.S01E01.mkv")
      File.write!(dest_file, "existing video")
      relative_path = Path.relative_to(dest_file, library_path.path)

      existing_files =
        for _ <- 1..2 do
          media_file_fixture(%{
            library_path_id: library_path.id,
            episode_id: ep_s1e1.id,
            relative_path: relative_path
          })
        end

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "PartialErrorClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "PartialErrorClient",
          download_client_id: "partial-error-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            # Marked as an upgrade so the already-filed-episode skip does not
            # intercept this file. Upgrades are exempt from that skip by design,
            # since they target episodes that already have files, which makes
            # this the path where a duplicate-row Repo.one crash is still
            # reachable and therefore still worth surfacing properly.
            "upgrade_target_media_file_id" => hd(existing_files).id
          }
        })

      {download, download_dir}
    end
  end

  describe "destination filename conflicts" do
    @tag :tmp_dir
    test "re-running an import adopts the earlier conflict copy instead of duplicating it",
         %{tmp_dir: tmp_dir} do
      # Conflict names used to carry a unix timestamp, so every retry of an
      # import minted a fresh filename and re-copied the whole file. Under
      # max_attempts: 1000 that is how misplaced episodes became ~980 GiB of
      # duplicates. Numbering deterministically means a retry finds what the
      # previous attempt wrote and adopts it.
      library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      source = Path.join(download_dir, "Conflict.Movie.2024.1080p.mkv")
      File.write!(source, "the freshly downloaded copy")

      media_item = media_item_fixture(%{type: "movie", title: "Conflict Movie", year: 2024})

      # Squat the destination with different content so the import is forced
      # down the conflict path.
      dest_dir = Path.join(library_path.path, "Conflict Movie (2024)")
      File.mkdir_p!(dest_dir)
      File.write!(Path.join(dest_dir, "Conflict Movie (2024).mkv"), "a different, older file")

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "ConflictClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "ConflictClient",
          download_client_id: "conflict-1"
        })

      args = %{"download_id" => download.id, "save_path" => download_dir}

      assert {:ok, :imported} = perform_job(MediaImport, args)
      assert ["Conflict Movie (2024).1.mkv"] = conflict_copies(dest_dir)

      # Clear imported_at so the job re-runs the import rather than
      # short-circuiting on the already-done guard. Re-fetch first: the local
      # struct predates the import, so changing it produces an empty changeset.
      download.id
      |> Mydia.Downloads.get_download!()
      |> Ecto.Changeset.change(%{imported_at: nil})
      |> Repo.update!()

      assert {:ok, :imported} = perform_job(MediaImport, args)

      assert ["Conflict Movie (2024).1.mkv"] = conflict_copies(dest_dir),
             "retry must reuse the existing conflict copy, not mint another one"
    end

    defp conflict_copies(dest_dir) do
      dest_dir
      |> File.ls!()
      |> Enum.filter(&(&1 != "Conflict Movie (2024).mkv" and String.ends_with?(&1, ".mkv")))
      |> Enum.sort()
    end
  end

  describe "download client removed from configuration" do
    # A download whose `download_client` no longer resolves to any configured
    # client cannot self-heal: every retry re-reads the same config and gets the
    # same answer. With max_attempts: 1000 the row retried indefinitely, and
    # because `Download.occupying/1` treats a non-nil `import_next_retry_at` as
    # "still working", the episode stayed occupied and was never re-searched.
    # Observed in production after an rqbit client was retired.
    setup do
      media_item = media_item_fixture(%{type: "movie", title: "Retired Client Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now(),
          download_client: "RetiredClient",
          download_client_id: "retired-client-1"
        })

      %{download: download}
    end

    test "retries the first attempts so a config reload can still recover it", %{
      download: download
    } do
      assert {:error, :no_client} =
               perform_job(MediaImport, %{"download_id" => download.id}, attempt: 1)

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_failure_reason == "no_client"
      assert updated.import_next_retry_at != nil
    end

    test "goes terminal after the third attempt so the episode is released", %{
      download: download
    } do
      assert {:cancel, :no_client} =
               perform_job(MediaImport, %{"download_id" => download.id}, attempt: 3)

      updated = Mydia.Downloads.get_download!(download.id)
      assert updated.import_failure_reason == "no_client"

      assert is_nil(updated.import_next_retry_at),
             "a terminal failure must clear import_next_retry_at so Download.occupying/1 releases the target"

      refute updated.id in occupying_download_ids()
    end

    defp occupying_download_ids do
      Mydia.Downloads.Download.occupying()
      |> Repo.all()
      |> Enum.map(& &1.id)
    end
  end

  # Task 9: linking an upgrade import's new file to what it supersedes.
  #
  # `MovieSearch`/`TVShowSearch` stamp exactly one
  # `"upgrade_target_media_file_id"` on the download's metadata even for a
  # season pack, which delivers files for many episodes. Stamping every
  # imported file with that single id would be wrong: an already-above-cutoff
  # episode in the pack would get pointed at some OTHER episode's old file.
  # Instead each created file must supersede its OWN episode/media item's
  # current best analyzed, untrashed file — the download's target id is only
  # a fallback when that per-file lookup finds nothing (e.g. no quality
  # profile resolves). Task 10 reads this pointer later to decide whether to
  # trash the old file or reject the new one; this task only records it.
  describe "supersedes_media_file_id on upgrade imports" do
    @tag :tmp_dir
    test "stamps supersedes pointer to the download's target for a single-file movie upgrade",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)

      profile =
        quality_profile_fixture(%{quality_standards: %{preferred_resolutions: ["2160p"]}})

      media_item =
        media_item_fixture(%{
          type: "movie",
          title: "Upgrade Movie",
          year: 2024,
          quality_profile_id: profile.id
        })

      existing_file =
        media_file_fixture(%{
          media_item_id: media_item.id,
          resolution: "1080p",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Upgrade.Movie.2024.2160p.mkv"), "new remux content")

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "UpgradeMovieClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "UpgradeMovieClient",
          download_client_id: "upgrade-movie-1",
          metadata: %{"upgrade_target_media_file_id" => existing_file.id}
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      new_file = Library.list_media_files() |> Enum.find(&(&1.id != existing_file.id))

      assert new_file, "expected a newly imported media file"
      assert new_file.supersedes_media_file_id == existing_file.id
    end

    # Copilot review: the per-file lookup was used for movies too, with no
    # fallback, so an unresolvable lookup left the pointer nil. A movie has one
    # target and no sibling episodes, so the cross-episode hazard that
    # justifies the no-fallback rule cannot apply to it — and a nil pointer
    # strands the upgrade, because `UpgradeFinalize` only runs for a non-nil
    # one. The old file would never be trashed, both copies would sit in the
    # library, and `Health.upgrade_health/0` counts stale pointers so it could
    # not see the stuck pair either.
    #
    # An unanalyzed target is one way to reach the empty lookup:
    # `Upgrades.current_best_file_id/2` only considers analyzed, untrashed
    # files.
    @tag :tmp_dir
    test "movie upgrade falls back to the download's target when the per-file lookup is empty",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)

      profile =
        quality_profile_fixture(%{quality_standards: %{preferred_resolutions: ["2160p"]}})

      media_item =
        media_item_fixture(%{
          type: "movie",
          title: "Unanalyzed Target Movie",
          year: 2024,
          quality_profile_id: profile.id
        })

      existing_file =
        media_file_fixture(%{
          media_item_id: media_item.id,
          resolution: "1080p",
          analyzed_at: nil
        })

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)

      File.write!(
        Path.join(download_dir, "Unanalyzed.Target.Movie.2024.2160p.mkv"),
        "new remux content"
      )

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "UnanalyzedTargetClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "UnanalyzedTargetClient",
          download_client_id: "unanalyzed-target-1",
          metadata: %{"upgrade_target_media_file_id" => existing_file.id}
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      new_file = Library.list_media_files() |> Enum.find(&(&1.id != existing_file.id))

      assert new_file, "expected a newly imported media file"

      assert new_file.supersedes_media_file_id == existing_file.id,
             "a movie upgrade must fall back to the download's target so the upgrade can finalize"
    end

    @tag :tmp_dir
    test "season pack stamps each episode's own prior file, not the download's single target",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :series)

      profile =
        quality_profile_fixture(%{quality_standards: %{preferred_resolutions: ["2160p"]}})

      show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Pack Show",
          quality_profile_id: profile.id
        })

      below_cutoff_episode =
        episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      above_cutoff_episode =
        episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      below_cutoff_file =
        media_file_fixture(%{
          episode_id: below_cutoff_episode.id,
          resolution: "480p",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      above_cutoff_file =
        media_file_fixture(%{
          episode_id: above_cutoff_episode.id,
          resolution: "2160p",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Pack.Show.S01E01.mkv"), "e1 content")
      File.write!(Path.join(download_dir, "Pack.Show.S01E02.mkv"), "e2 content")

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "UpgradePackClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: show.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "UpgradePackClient",
          download_client_id: "upgrade-pack-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2,
            # UpgradeSweep only ever tracks ONE target: the season's single
            # below-cutoff episode's file. Every imported file in this pack
            # must NOT blindly inherit this id.
            "upgrade_target_media_file_id" => below_cutoff_file.id
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      files_by_episode =
        Library.list_media_files()
        |> Enum.reject(&(&1.id in [below_cutoff_file.id, above_cutoff_file.id]))
        |> Enum.filter(&(&1.episode_id in [below_cutoff_episode.id, above_cutoff_episode.id]))
        |> Map.new(&{&1.episode_id, &1})

      new_below = Map.fetch!(files_by_episode, below_cutoff_episode.id)
      new_above = Map.fetch!(files_by_episode, above_cutoff_episode.id)

      assert new_below.supersedes_media_file_id == below_cutoff_file.id

      assert new_above.supersedes_media_file_id == above_cutoff_file.id,
             "an already-above-cutoff episode must point at its OWN prior file, not the " <>
               "download's single upgrade target, so Task 10's gate can reject the pack's " <>
               "version for it and keep the existing file"

      refute new_above.supersedes_media_file_id == below_cutoff_file.id
    end

    @tag :tmp_dir
    test "a pack episode with no existing file gets a nil supersedes pointer",
         %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :series)

      profile =
        quality_profile_fixture(%{quality_standards: %{preferred_resolutions: ["2160p"]}})

      show =
        media_item_fixture(%{
          type: "tv_show",
          title: "New Episode Pack Show",
          quality_profile_id: profile.id
        })

      existing_episode =
        episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      new_episode =
        episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      existing_file =
        media_file_fixture(%{
          episode_id: existing_episode.id,
          resolution: "480p",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "New.Episode.Pack.Show.S01E01.mkv"), "e1 content")
      File.write!(Path.join(download_dir, "New.Episode.Pack.Show.S01E02.mkv"), "e2 content")

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "NoExistingFileClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: show.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "NoExistingFileClient",
          download_client_id: "no-existing-file-1",
          metadata: %{
            "season_pack" => true,
            "season_number" => 1,
            "episode_count" => 2,
            "upgrade_target_media_file_id" => existing_file.id
          }
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      new_file_for_new_episode =
        Library.list_media_files() |> Enum.find(&(&1.episode_id == new_episode.id))

      assert new_file_for_new_episode, "expected S01E02 to import despite having no prior file"
      assert is_nil(new_file_for_new_episode.supersedes_media_file_id)
    end

    @tag :tmp_dir
    test "a non-upgrade import leaves supersedes_media_file_id nil", %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Regular.Movie.2024.1080p.mkv"), "content")

      media_item = media_item_fixture(%{type: "movie", title: "Regular Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "RegularClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "RegularClient",
          download_client_id: "regular-1"
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      new_file = Library.list_media_files() |> Enum.find(&(&1.media_item_id == media_item.id))

      assert new_file, "expected the regular movie file to import"
      assert is_nil(new_file.supersedes_media_file_id)
    end
  end

  describe "import candidate snapshot" do
    setup %{tmp_dir: tmp_dir} do
      library_path = create_test_library_path(tmp_dir, :series)
      %{library_path: library_path}
    end

    test "records every file with its skip reason when nothing is importable",
         %{tmp_dir: tmp_dir} do
      download_dir = Path.join(tmp_dir, "download")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "payload.exe"), :binary.copy(<<0>>, 4096))
      File.write!(Path.join(download_dir, "release.nfo"), "info")

      media_item = media_item_fixture(%{type: "tv_show"})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "SnapshotClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "SnapshotClient",
          download_client_id: "snapshot-1"
        })

      assert {:cancel, :no_importable_files} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      candidates = Repo.reload!(download).metadata["import_candidates"]

      assert length(candidates) == 2
      assert Enum.all?(candidates, &(&1["skip_reason"] == "not_video_extension"))
      assert Enum.find(candidates, &(&1["name"] == "payload.exe"))
      assert Repo.reload!(download).metadata["import_candidates_at"]
    end

    test "writes no snapshot when the download path does not exist", %{tmp_dir: tmp_dir} do
      media_item = media_item_fixture(%{type: "tv_show"})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "MissingPathClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "MissingPathClient",
          download_client_id: "missing-1"
        })

      # A save_path that never existed fails before the file listing succeeds
      # (`:path_not_found`), so this must never reach `process_import/3` and
      # never write a snapshot.
      assert {:error, {:path_not_found, _}} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => Path.join(tmp_dir, "missing")
               })

      refute Repo.reload!(download).metadata["import_candidates"]
    end
  end

  describe "import candidate snapshot resilience" do
    test "returns the original failure without crashing when the download row is deleted mid-job",
         %{tmp_dir: tmp_dir} do
      # Regression: the snapshot reloads the download (see the comment on
      # `fetch_current_download/1` in media_import.ex) so it merges onto the
      # freshest metadata instead of the stale struct captured before
      # `do_process_import/4` ran. If an operator dismisses the download
      # while a large import is still copying files, that reload can find
      # the row gone. `Downloads.get_download!/1` is `Repo.get!`, which
      # raises `Ecto.NoResultsError` on a missing row — unguarded, that
      # would crash the Oban job outright instead of returning the failure
      # tuple the job would have returned before this task's refactor.
      #
      # No library path is configured, so this reaches the cheapest
      # snapshot-triggering failure (`:no_library_path`) without touching
      # the filesystem-heavy `organize_and_import_files/4` path. A
      # telemetry handler on the repo's query event deletes the download
      # row the moment `determine_library_path/1` issues its
      # `library_paths` SELECT — the last DB read before the snapshot's own
      # reload — guaranteeing the row is gone by the time that reload runs.
      download_dir = Path.join(tmp_dir, "download")
      File.mkdir_p!(download_dir)
      File.write!(Path.join(download_dir, "Mystery.Show.S01E01.mkv"), "fake video content")

      media_item = media_item_fixture(%{type: "tv_show"})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "VanishingRowClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "VanishingRowClient",
          download_client_id: "vanish-1"
        })

      handler_id = {__MODULE__, :delete_download_before_snapshot_reload, download.id}

      # Telemetry handlers are global and run inside whichever process emitted
      # the event, so without this pid guard any *other* async test querying
      # `library_paths` steals the handler. The delete then runs on that
      # process's sandbox connection, where this row does not exist, and Ecto
      # raises StaleEntryError; telemetry detaches the failed handler, so the
      # row is never deleted and the assertion below fails. `perform_job/2` runs
      # the worker inline in this process, so the intended trigger still fires.
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mydia, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.source == "library_paths" and self() == test_pid do
            :telemetry.detach(handler_id)
            {:ok, _} = Mydia.Downloads.delete_download(download)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :no_library_path} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      assert_raise Ecto.NoResultsError, fn -> Mydia.Downloads.get_download!(download.id) end
    end
  end

  describe "determine_library_path/1 destination stability" do
    test "a newly added alphabetically-first library does not capture an item with existing files" do
      # Reproduces the reported bug: "Cartoons" sorts before "Movies", and
      # before this change Enum.find over path-ascending order picked it for
      # every movie, including ones whose files already lived in Movies.
      movies = library_path_fixture(%{type: "movies", path: "/tmp/zzz-Movies"})
      _cartoons = library_path_fixture(%{type: "movies", path: "/tmp/aaa-Cartoons"})

      item = media_item_fixture(%{type: "movie", title: "Old Movie", year: 2001})

      {:ok, _file} =
        Mydia.Library.create_media_file(%{
          media_item_id: item.id,
          library_path_id: movies.id,
          relative_path: "Old Movie (2001)/old.mkv",
          path: Path.join(movies.path, "Old Movie (2001)/old.mkv")
        })

      download = %Mydia.Downloads.Download{
        media_item_id: item.id,
        media_item: item,
        episode: nil,
        library_path: nil,
        library_path_id: nil
      }

      assert Mydia.Jobs.MediaImport.determine_library_path(download).id == movies.id
    end

    test "an explicit target on the media item wins" do
      _movies = library_path_fixture(%{type: "movies", path: "/tmp/aaa-Movies"})
      cartoons = library_path_fixture(%{type: "movies", path: "/tmp/zzz-Cartoons"})

      item =
        media_item_fixture(%{
          type: "movie",
          title: "Chosen Movie",
          year: 2024,
          library_path_id: cartoons.id
        })

      download = %Mydia.Downloads.Download{
        media_item_id: item.id,
        media_item: item,
        episode: nil,
        library_path: nil,
        library_path_id: nil
      }

      assert Mydia.Jobs.MediaImport.determine_library_path(download).id == cartoons.id
    end

    test "a download with no media item still resolves to a mixed library" do
      mixed = library_path_fixture(%{type: "mixed"})

      download = %Mydia.Downloads.Download{
        media_item_id: nil,
        media_item: nil,
        episode: nil,
        library_path: nil,
        library_path_id: nil
      }

      assert Mydia.Jobs.MediaImport.determine_library_path(download).id == mixed.id
    end
  end

  describe "auto_reject counter" do
    @tag :tmp_dir
    test "a successful import clears the media item's auto_reject counter", %{tmp_dir: tmp_dir} do
      # Staging copied from "falls back to save_path when client query fails"
      # — a completed download with a real video on disk and an unreachable
      # client, importing via the save_path job arg.
      _library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      video_file = Path.join(download_dir, "AutoReject.Reset.2024.1080p.mkv")
      File.write!(video_file, "fake video content")

      media_item =
        media_item_fixture(%{type: "movie", title: "AutoReject Reset Movie", year: 2024})

      Mydia.Search.record_failure("auto_reject", media_item.id, "no_importable_files")
      assert Mydia.Search.get_backoff_info("auto_reject", media_item.id)

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "AutoRejectResetClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "AutoRejectResetClient",
          download_client_id: "auto-reject-reset"
        })

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      refute Mydia.Search.get_backoff_info("auto_reject", media_item.id)
    end

    test "an import whose download row is deleted after the files land still succeeds",
         %{tmp_dir: tmp_dir} do
      # Regression for #285. `do_process_import/4` stamps `imported_at` *after*
      # `organize_and_import_files/4` has already moved the bytes into the
      # library. If an operator clears the download in that window, the stamp
      # used to raise Ecto.StaleEntryError and crash the job — so Oban retried
      # and imported the same files a second time.
      _library_path = create_test_library_path(tmp_dir, :movies)

      download_dir = Path.join(tmp_dir, "downloads")
      File.mkdir_p!(download_dir)
      video_file = Path.join(download_dir, "Vanishing.Row.2024.1080p.mkv")
      File.write!(video_file, "fake video content")

      media_item = media_item_fixture(%{type: "movie", title: "Vanishing Row Movie", year: 2024})

      {:ok, _} =
        Settings.create_download_client_config(%{
          name: "VanishingImportClient",
          type: :qbittorrent,
          host: "nonexistent.invalid",
          port: 9999,
          username: "test",
          password: "test",
          enabled: true,
          priority: 1
        })

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "completed",
          completed_at: DateTime.utc_now(),
          download_client: "VanishingImportClient",
          download_client_id: "vanishing-import"
        })

      # The job reads the download by primary key twice: once at start
      # (`fetch_download/1`) and once as `do_process_import/4`'s reload, after the
      # files are on disk. Deleting on the *second* read puts the row's
      # disappearance exactly in the window the stamp writes into. Telemetry
      # fires after the query runs, so the reload still returns a row and it is
      # the write that finds it gone.
      #
      # The SQL match stops at `."id" = ` because the placeholder that follows is
      # adapter-specific (`?` on SQLite, `$1` on Postgres).
      handler_id = {__MODULE__, :delete_after_files_land, download.id}
      test_pid = self()
      reads = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:mydia, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata.source == "downloads" and
               String.contains?(metadata.query, ~s|."id" = |) do
            :counters.add(reads, 1, 1)

            if :counters.get(reads, 1) == 2 do
              :telemetry.detach(handler_id)
              {:ok, _} = Mydia.Downloads.delete_download(download)
              send(test_pid, :deleted_after_files_landed)
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, :imported} =
               perform_job(MediaImport, %{
                 "download_id" => download.id,
                 "save_path" => download_dir
               })

      # Without this the test would pass even if the delete never fired, and so
      # would never have exercised the race.
      assert_received :deleted_after_files_landed

      # The import itself must still have completed: the file is in the library.
      assert [_media_file] = Mydia.Library.list_media_files(media_item_id: media_item.id)
    end
  end
end
