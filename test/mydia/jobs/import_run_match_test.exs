defmodule Mydia.Jobs.ImportRunMatchTest do
  @moduledoc """
  async: false because it shares the global metadata ETS cache and Bypass.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Jobs.ImportRun, as: ImportRunJob

  setup do
    bypass = Bypass.open()

    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
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
    # https://relay.mydia.dev instead of this Bypass server, and Bypass.stub
    # (unlike Bypass.expect) never fails a test that received zero requests --
    # so an unwired test here would still turn green while proving nothing.
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

    {:ok, bypass: bypass, config: config, dir: dir, library_path: library_path, run: run}
  end

  test "writes a candidate for every unmatched file", %{
    run: run,
    library_path: lp,
    config: config
  } do
    assert :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    assert Library.list_unmatched_media_file_paths(lp.id, 100) == []
  end

  test "records the matched count on the run", %{run: run, config: config} do
    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    assert Library.get_import_run(run.id).files_matched == 5
  end

  test "review mode creates no new items from external matches", %{
    run: run,
    library_path: lp,
    config: config
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
  end

  test "stops at the chunk boundary when asked", %{run: run, config: config} do
    {:ok, _} = Library.request_import_run_stop(Library.get_import_run(run.id))

    assert :stopped = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)
  end

  test "a resumed run does not re-match files that already have candidates", %{
    run: run,
    library_path: lp,
    config: config
  } do
    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    before = Library.get_import_run(run.id).files_matched

    :ok = ImportRunJob.run_match_phase(Library.get_import_run(run.id), config: config)

    # Nothing left to do, so the counter does not move.
    assert Library.get_import_run(run.id).files_matched == before
    assert Library.list_unmatched_media_file_paths(lp.id, 100) == []
  end

  test "keeps candidates a chunk already committed when a stop lands mid-match, and a resumed run finishes the rest",
       %{run: run, dir: dir, library_path: lp, config: config} do
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
    assert Library.list_unmatched_media_file_paths(lp.id, 1000) == []
  end
end
