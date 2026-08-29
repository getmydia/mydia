defmodule Mydia.Jobs.LibraryScannerTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library.ScanSummary
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

  describe "reconcile_sidecars?/1" do
    test "true only when the scan summary is a success" do
      assert LibraryScanner.reconcile_sidecars?({:ok, %ScanSummary{}})
    end

    test "false when the filesystem scan failed" do
      refute LibraryScanner.reconcile_sidecars?({:error, "Library path does not exist: /gone"})
    end

    test "false when process_scan_result/2 raised internally and its own rescue converted that into an error" do
      # scan_library_path/1 always feeds this guard whatever
      # summarize(process_scan_result(library_path, scan_result)) produced,
      # and process_scan_result/2 has its own pre-existing rescue that turns
      # an internal exception into handle_scan_error/2's {:error, message}
      # rather than letting it propagate. That is indistinguishable, from
      # this guard's perspective, from the filesystem scan itself failing:
      # both arrive as a plain {:error, _} tuple, and both must refuse
      # reconciliation. Reaching that rescue for real would mean finding a
      # raise that survives every self-rescuing helper
      # process_scan_result/2 calls (fix_orphaned_tv_file/2,
      # revalidate_tv_file_association/1, associate_file_with_episode/2,
      # match_file_to_existing_items/4), so this pins the guard against the
      # same shape handle_scan_error/2 actually returns instead.
      refute LibraryScanner.reconcile_sidecars?(
               {:error, Exception.format(:error, %RuntimeError{message: "boom"}, [])}
             )
    end
  end

  describe "sidecar reconciliation" do
    test "a scan adopts a sidecar sitting beside a scanned video" do
      dir = empty_library_dir()

      # A TV-shaped filename inside a movies-only library path trips the
      # existing type-mismatch guard in process_media_file/3, so metadata
      # enrichment (and any real network call to the metadata relay) is
      # skipped. The media_file row is still created before enrichment ever
      # runs, which is all sidecar reconciliation needs.
      File.write!(Path.join(dir, "Show.S01E01.mkv"), "not really a video")

      File.write!(Path.join(dir, "Show.S01E01.en.srt"), """
      1
      00:00:01,000 --> 00:00:02,000
      Hello.
      """)

      {:ok, library_path} =
        Settings.create_library_path(%{path: dir, type: "movies", monitored: true})

      assert :ok = perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

      assert [media_file] = Mydia.Library.list_media_files(library_path_id: library_path.id)

      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert subtitle.origin == "sidecar"
      assert subtitle.language == "en"
    end
  end

  defp empty_library_dir do
    path = Path.join(System.tmp_dir!(), "mydia_scan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  describe "ScanSummary auto_linked" do
    test "defaults to zero so a scan that imported nothing reports nothing" do
      assert %ScanSummary{}.auto_linked == 0
    end

    test "carries a count independent of the new-file count" do
      summary = %ScanSummary{new_files: 5, auto_linked: 2}

      assert summary.auto_linked == 2
      assert summary.new_files == 5
    end
  end
end
