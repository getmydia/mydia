defmodule Mydia.Jobs.ImportRunJobTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library
  alias Mydia.Library.ImportCandidate
  alias Mydia.Library.MediaFile
  alias Mydia.Library.SelectionScope
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
    test "upserts an import candidate for every discovered file, creating no media files", %{
      run: run
    } do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Repo.aggregate(ImportCandidate, :count) == 3
      assert Repo.aggregate(MediaFile, :count) == 0
    end

    test "records the discovered count on the run", %{run: run} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Library.get_import_run(run.id).files_discovered == 3
    end

    test "is idempotent, so a resumed run creates no duplicates", %{run: run} do
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
      :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Repo.aggregate(ImportCandidate, :count) == 3
    end

    test "skips a path already owned by a parented media file", %{run: run, library_path: lp} do
      # A real ownership decision made outside this run entirely (a prior
      # accept, a local show, a scanner link) must not be revisited: the file
      # already belongs to something, and `media_files` now enforces (via a
      # database CHECK) that it can never go back to being parentless.
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      {:ok, _parented} =
        Library.create_media_file(%{
          library_path_id: lp.id,
          relative_path: "Season 01/Bluey.S01E01.mkv",
          episode_id: episode.id,
          size: 1_000
        })

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Repo.aggregate(ImportCandidate, :count) == 2
      assert ImportCandidates.get_by_path(lp.id, "Season 01/Bluey.S01E01.mkv") == nil
      assert Library.get_import_run(run.id).files_discovered == 2
    end

    test "tolerates duplicate parented rows for one path without crashing, and still skips it",
         %{run: run, library_path: lp} do
      # The data anomaly that used to strand a run: two builds of the scanner
      # (or a scanner racing the import coordinator) created two rows for the
      # same relative path. `get_media_file_by_relative_path/3` raises
      # `Ecto.MultipleResultsError` on that shape, which Oban discarded after
      # retries, leaving the run row :running forever -- this is why phase 1
      # checks ownership with the duplicate-safe
      # `list_media_files_by_relative_path/3` instead.
      relative_path = "Season 01/Bluey.S01E01.mkv"
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      for _ <- 1..2 do
        {:ok, _} =
          Library.create_media_file(%{
            library_path_id: lp.id,
            relative_path: relative_path,
            episode_id: episode.id,
            size: 1_000
          })
      end

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      assert Repo.aggregate(ImportCandidate, :count) == 2
      assert ImportCandidates.get_by_path(lp.id, relative_path) == nil
    end

    test "stops when a stop was requested", %{run: run} do
      {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))

      assert :stopped = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))
    end

    test "keeps candidates a batch already committed when a stop lands mid-scan, and a resumed run finishes the rest",
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

      partial_count = Repo.aggregate(ImportCandidate, :count)

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

      final_count = Repo.aggregate(ImportCandidate, :count)
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
    # downstream (the old review inbox query, MediaFile.library_type_compatible?/3)
    # restricts by library type, so an unattended run over one could link a
    # track to a movie. Those types are gone, and no constructible
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

  describe "a dismissed candidate survives a rescan" do
    test "dismissed_at is preserved across the whole scan and match phases", %{
      run: run,
      library_path: lp
    } do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      candidate = ImportCandidates.get_by_path(lp.id, "Season 01/Bluey.S01E01.mkv")

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page([candidate.anchor_key])
      assert {:ok, 3} = ImportCandidates.dismiss(scope)

      # Rerunning phase 1 must not resurrect the dismissal, whether or not
      # anything else about the path changed.
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      for ep <- 1..3 do
        reloaded = ImportCandidates.get_by_path(lp.id, "Season 01/Bluey.S01E0#{ep}.mkv")
        refute is_nil(reloaded.dismissed_at)
      end

      # And phase 2 must never pick a dismissed candidate back up.
      assert :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id))
      assert Library.get_import_run(run.id).files_matched == 0

      for ep <- 1..3 do
        reloaded = ImportCandidates.get_by_path(lp.id, "Season 01/Bluey.S01E0#{ep}.mkv")
        refute is_nil(reloaded.dismissed_at)
        assert is_nil(reloaded.provider_id)
      end
    end
  end

  describe "rescanning a file that already carries a match and retry state" do
    setup %{run: run, library_path: lp} do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      relative_path = "Season 01/Bluey.S01E01.mkv"

      future_retry =
        DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      # Stamps the same shape `FileIngest.candidate_attrs/2` and
      # `record_failure/2` would after a real match attempt: a provider match
      # plus a failure history sitting alongside it, exactly what
      # `candidate_scan_attrs/4`'s clearing branch has to blow away and its
      # preserving branch has to leave alone.
      {:ok, matched} =
        ImportCandidates.upsert(%{
          library_path_id: lp.id,
          relative_path: relative_path,
          provider_type: "tmdb",
          provider_id: "603",
          title: "Some Match",
          year: 1999,
          confidence: 0.5,
          attempts: 2,
          last_error: "no_match",
          next_retry_at: future_retry
        })

      refute is_nil(matched.provider_id)

      {:ok, relative_path: relative_path}
    end

    test "an unchanged file preserves the match and retry state on rescan", %{
      run: run,
      library_path: lp,
      relative_path: relative_path
    } do
      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      reloaded = ImportCandidates.get_by_path(lp.id, relative_path)
      assert reloaded.provider_id == "603"
      assert reloaded.provider_type == "tmdb"
      assert reloaded.title == "Some Match"
      assert reloaded.confidence == 0.5
      assert reloaded.attempts == 2
      assert reloaded.last_error == "no_match"
      refute is_nil(reloaded.next_retry_at)
    end

    test "a changed file size clears the match and retry state on rescan", %{
      run: run,
      dir: dir,
      library_path: lp,
      relative_path: relative_path
    } do
      # The setup files are all written as the single byte "x"; anything
      # longer changes size without necessarily changing mtime precision,
      # isolating the size half of content_changed?/3's `or`.
      File.write!(Path.join(dir, relative_path), "a file that is no longer one byte")

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      reloaded = ImportCandidates.get_by_path(lp.id, relative_path)
      assert is_nil(reloaded.provider_id)
      assert is_nil(reloaded.provider_type)
      assert is_nil(reloaded.title)
      assert is_nil(reloaded.year)
      assert is_nil(reloaded.confidence)
      assert reloaded.attempts == 0
      assert is_nil(reloaded.last_error)
      assert is_nil(reloaded.next_retry_at)
    end

    test "a changed mtime alone, same size, also clears the match and retry state", %{
      run: run,
      dir: dir,
      library_path: lp,
      relative_path: relative_path
    } do
      # Same one-byte content as the original write -- only the mtime moves,
      # isolating mtime_differs?/2 from the size comparison entirely.
      File.touch!(Path.join(dir, relative_path), System.os_time(:second) + 3_600)

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      reloaded = ImportCandidates.get_by_path(lp.id, relative_path)
      assert is_nil(reloaded.provider_id)
      assert reloaded.attempts == 0
      assert is_nil(reloaded.next_retry_at)
    end

    test "a dismissal survives a size-triggered clear of the match and retry state", %{
      run: run,
      dir: dir,
      library_path: lp,
      relative_path: relative_path
    } do
      candidate = ImportCandidates.get_by_path(lp.id, relative_path)
      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_page([candidate.anchor_key])
      assert {:ok, 3} = ImportCandidates.dismiss(scope)

      File.write!(Path.join(dir, relative_path), "a file that is no longer one byte")

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      reloaded = ImportCandidates.get_by_path(lp.id, relative_path)
      refute is_nil(reloaded.dismissed_at)
      assert is_nil(reloaded.provider_id)
      assert reloaded.attempts == 0
      assert is_nil(reloaded.last_error)
      assert is_nil(reloaded.next_retry_at)
    end

    test "a candidate with no stored mtime is not treated as changed, so its match survives a rescan",
         %{run: run, library_path: lp, relative_path: relative_path} do
      # Mirrors a candidate written by a path that never set mtime (e.g.
      # `ImportCandidates.demote_episode_files/1`): there is nothing to
      # compare the real file's mtime against, so mtime_differs?/2 must not
      # treat that absence as proof of a change.
      {:ok, _} =
        ImportCandidates.upsert(%{
          library_path_id: lp.id,
          relative_path: relative_path,
          mtime: nil
        })

      before_rescan = ImportCandidates.get_by_path(lp.id, relative_path)
      assert is_nil(before_rescan.mtime)
      assert before_rescan.provider_id == "603"

      assert :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

      reloaded = ImportCandidates.get_by_path(lp.id, relative_path)
      assert reloaded.provider_id == "603"
      assert reloaded.attempts == 2
      assert reloaded.next_retry_at == before_rescan.next_retry_at

      # Phase 1 always refreshes mtime in its base attrs, changed or not, so
      # the backfill itself is real -- this isn't passing because nothing
      # was written at all.
      refute is_nil(reloaded.mtime)
    end
  end
end
