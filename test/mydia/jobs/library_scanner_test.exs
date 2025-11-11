defmodule Mydia.Jobs.LibraryScannerTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Settings
  import Mydia.MediaFixtures

  describe "perform/1" do
    test "handles non-existent library path gracefully" do
      # Create a library path that points to a non-existent directory
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/nonexistent/path/to/library",
          type: "movies",
          monitored: true
        })

      # Perform the job with the specific library path
      assert {:error, _reason} =
               perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

      # Verify the library path was updated with failed status
      updated_path = Settings.get_library_path!(library_path.id)
      assert updated_path.last_scan_status == :failed
      assert updated_path.last_scan_error =~ "Library path does not exist"
    end

    @tag timeout: 120_000
    @tag :external
    test "successfully scans library with no media items" do
      assert :ok = perform_job(LibraryScanner, %{})
    end

    @tag timeout: 120_000
    @tag :external
    test "successfully scans library with monitored media items" do
      # Create some monitored media items
      media_item_fixture(%{title: "Test Movie", type: "movie", monitored: true})
      media_item_fixture(%{title: "Test Show", type: "tv_show", monitored: false})

      assert :ok = perform_job(LibraryScanner, %{})
    end

    @tag timeout: 120_000
    @tag :external
    test "only processes monitored media items" do
      # Create monitored and unmonitored items
      monitored = media_item_fixture(%{title: "Monitored", monitored: true})
      media_item_fixture(%{title: "Not Monitored", monitored: false})

      # Job should complete successfully
      assert :ok = perform_job(LibraryScanner, %{})

      # Verify monitored item still exists (job doesn't modify items)
      assert Mydia.Media.get_media_item!(monitored.id).monitored == true
    end
  end
end
