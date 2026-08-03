defmodule Mydia.Jobs.SegmentDetectionTest do
  # Swaps the fingerprint implementation via Application env, so serial.
  use Mydia.DataCase, async: false

  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures

  alias Mydia.FingerprintStub
  alias Mydia.Jobs.SegmentDetection
  alias Mydia.Jobs.SegmentDetectionScheduler
  alias Mydia.Library.MediaFile

  setup do
    # The app skips Oban in test (engine: false), so Oban.insert cannot be
    # resolved from inside the scheduler. Start an isolated, manual-mode
    # instance so enqueues land somewhere assert_enqueued can see them.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    start_supervised!(%{id: FingerprintStub, start: {FingerprintStub, :start_link, []}})
    Application.put_env(:mydia, :fingerprint_impl, FingerprintStub)

    # Fingerprints are cached through GeneratedMedia, so give the run its own
    # directory rather than writing into priv/generated.
    cache_dir =
      Path.join([
        System.tmp_dir!(),
        "segment_detection_jobs_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(cache_dir)
    Application.put_env(:mydia, :generated_media_path, cache_dir)

    on_exit(fn ->
      File.rm_rf!(cache_dir)
      Application.delete_env(:mydia, :generated_media_path)
      Application.delete_env(:mydia, :fingerprint_impl)
    end)

    :ok
  end

  defp noise(count, seed) do
    Enum.map(1..count, fn i -> :erlang.phash2({seed, i}, 4_294_967_296) end)
  end

  # Builds a season of TV episodes, each with one media file, and returns
  # {media_item, [{media_file, absolute_path}]}. Files default to analyzed with
  # a known duration, which is what makes them eligible for detection.
  defp season_fixture(episode_count, opts \\ []) do
    media_item =
      Keyword.get_lazy(opts, :media_item, fn -> media_item_fixture(%{type: "tv_show"}) end)

    season_number = Keyword.get(opts, :season_number, 1)
    duration = Keyword.get(opts, :duration, 1500.0)

    analyzed_at =
      Keyword.get(opts, :analyzed_at, DateTime.utc_now() |> DateTime.truncate(:second))

    files =
      for n <- 1..episode_count do
        episode =
          episode_fixture(%{
            media_item_id: media_item.id,
            season_number: season_number,
            episode_number: n
          })

        # The fixture replaces :metadata wholesale, so the duration segment
        # detection needs has to be carried here explicitly.
        media_file =
          media_file_fixture(%{
            episode_id: episode.id,
            analyzed_at: analyzed_at,
            relative_path: "s#{season_number}e#{n}.mkv",
            metadata: %{"container" => "mkv", "duration" => duration}
          })

        {media_file, MediaFile.absolute_path(Repo.preload(media_file, :library_path))}
      end

    {media_item, files}
  end

  defp update_files(files, changes) do
    Enum.map(files, fn {media_file, path} ->
      {media_file |> Ecto.Changeset.change(changes) |> Repo.update!(), path}
    end)
  end

  describe "SegmentDetectionScheduler" do
    test "enqueues exactly one job per season, however many files are pending" do
      {show, _files} = season_fixture(3)
      {_show, _more} = season_fixture(2, media_item: show, season_number: 2)
      {other_show, _files} = season_fixture(1)

      assert :ok = perform_job(SegmentDetectionScheduler, %{})

      assert_enqueued(worker: SegmentDetection, args: %{media_item_id: show.id, season_number: 1})
      assert_enqueued(worker: SegmentDetection, args: %{media_item_id: show.id, season_number: 2})

      assert_enqueued(
        worker: SegmentDetection,
        args: %{media_item_id: other_show.id, season_number: 1}
      )

      assert length(all_enqueued(worker: SegmentDetection)) == 3
    end

    test "does not select files whose duration is unknown" do
      season_fixture(2, analyzed_at: nil)

      assert :ok = perform_job(SegmentDetectionScheduler, %{})

      assert all_enqueued(worker: SegmentDetection) == []
    end

    test "enqueues nothing when fingerprinting is unavailable" do
      # fpcalc missing is a runtime capability check, not a stored state: the
      # files stay pending and get picked up once chromaprint is installed.
      FingerprintStub.put_available(false)

      {_media_item, files} = season_fixture(2)

      assert :ok = perform_job(SegmentDetectionScheduler, %{})

      assert all_enqueued(worker: SegmentDetection) == []

      for {media_file, _path} <- files do
        assert Repo.get!(MediaFile, media_file.id).segment_analysis_state == "pending"
      end
    end

    test "does not enqueue seasons whose files exhausted their attempts" do
      {_media_item, files} = season_fixture(2)
      update_files(files, %{segment_analysis_attempts: 3})

      assert :ok = perform_job(SegmentDetectionScheduler, %{})

      assert all_enqueued(worker: SegmentDetection) == []
    end

    test "does not enqueue seasons that already reached a terminal state" do
      {_media_item, files} = season_fixture(2)
      update_files(files, %{segment_analysis_state: "detected"})

      assert :ok = perform_job(SegmentDetectionScheduler, %{})

      assert all_enqueued(worker: SegmentDetection) == []
    end
  end

  describe "configuration" do
    setup do
      source =
        Config.Reader.read!(Path.expand("../../../config/config.exs", __DIR__), env: :prod)

      %{oban: get_in(source, [:mydia, Oban]) || []}
    end

    test "the segments queue runs at concurrency 1", %{oban: oban} do
      # Concurrency 1 is the throttle for the whole feature: one season at a
      # time, never competing with analysis or media.
      assert Keyword.get(oban[:queues], :segments) == 1
    end

    test "cron ticks the scheduler", %{oban: oban} do
      assert {Oban.Plugins.Cron, opts} =
               Enum.find(oban[:plugins], &match?({Oban.Plugins.Cron, _opts}, &1))

      crontab = Keyword.fetch!(opts, :crontab)

      assert Enum.any?(crontab, &match?({_schedule, SegmentDetectionScheduler}, &1)),
             "expected Mydia.Jobs.SegmentDetectionScheduler in the crontab"
    end
  end

  describe "SegmentDetection worker" do
    test "analyzes the requested season" do
      {media_item, files} = season_fixture(3)

      theme = noise(300, :theme)

      for {{_media_file, path}, index} <- Enum.with_index(files, 1) do
        FingerprintStub.put(
          path,
          noise(200, {:open, index}) ++ theme ++ noise(400, {:body, index})
        )
      end

      assert :ok =
               perform_job(SegmentDetection, %{
                 "media_item_id" => media_item.id,
                 "season_number" => 1
               })

      for {media_file, _path} <- files do
        reloaded = Repo.preload(Repo.get!(MediaFile, media_file.id), :segments)
        assert reloaded.segment_analysis_state == "detected"
        assert Enum.any?(reloaded.segments, &(&1.type == "intro"))
      end
    end

    test "marks a file failed once it reaches the attempt ceiling" do
      {media_item, files} = season_fixture(2)
      update_files(files, %{segment_analysis_attempts: 2})

      for {_media_file, path} <- files do
        FingerprintStub.put_error(path, :fpcalc_exploded)
      end

      assert :ok =
               perform_job(SegmentDetection, %{
                 "media_item_id" => media_item.id,
                 "season_number" => 1
               })

      for {media_file, _path} <- files do
        reloaded = Repo.get!(MediaFile, media_file.id)
        assert reloaded.segment_analysis_state == "failed"
        assert reloaded.segment_analysis_attempts == 3
        assert reloaded.last_segment_analysis_error =~ "fpcalc_exploded"
      end
    end

    test "succeeds when the season no longer exists" do
      assert :ok =
               perform_job(SegmentDetection, %{
                 "media_item_id" => Ecto.UUID.generate(),
                 "season_number" => 1
               })
    end
  end
end
