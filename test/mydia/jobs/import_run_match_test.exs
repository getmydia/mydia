defmodule Mydia.Jobs.ImportRunMatchTest do
  @moduledoc """
  async: false because it shares the global metadata ETS cache and Bypass.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.InvalidCandidateMatcher
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Metadata.Cache

  setup do
    # Mydia.Metadata.Cache is global, named ETS with a 1-hour TTL and no other
    # test-suite reset. Its key (Metadata.search_cached/3, metadata.ex:159) is
    # "search:<provider>:<query>:<media_type>:<year>:<language>:<page>" -- it
    # does NOT include base_url. So a cache entry left behind by an earlier
    # test with the same title/year would make a search skip the HTTP layer
    # entirely, regardless of whether :config below is wired correctly. Clear
    # on the way in and the way out, same idiom as
    # test/mydia/library/batch_matcher_test.exs and
    # test/support/metadata_stub.ex. Do NOT delete by hand-computed key:
    # Task 5 tried that and the key silently desynced the moment a stub's
    # response shape changed which of MetadataMatcher's search branches ran.
    Cache.clear()
    on_exit(fn -> Cache.clear() end)

    bypass = Bypass.open()

    # Counts requests that actually land on THIS local Bypass server. This is
    # the only way to tell "the seam is wired to Bypass" apart from "the seam
    # silently fell through to Metadata.default_relay_config/0's real
    # https://relay.mydia.dev" or "the cache above was stale and skipped HTTP
    # altogether" -- every business-observable assertion in this file (a
    # candidate got written, files_matched incremented, nothing got linked)
    # is identical in all three cases, because FileIngest.ingest/3 records a
    # candidate identically for a real match, a {:error, _}, and a nil match,
    # and Bypass.stub (unlike Bypass.expect) never fails a test that received
    # zero requests. A real HTTP call to relay.mydia.dev can never increment
    # this in-process counter, so counter > 0 is airtight proof of local
    # interception, and counter == 0 is airtight proof no network call was
    # attempted at all.
    counter = :counters.new(1, [:atomics])

    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
    end)

    # Injected directly into run_match_phase/2 rather than mutating the global
    # METADATA_RELAY_URL env var, matching the convention used elsewhere (see
    # test/mydia/media/refresh_test.exs and test/mydia/media_test.exs): a
    # global env mutation would race any async test resolving the default
    # relay config concurrently. Without this, run_match_phase/2's internal
    # default (Metadata.default_relay_config/0) would try to reach the real
    # https://relay.mydia.dev instead of this Bypass server.
    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    dir = Path.join(System.tmp_dir!(), "import_match_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for n <- 1..5 do
      File.write!(Path.join(dir, "Some.Movie.#{2000 + n}.1080p.mkv"), "x")
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    library_path = library_path_fixture(%{path: dir, type: "movies"})

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: library_path.id,
        user_id: user_fixture().id,
        mode: :review
      })

    :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

    {:ok,
     bypass: bypass,
     config: config,
     counter: counter,
     dir: dir,
     library_path: library_path,
     run: run}
  end

  test "writes a candidate for every unmatched file", %{
    run: run,
    library_path: lp,
    config: config,
    counter: counter
  } do
    assert :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    assert Library.list_unmatched_media_file_paths(lp.id, 100) == []

    # Proves the search actually landed on the local Bypass server rather
    # than falling through to the real relay or being served from a stale
    # cache entry -- every assertion above would look identical in either of
    # those cases.
    assert :counters.get(counter, 1) > 0
  end

  test "records the matched count on the run", %{run: run, config: config, counter: counter} do
    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    assert Library.get_import_run(run.id).files_matched == 5
    assert :counters.get(counter, 1) > 0
  end

  test "review mode creates no new items from external matches", %{
    run: run,
    library_path: lp,
    config: config,
    counter: counter
  } do
    # Review mode uses the :local_only policy, so it will still associate a
    # file whose show already exists in the library. What it must never do is
    # create a NEW item from an external provider match: that is the judgement
    # call the human is here to make. This fixture library has no local items,
    # so nothing should be linked at all.
    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    files = Library.list_media_files(library_path_id: lp.id)
    assert Enum.all?(files, &is_nil(&1.media_item_id))
    assert Library.get_import_run(run.id).files_linked == 0

    # Every file got a candidate instead, which is the inbox handoff.
    assert Library.count_inbox_files(library_path_id: lp.id) == 5

    # Confirms these are candidates from an actual (empty) relay search, not
    # a coincidence of :review mode never linking regardless of what the
    # relay would have returned.
    assert :counters.get(counter, 1) > 0
  end

  test "stops at the chunk boundary when asked", %{run: run, config: config, counter: counter} do
    {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))

    assert :stopped = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    # The stop is checked before the first chunk is ever pulled, so no search
    # should reach the relay at all -- the mirror-image proof to the > 0
    # assertions elsewhere in this file.
    assert :counters.get(counter, 1) == 0
  end

  test "a resumed run does not re-match files that already have candidates", %{
    run: run,
    library_path: lp,
    config: config,
    counter: counter
  } do
    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    before = Library.get_import_run(run.id).files_matched
    first_run_calls = :counters.get(counter, 1)
    assert first_run_calls > 0

    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    # Nothing left to do, so the counter does not move.
    assert Library.get_import_run(run.id).files_matched == before
    assert Library.list_unmatched_media_file_paths(lp.id, 100) == []

    # And no new relay traffic was generated by the second call either: this
    # is the same "resume skips relay work already paid for" property, proven
    # against actual network activity rather than only against the DB state
    # that activity happens to produce.
    assert :counters.get(counter, 1) == first_run_calls
  end

  test "keeps candidates a chunk already committed when a stop lands mid-match, and a resumed run finishes the rest",
       %{run: run, dir: dir, library_path: lp, config: config, counter: counter} do
    # @match_chunk_size is 50, so this forces a second match_loop iteration to
    # exist: without it, a stop could only ever be observed before the first
    # (and only) chunk, which is the already-covered "stops at the chunk
    # boundary when asked" case above, not this one. That test proves a stop
    # requested up front is honored; it says nothing about whether a chunk
    # that already committed survives a stop requested after it.
    for n <- 1..50 do
      File.write!(Path.join(dir, "Extra.Movie.#{3000 + n}.1080p.mkv"), "x")
    end

    :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

    total_unmatched = length(Library.list_unmatched_media_file_paths(lp.id, 1000))
    assert total_unmatched == 55

    # Requesting the stop from inside :after_chunk runs it synchronously in
    # the same call stack as run_match_phase/2, right after the first chunk's
    # candidates commit and strictly before the loop's next stopping-check
    # reads the run row. That ordering is a program-counter guarantee, not a
    # race against a concurrent process or a sleep: import_run_stopping?/1 is
    # a fresh DB read, and this write is guaranteed to have already happened
    # by the time that read runs. Mirrors run_scan_phase/2's proven pattern
    # (test/mydia/jobs/import_run_job_test.exs).
    stop_after_first_chunk = fn ->
      {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))
    end

    assert :stopped =
             ImportRunJob.run_match_phase(Library.get_import_run(run.id),
               config: config,
               after_chunk: stop_after_first_chunk
             )

    partial_matched = Library.get_import_run(run.id).files_matched
    remaining = length(Library.list_unmatched_media_file_paths(lp.id, 1000))

    # Both halves matter: >0 proves the first chunk's candidates were not
    # rolled back, <total proves the stop actually cut the match phase short
    # rather than the run simply finishing all 55 in one pass.
    assert partial_matched > 0
    assert partial_matched < total_unmatched
    assert remaining == total_unmatched - partial_matched

    # The chunk that committed did real (local) relay work -- this is not a
    # trivially-true :ok/:stopped return with an empty chunk underneath it.
    calls_before_resume = :counters.get(counter, 1)
    assert calls_before_resume > 0

    # Mirror what the real coordinator does on :stopped (Jobs.ImportRun.finish/2):
    # the run becomes terminal, which is what lets a fresh run be started for
    # the same library path (a :stopping run is still "active" and blocks a
    # second one).
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

    assert :ok =
             ImportRunJob.run_match_phase(Library.get_import_run(resumed_run.id), config: config)

    # Every file the first (interrupted) run committed a candidate for is
    # untouched by the resume: only the remainder got matched again.
    assert Library.get_import_run(resumed_run.id).files_matched == remaining

    # And the resume did its own real relay work rather than, say, replaying
    # cached results for the whole library -- the counter keeps climbing.
    assert :counters.get(counter, 1) > calls_before_resume
    assert Library.list_unmatched_media_file_paths(lp.id, 1000) == []
  end

  describe "the progress contract backstop" do
    test "fails the run instead of reporting :ok when a file is left with neither a parent nor a candidate",
         %{run: run, library_path: lp} do
      # InvalidCandidateMatcher's confidence is outside MatchCandidate.changeset/2's
      # valid range, so Library.upsert_match_candidate/1 genuinely rejects the
      # write and FileIngest.ingest/3 returns
      # {:error, {:candidate_write_failed, _}} for every file in this run's
      # single chunk -- each one left with no parent and no candidate, which
      # is exactly the progress-contract violation
      # verify_match_phase_complete/2 exists to catch once the keyset walk
      # (which never re-visits a chunk's ids once it has advanced past them)
      # reports the phase done regardless.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:files_outstanding, message}} =
                   ImportRunJob.run_match_phase(Library.get_import_run(run.id),
                     matcher: InvalidCandidateMatcher
                   )

          assert message =~ "5 file(s)"
          assert message =~ "still outstanding"
        end)

      assert log =~ "count=5"
      assert log =~ "media_file_ids="

      # Not just a message: the files really are still there, unmatched, so
      # the run's failure reflects real stuck state rather than a check that
      # fired on stale information.
      assert length(Library.list_unmatched_media_file_paths(lp.id, 100)) == 5
    end
  end
end
