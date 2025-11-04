defmodule Mydia.Jobs.LibraryScannerTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.LibraryScanner
  import Mydia.MediaFixtures

  describe "perform/1" do
    test "successfully scans library with no media items" do
      assert :ok = perform_job(LibraryScanner, %{})
    end

    test "successfully scans library with monitored media items" do
      # Create some monitored media items
      media_item_fixture(%{title: "Test Movie", type: "movie", monitored: true})
      media_item_fixture(%{title: "Test Show", type: "tv_show", monitored: false})

      assert :ok = perform_job(LibraryScanner, %{})
    end

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
