defmodule Mydia.Jobs.ImportRunJobTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Jobs.ImportRun, as: ImportRunJob

  setup do
    dir = Path.join(System.tmp_dir!(), "import_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "Season 01"))

    for ep <- 1..3 do
      path =
        Path.join([dir, "Season 01", "Bluey.S01E0#{ep}.mkv"])

      File.write!(path, "x")
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    library_path = library_path_fixture(%{path: dir, type: "series"})
    user = user_fixture()

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: library_path.id,
        user_id: user.id,
        mode: :review
      })

    {:ok, dir: dir, library_path: library_path, run: run}
  end

  describe "phase 1: scanning" do
    test "commits a media_file row for every discovered file", %{run: run, library_path: lp} do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      files = Library.list_media_files(library_path_id: lp.id)
      assert length(files) == 3
    end

    test "records the discovered count on the run", %{run: run} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Library.get_import_run(run.id).files_discovered == 3
    end

    test "is idempotent, so a resumed run creates no duplicates", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert length(Library.list_media_files(library_path_id: lp.id)) == 3
    end

    test "stops when a stop was requested", %{run: run} do
      {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))

      assert :stopped = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
    end

    test "keeps rows a batch already committed when a stop lands mid-scan, and a resumed run finishes the rest",
         %{run: run, dir: dir, library_path: lp} do
      # @scan_batch_size is 100, so this forces a second reduce_while
      # iteration to exist: without it, a stop could only ever be observed
      # before the first (and only) batch, which is the already-covered
      # "stops when a stop was requested" case above, not this one.
      season_two = Path.join(dir, "Season 02")
      File.mkdir_p!(season_two)

      for ep <- 1..150 do
        padded = ep |> Integer.to_string() |> String.pad_leading(3, "0")
        File.write!(Path.join(season_two, "Bluey.S02E#{padded}.mkv"), "x")
      end

      total_on_disk = 3 + 150

      # Requesting the stop from inside :after_batch runs it synchronously in
      # the same call stack as run_scan_phase/2, right after the first batch
      # commits and strictly before the loop's next stopping-check reads the
      # run row. That ordering is a program-counter guarantee, not a race
      # against a concurrent process or a sleep: import_run_stopping?/1 is a
      # fresh DB read, and this write is guaranteed to have already happened
      # by the time that read runs.
      stop_after_first_batch = fn ->
        {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))
      end

      assert :stopped =
               ImportRunJob.run_scan_phase(Library.get_import_run(run.id),
                 after_batch: stop_after_first_batch
               )

      partial_count = length(Library.list_media_files(library_path_id: lp.id))

      # Both halves matter: >0 proves the first batch's commit was not rolled
      # back, <total proves the stop actually cut the scan short rather than
      # the run simply finishing.
      assert partial_count > 0
      assert partial_count < total_on_disk

      # Mirror what the real coordinator does on :stopped
      # (Mydia.Jobs.ImportRun.finish/2): the run becomes terminal, which is
      # what lets a fresh run be started for the same library path (a
      # :stopping run is still "active" and blocks a second one).
      {:ok, _} =
        Library.update_import_run(Library.get_import_run(run.id), %{
          status: :stopped,
          phase: :finished
        })

      {:ok, resumed_run} =
        Library.create_import_run(%{
          library_path_id: lp.id,
          user_id: run.user_id,
          mode: :review
        })

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(resumed_run.id))

      final_count = length(Library.list_media_files(library_path_id: lp.id))
      assert final_count == total_on_disk
    end
  end

  describe "failure" do
    test "broadcasts the failure so a subscribed LiveView can react", %{run: run, dir: dir} do
      Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))

      # Removing the scan root out from under the run makes Scanner.scan/2's
      # validate_directory/1 fail, driving execute/1's {:error, reason}
      # branch (perform/1's only route to it) without faking anything deeper
      # in the pipeline. on_exit already rm_rf's dir, so this is a no-op by
      # the time that runs.
      File.rm_rf!(dir)

      assert {:error, :not_found} =
               ImportRunJob.perform(%Oban.Job{args: %{"import_run_id" => run.id}})

      assert_receive {:import_run_progress, %{status: :failed} = broadcast_run}
      assert broadcast_run.error =~ "not_found"

      persisted = Library.get_import_run(run.id)
      assert persisted.status == :failed
      assert persisted.error =~ "not_found"
    end
  end

  describe "list_unmatched_media_file_paths/2" do
    test "returns files with no candidate and no parent", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 3
    end

    test "excludes a file that already carries a candidate", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      [{file_id, _path} | _] = Library.list_unmatched_media_file_paths(lp.id, 100)

      {:ok, _} =
        Library.upsert_match_candidate(%{media_file_id: file_id, rank: 0, attempts: 1})

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 2
    end
  end
end
