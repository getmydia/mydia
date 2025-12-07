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

    test "handles missing library path ID gracefully" do
      # Try to scan a non-existent library path
      fake_id = Ecto.UUID.generate()

      assert_raise Ecto.NoResultsError, fn ->
        perform_job(LibraryScanner, %{"library_path_id" => fake_id})
      end
    end

    test "handles scan with no monitored library paths" do
      # Create an unmonitored library path
      {:ok, _library_path} =
        Settings.create_library_path(%{
          path: "/some/path",
          type: "movies",
          monitored: false
        })

      # Job should complete successfully even with no monitored paths
      assert :ok = perform_job(LibraryScanner, %{})
    end

    test "handles path that is not a directory" do
      # Create a temporary file
      temp_path =
        Path.join(System.tmp_dir!(), "test_file_#{System.unique_integer([:positive])}.txt")

      File.write!(temp_path, "test content")

      try do
        {:ok, library_path} =
          Settings.create_library_path(%{
            path: temp_path,
            type: "movies",
            monitored: true
          })

        # Perform the job
        assert {:error, _reason} =
                 perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

        # Verify the library path was updated with failed status
        updated_path = Settings.get_library_path!(library_path.id)
        assert updated_path.last_scan_status == :failed
        assert updated_path.last_scan_error =~ "not a directory"
      after
        File.rm(temp_path)
      end
    end

    test "broadcasts scan started event" do
      # Subscribe to the library_scanner topic
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")

      # Create a library path with a non-existent directory (will fail quickly)
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/nonexistent/broadcast/test/path",
          type: "movies",
          monitored: true
        })

      expected_id = library_path.id

      # Run the job
      perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

      # Should receive scan started message
      assert_receive {:library_scan_started, %{library_path_id: ^expected_id}}
    end

    test "broadcasts scan failed event on error" do
      # Subscribe to the library_scanner topic
      Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")

      # Create a library path with a non-existent directory
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/nonexistent/broadcast/test/path2",
          type: "movies",
          monitored: true
        })

      expected_id = library_path.id

      # Run the job
      perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

      # Should receive scan failed message
      assert_receive {:library_scan_failed, %{library_path_id: ^expected_id, error: _}}
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

  describe "new/2" do
    test "creates a valid job changeset without library_path_id" do
      changeset = LibraryScanner.new(%{})
      assert changeset.valid?
      assert changeset.changes.queue == "media"
    end

    test "creates a valid job changeset with library_path_id" do
      id = Ecto.UUID.generate()
      changeset = LibraryScanner.new(%{"library_path_id" => id})
      assert changeset.valid?
      assert changeset.changes.args["library_path_id"] == id
    end
  end
end
