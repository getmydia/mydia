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

    {:ok, dir: dir, library_path: library_path, run: run, user: user}
  end

  # `attempt` and `max_attempts` are load-bearing on every job built here: a
  # failure is only terminal on the last attempt, because Oban still holds
  # retries before that and a :failed row would let the user start a second,
  # concurrent coordinator for the same library path.
  defp job(run_id, attempt, max_attempts \\ 3) do
    %Oban.Job{
      args: %{"import_run_id" => run_id},
      attempt: attempt,
      max_attempts: max_attempts
    }
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

    test "tolerates duplicate rows for one path without crashing or adding more", %{
      run: run,
      library_path: lp
    } do
      # The data anomaly that used to strand a run: two builds of the scanner
      # (or a scanner racing the import coordinator) created two rows for the
      # same relative path. get_media_file_by_relative_path/3 raised
      # Ecto.MultipleResultsError here, which Oban discarded after retries,
      # leaving the run row :running forever.
      relative_path = "Season 01/Bluey.S01E01.mkv"

      for _ <- 1..2 do
        {:ok, _} =
          Library.create_scanned_media_file(%{
            library_path_id: lp.id,
            relative_path: relative_path,
            size: 1,
            verified_at: DateTime.utc_now()
          })
      end

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      files = Library.list_media_files(library_path_id: lp.id)
      assert Enum.count(files, &(&1.relative_path == relative_path)) == 2
    end

    test "broadcasts the path being scanned", %{run: run} do
      Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      # The scanner reports every directory it enters and every file it finds,
      # relative to the library root, so the page can show what "Finding files"
      # is looking at. The exact set depends on File.ls ordering, so assert the
      # shapes rather than a specific sequence.
      paths =
        receive_scan_paths([])

      assert "Season 01" in paths
      assert "Season 01/Bluey.S01E01.mkv" in paths
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

      assert {:error, :not_found} = ImportRunJob.perform(job(run.id, 3))

      assert_receive {:import_run_progress, %{status: :failed} = broadcast_run}
      assert broadcast_run.error =~ "not_found"

      persisted = Library.get_import_run(run.id)
      assert persisted.status == :failed
      assert persisted.error =~ "not_found"
    end

    test "keeps the run active while Oban still holds retries", %{
      run: run,
      dir: dir,
      library_path: lp
    } do
      File.rm_rf!(dir)

      assert {:error, :not_found} = ImportRunJob.perform(job(run.id, 1))

      # Still :running, for two reasons. The user should not be told "Import
      # failed" while the system is about to try again, and more importantly
      # a terminal row makes active_import_run/1 return nil, which would let
      # them start a SECOND coordinator against this path while the first is
      # queued for retry. The partial unique index guards import_runs rows,
      # not Oban jobs, so nothing else would stop that.
      assert Library.get_import_run(run.id).status == :running
      assert Library.active_import_run(lp.id)
    end
  end

  describe "library types that cannot be imported" do
    # This guard used to be reachable: music, books and adult paths were real
    # enum values that run_scan_phase/2 had to turn away, because nothing
    # downstream (inbox_base_query/1, MediaFile.library_type_compatible?/3)
    # restricts by library type, so an unattended run over one could link a
    # track to a movie item. Those types are gone, and no constructible
    # library path is refused any more -- library_path_fixture cannot even
    # build one, since the changeset validates against the same enum.
    #
    # So the guard is now covered where it can be: the pure predicate, and a
    # tripwire on the enum. Adding a library type whose files are not movies
    # or episodes fails here and has to decide what import means for it.
    test "the importable allow-list still covers every type the schema allows" do
      assert Enum.sort(Ecto.Enum.values(Mydia.Settings.LibraryPath, :type)) ==
               Enum.sort(Mydia.Library.ImportRun.importable_types())
    end

    test "the scan-phase guard still refuses a type outside the allow-list" do
      refute Mydia.Library.ImportRun.importable_type?(:music)
      refute Mydia.Library.ImportRun.importable_type?(:some_future_type)
    end
  end

  describe "list_unmatched_media_file_paths/2" do
    test "returns files with no candidate and no parent", %{run: run, library_path: lp} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 3
    end

    test "excludes a file whose failure is still inside its retry window", %{
      run: run,
      library_path: lp
    } do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      [{file_id, _path} | _] = Library.list_unmatched_media_file_paths(lp.id, 100)

      # Mirrors what `FileIngest.record_failure/2` actually writes on a first
      # attempt: a rank-0 candidate with `next_retry_at` in the future. A
      # candidate with `next_retry_at` unset is a different case (a
      # pre-existing failure predating the backoff, or one written outside
      # `record_failure/2`) and is deliberately still eligible -- see
      # `Library.list_unmatched_media_file_paths/2`'s moduledoc.
      future = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Library.upsert_match_candidate(%{
          media_file_id: file_id,
          rank: 0,
          attempts: 1,
          next_retry_at: future
        })

      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 2
    end
  end

  # Drains the scan-progress messages `run_scan_phase/2` already broadcast
  # into the test process's mailbox (the scan is synchronous, so they are all
  # queued by the time this runs). The short timeout only bounds an empty
  # mailbox, not a slow scan.
  defp receive_scan_paths(acc) do
    receive do
      {:import_run_current_file, path} -> receive_scan_paths([path | acc])
    after
      200 -> acc
    end
  end
end
