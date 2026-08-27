defmodule Mydia.Jobs.LibraryScannerTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Accounts.Scope
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
      assert Mydia.Media.get_media_item!(Scope.unrestricted(), monitored.id).monitored == true
    end

    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    for type <- ["movies", "series", "mixed"] do
      test "completes a scan of a #{type} library path" do
        {:ok, library_path} =
          Settings.create_library_path(%{
            path: empty_library_dir(),
            type: unquote(type),
            monitored: true
          })

        assert :ok = perform_job(LibraryScanner, %{"library_path_id" => library_path.id})
        assert Settings.get_library_path!(library_path.id).last_scan_status == :success
      end
    end
  end

  defp empty_library_dir do
    path = Path.join(System.tmp_dir!(), "mydia_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
