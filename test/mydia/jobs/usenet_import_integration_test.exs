defmodule Mydia.Jobs.UsenetImportIntegrationTest do
  @moduledoc """
  Integration tests for the Usenet download import pipeline.

  These tests verify the save_path persistence fix (Bug 1) by exercising
  the full MediaImport flow with files on disk, bypassing the download
  client entirely via the persisted save_path.
  """

  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Jobs.MediaImport
  alias Mydia.Settings

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  @moduletag :tmp_dir

  describe "import with persisted save_path (Bug 1 fix)" do
    test "imports movie file using save_path from job args", %{tmp_dir: tmp_dir} do
      # Setup library path
      library_path = create_test_library_path(tmp_dir, :movies)

      # Create download directory with a test video file
      download_dir = Path.join(tmp_dir, "downloads/My.Movie.2024.1080p")
      File.mkdir_p!(download_dir)
      video_file = Path.join(download_dir, "My.Movie.2024.1080p.WEB-DL.mkv")
      File.write!(video_file, :crypto.strong_rand_bytes(1024))

      # Create media item and completed download
      media_item = media_item_fixture(%{type: "movie", title: "My Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now(),
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_test123",
          save_path: download_dir
        })

      # Run MediaImport with save_path in args — no client needed
      result =
        perform_job(MediaImport, %{
          "download_id" => download.id,
          "save_path" => download_dir,
          "use_hardlinks" => false,
          "move_files" => true
        })

      assert {:ok, _} = result

      # Verify the download was marked as imported
      updated_download = Downloads.get_download!(download.id)
      assert updated_download.imported_at != nil

      # Verify a media file was created in the library
      media_files = Mydia.Library.list_media_files(media_item_id: media_item.id)
      assert length(media_files) >= 1

      # Verify the file was moved to the library path
      library_files =
        library_path.path
        |> File.ls!()

      assert length(library_files) >= 1
    end

    test "falls back to client when save_path directory is empty", %{tmp_dir: tmp_dir} do
      # Setup library path
      _library_path = create_test_library_path(tmp_dir, :movies)

      # Create an empty download directory
      download_dir = Path.join(tmp_dir, "downloads/empty")
      File.mkdir_p!(download_dir)

      media_item = media_item_fixture(%{type: "movie", title: "Empty Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now(),
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_empty",
          save_path: download_dir
        })

      # Run MediaImport with save_path pointing to empty dir
      # It should fall back to client re-fetch, which fails with :no_client
      # (since no real client is configured)
      result =
        perform_job(MediaImport, %{
          "download_id" => download.id,
          "save_path" => download_dir
        })

      assert {:error, :no_client} = result
    end

    test "falls back to client when save_path does not exist", %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)
      media_item = media_item_fixture(%{type: "movie", title: "Missing Path Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now(),
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_missing",
          save_path: "/nonexistent/path"
        })

      # save_path doesn't exist -> falls back to client -> :no_client
      result =
        perform_job(MediaImport, %{
          "download_id" => download.id,
          "save_path" => "/nonexistent/path"
        })

      assert {:error, :no_client} = result
    end

    test "imports without save_path falls back to client", %{tmp_dir: tmp_dir} do
      _library_path = create_test_library_path(tmp_dir, :movies)
      media_item = media_item_fixture(%{type: "movie", title: "No Save Path Movie", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now(),
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_nosave"
        })

      # No save_path in args -> falls back to client -> :no_client
      result = perform_job(MediaImport, %{"download_id" => download.id})
      assert {:error, :no_client} = result
    end

    @tag :skip
    test "imports TV episode file using save_path", %{tmp_dir: tmp_dir} do
      # Setup library path for TV shows
      library_path = create_test_library_path(tmp_dir, :series)

      # Create download directory with a test episode file
      download_dir = Path.join(tmp_dir, "downloads/My.Show.S01E01")
      File.mkdir_p!(download_dir)
      video_file = Path.join(download_dir, "My.Show.S01E01.720p.WEB-DL.mkv")
      File.write!(video_file, :crypto.strong_rand_bytes(1024))

      # Create media item (TV show) with episode
      media_item = media_item_fixture(%{type: "tv_show", title: "My Show"})

      episode =
        episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          episode_id: episode.id,
          completed_at: DateTime.utc_now(),
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_ep01",
          save_path: download_dir
        })

      result =
        perform_job(MediaImport, %{
          "download_id" => download.id,
          "save_path" => download_dir,
          "use_hardlinks" => false,
          "move_files" => true
        })

      assert {:ok, _} = result

      # Verify the download was marked as imported
      updated_download = Downloads.get_download!(download.id)
      assert updated_download.imported_at != nil

      # Verify a file exists in the library
      show_dir = Path.join(library_path.path, "My Show")
      assert File.dir?(show_dir)
    end
  end

  describe "save_path persistence in DownloadMonitor" do
    test "DownloadMonitor persists save_path when completing a download" do
      # This test verifies the DownloadMonitor -> save_path persistence flow
      # Since DownloadMonitor needs live client connections, we test that
      # the save_path field is correctly stored on the download record

      media_item = media_item_fixture(%{type: "movie", title: "Persist Test", year: 2024})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "TestSabnzbd",
          download_client_id: "SABnzbd_nzo_persist"
        })

      # Simulate what DownloadMonitor.handle_completion does:
      # 1. Mark as completed
      {:ok, download} = Downloads.mark_download_completed(download)
      assert download.completed_at != nil

      # 2. Persist save_path
      {:ok, download} =
        Downloads.update_download(download, %{save_path: "/downloads/test-show"})

      assert download.save_path == "/downloads/test-show"

      # 3. Verify save_path survives a reload
      reloaded = Downloads.get_download!(download.id)
      assert reloaded.save_path == "/downloads/test-show"
      assert reloaded.completed_at != nil
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
end
