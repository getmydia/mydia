defmodule Mydia.Library.SegmentDetectionTest do
  # Swaps the fingerprint implementation via Application env, so serial.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.FingerprintStub
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaSegment
  alias Mydia.Library.SegmentDetection

  setup do
    start_supervised!(%{id: FingerprintStub, start: {FingerprintStub, :start_link, []}})
    Application.put_env(:mydia, :fingerprint_impl, FingerprintStub)

    # Fingerprints are cached through GeneratedMedia, so give the run its own
    # directory rather than writing into priv/generated.
    cache_dir =
      Path.join([
        System.tmp_dir!(),
        "segment_detection_test_#{System.unique_integer([:positive])}"
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

  # Builds a TV season whose episodes each have one media file with a known
  # duration, and returns {media_item, [{media_file, absolute_path}]}.
  defp season_fixture(episode_count, opts \\ []) do
    duration = Keyword.get(opts, :duration, 1500.0)
    media_item = media_item_fixture(%{type: "tv_show"})

    files =
      for n <- 1..episode_count do
        episode =
          episode_fixture(%{
            media_item_id: media_item.id,
            season_number: 1,
            episode_number: n
          })

        # Segment detection requires a known duration, which FileAnalysis
        # normally supplies. The fixture replaces :metadata wholesale, so the
        # duration has to be carried here explicitly.
        media_file =
          media_file_fixture(%{
            episode_id: episode.id,
            relative_path: "s01e#{String.pad_leading(to_string(n), 2, "0")}.mkv",
            metadata: %{"container" => "mkv", "duration" => duration}
          })

        {media_file, MediaFile.absolute_path(Repo.preload(media_file, :library_path))}
      end

    {media_item, files}
  end

  describe "consensus/2" do
    test "accepts two agreeing matches and reports the agreement ratio" do
      matches = [
        %{start_ms: 30_000, end_ms: 90_000},
        %{start_ms: 30_100, end_ms: 90_200}
      ]

      assert {:ok, result} = SegmentDetection.consensus(matches, 5)
      assert result.start_ms == 30_050
      assert result.end_ms == 90_100
      assert_in_delta result.confidence, 0.4, 0.0001
    end

    test "takes the median of an odd number of matches" do
      # All three agree within tolerance, so the cluster is the whole list and
      # the middle value wins.
      matches = [
        %{start_ms: 30_000, end_ms: 90_000},
        %{start_ms: 31_000, end_ms: 91_000},
        %{start_ms: 31_800, end_ms: 91_800}
      ]

      assert {:ok, result} = SegmentDetection.consensus(matches, 3)
      assert result.start_ms == 31_000
      assert result.end_ms == 91_000
      assert_in_delta result.confidence, 1.0, 0.0001
    end

    test "rejects a single match" do
      assert :no_consensus = SegmentDetection.consensus([%{start_ms: 1, end_ms: 2}], 5)
    end

    test "rejects an empty match list" do
      assert :no_consensus = SegmentDetection.consensus([], 5)
    end

    test "rejects two matches that disagree rather than averaging them" do
      # A real intro at 2:00 and a spurious hit at 15:00. Taking the median of
      # the pair would ship a segment at 8:30 at exactly the confidence the
      # exposure floor admits, so the disagreement has to be caught here.
      matches = [
        %{start_ms: 120_000, end_ms: 180_000},
        %{start_ms: 900_000, end_ms: 960_000}
      ]

      assert :no_consensus = SegmentDetection.consensus(matches, 5)
    end

    test "drops an outlier and scores confidence on the cluster, not the raw count" do
      matches = [
        %{start_ms: 120_000, end_ms: 180_000},
        %{start_ms: 120_200, end_ms: 180_100},
        %{start_ms: 900_000, end_ms: 960_000}
      ]

      assert {:ok, result} = SegmentDetection.consensus(matches, 5)
      assert result.start_ms == 120_100
      assert result.end_ms == 180_050
      # 2 of 5 agreed, not 3 of 5.
      assert_in_delta result.confidence, 0.4, 0.0001
    end

    test "treats matches a frame or two apart as one cluster" do
      matches = [
        %{start_ms: 30_000, end_ms: 90_000},
        %{start_ms: 30_124, end_ms: 90_124},
        %{start_ms: 30_248, end_ms: 90_248}
      ]

      assert {:ok, result} = SegmentDetection.consensus(matches, 3)
      assert result.start_ms == 30_124
      assert result.end_ms == 90_124
      assert_in_delta result.confidence, 1.0, 0.0001
    end
  end

  describe "partners/3" do
    test "spreads partners across the season rather than taking neighbours" do
      files = for n <- 1..20, do: %{id: n}
      target = %{id: 1}

      partners = SegmentDetection.partners(files, target, 5)

      assert length(partners) == 5
      refute target in partners
      # Should reach beyond the immediate neighbours.
      assert Enum.any?(partners, &(&1.id > 10))
    end

    test "returns everything available when the season is smaller than the count" do
      files = for n <- 1..3, do: %{id: n}
      target = %{id: 2}

      partners = SegmentDetection.partners(files, target, 5)

      assert length(partners) == 2
      refute target in partners
    end
  end

  # Installs a fake ffmpeg that reports one black transition at `at_seconds`
  # into whatever window blackdetect is pointed at. Boundary shells out through
  # Mydia.Library.Ffmpeg, which honours the :ffmpeg_path override.
  defp stub_blackdetect(at_seconds) do
    dir = Path.join(System.tmp_dir!(), "segdet_ffmpeg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "ffmpeg")

    File.write!(script, """
    #!/bin/sh
    echo "[Parsed_blackdetect_0 @ 0x1] black_start:#{at_seconds} black_end:#{at_seconds} black_duration:0.125" >&2
    """)

    File.chmod!(script, 0o755)
    Application.put_env(:mydia, :ffmpeg_path, script)

    on_exit(fn ->
      Application.delete_env(:mydia, :ffmpeg_path)
      File.rm_rf!(dir)
    end)
  end

  # A season whose only shared audio is exactly the 20s minimum credits run,
  # placed 100 frames into the credits window. With duration 1500.0 that window
  # starts at 1_050_000ms, so the run is 1_060_000 -> 1_080_000.
  defp minimum_credits_season do
    {media_item, files} = season_fixture(4)
    theme = noise(200, :ending)

    for {{_media_file, path}, index} <- Enum.with_index(files, 1) do
      FingerprintStub.put(path, noise(100, {:body, index}) ++ theme ++ noise(200, {:tail, index}))
    end

    {media_item, files}
  end

  describe "credits boundary refinement" do
    test "keeps the unrefined end when refinement would cross the segment start" do
      # black_start:0 puts the refined end at the very beginning of the +/-20s
      # search window, which for a 20s segment is exactly its start. Persisting
      # that would fail MediaSegment's end > start validation while the type was
      # still recorded as detected, leaving a detected file with no segment.
      stub_blackdetect(0)
      {media_item, files} = minimum_credits_season()

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      {media_file, _path} = hd(files)
      reloaded = Repo.preload(Repo.get!(MediaFile, media_file.id), :segments)
      credits = Enum.find(reloaded.segments, &(&1.type == "credits"))

      assert credits, "credits segment should survive a refinement that would cross the start"
      assert credits.start_ms == 1_060_000
      assert credits.end_ms == 1_080_000
    end

    test "applies refinement that lands after the segment start" do
      # 15s into the window is 1_075_000 absolute, comfortably past the start,
      # so the snap is taken and the end moves earlier by 5s.
      stub_blackdetect(15)
      {media_item, files} = minimum_credits_season()

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      {media_file, _path} = hd(files)
      reloaded = Repo.preload(Repo.get!(MediaFile, media_file.id), :segments)
      credits = Enum.find(reloaded.segments, &(&1.type == "credits"))

      assert credits.start_ms == 1_060_000
      assert credits.end_ms == 1_075_000
    end
  end

  describe "analyze_season/2" do
    test "detects a shared intro and persists it for every episode" do
      {media_item, files} = season_fixture(4)

      theme = noise(300, :theme)

      for {{_media_file, path}, index} <- Enum.with_index(files, 1) do
        # Every episode carries the same 300-frame theme after 200 frames of
        # cold open, then unique content.
        FingerprintStub.put(
          path,
          noise(200, {:open, index}) ++ theme ++ noise(500, {:body, index})
        )
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for {media_file, _path} <- files do
        reloaded = Repo.preload(Repo.get!(MediaFile, media_file.id), :segments)
        assert reloaded.segment_analysis_state == "detected"
        assert %DateTime{} = reloaded.segments_analyzed_at

        intro = Enum.find(reloaded.segments, &(&1.type == "intro"))
        assert intro.source == "fingerprint"
        # 200 frames at 100ms per frame.
        assert intro.start_ms == 20_000
        assert intro.end_ms == 50_000
        assert intro.confidence > 0.5
      end
    end

    test "marks the season not_found when episodes share nothing" do
      {media_item, files} = season_fixture(3)

      for {{_media_file, path}, index} <- Enum.with_index(files, 1) do
        FingerprintStub.put(path, noise(800, {:unique, index}))
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for {media_file, _path} <- files do
        reloaded = Repo.get!(MediaFile, media_file.id)
        assert reloaded.segment_analysis_state == "not_found"
        assert reloaded.segment_analysis_attempts == 0
      end
    end

    test "short-circuits a season with fewer than two files without spending attempts" do
      {media_item, [{media_file, _path}]} = season_fixture(1)

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      reloaded = Repo.get!(MediaFile, media_file.id)
      assert reloaded.segment_analysis_state == "not_found"
      assert reloaded.segment_analysis_attempts == 0
    end

    test "leaves files pending when the rest of the season has no duration yet" do
      {media_item, files} = season_fixture(3)
      [{first, _}, {second, _}, {third, _}] = files

      # FileAnalysis has not reached these two, so there is nothing ready to
      # correlate the first file against. That is an ordering dependency, not a
      # failure, so nothing may be marked and no attempt may be spent.
      for file <- [second, third] do
        file
        |> Ecto.Changeset.change(%{analyzed_at: nil, metadata: %{"container" => "mkv"}})
        |> Repo.update!()
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for file <- [first, second, third] do
        reloaded = Repo.get!(MediaFile, file.id)
        assert reloaded.segment_analysis_state == "pending"
        assert reloaded.segment_analysis_attempts == 0
      end
    end

    test "waits rather than closing out early episodes when only two files are ready" do
      # Two ready files is one short of what consensus needs: it requires
      # @min_agreeing partners that agree, and a target cannot partner with
      # itself. Running anyway would write the terminal `not_found` that no
      # later tick revisits, permanently closing out the early episodes of a
      # season that was only still filling in.
      {media_item, files} = season_fixture(5)
      [_, _, {third, _}, {fourth, _}, {fifth, _}] = files

      for file <- [third, fourth, fifth] do
        file
        |> Ecto.Changeset.change(%{analyzed_at: nil, metadata: %{"container" => "mkv"}})
        |> Repo.update!()
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for {file, _path} <- files do
        reloaded = Repo.get!(MediaFile, file.id)
        assert reloaded.segment_analysis_state == "pending"
        assert reloaded.segment_analysis_attempts == 0
      end
    end

    test "does not wait forever when the whole season is ready but too small" do
      # The counterpart to the test above. Every file has a runtime, so there is
      # nothing left to wait for, and a two-file season settles honestly on
      # not_found rather than staying pending indefinitely.
      {media_item, files} = season_fixture(2)

      for {_media_file, path} <- files do
        FingerprintStub.put(path, noise(600, :unshared))
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for {file, _path} <- files do
        reloaded = Repo.get!(MediaFile, file.id)
        assert reloaded.segment_analysis_state == "not_found"
      end
    end

    test "counts an attempt and records the error when fingerprinting fails" do
      {media_item, files} = season_fixture(2)

      for {_media_file, path} <- files do
        FingerprintStub.put_error(path, :fpcalc_exploded)
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      for {media_file, _path} <- files do
        reloaded = Repo.get!(MediaFile, media_file.id)
        assert reloaded.segment_analysis_state == "pending"
        assert reloaded.segment_analysis_attempts == 1
        assert reloaded.last_segment_analysis_error =~ "fpcalc_exploded"
      end
    end

    test "skips files that already have a terminal state" do
      {media_item, files} = season_fixture(2)
      [{first, _}, _] = files

      first
      |> Ecto.Changeset.change(%{segment_analysis_state: "detected"})
      |> Repo.update!()

      for {_media_file, path} <- files do
        FingerprintStub.put(path, noise(400, :whatever))
      end

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      assert Repo.get!(MediaFile, first.id).segment_analysis_state == "detected"
    end
  end

  describe "reset_season/2" do
    test "clears segments and returns files to pending" do
      {media_item, files} = season_fixture(2)
      [{first, _}, _] = files

      %MediaSegment{}
      |> MediaSegment.changeset(%{
        media_file_id: first.id,
        type: "intro",
        start_ms: 1000,
        end_ms: 2000,
        source: "fingerprint",
        confidence: 0.9
      })
      |> Repo.insert!()

      first
      |> Ecto.Changeset.change(%{
        segment_analysis_state: "detected",
        segment_analysis_attempts: 2
      })
      |> Repo.update!()

      assert :ok = SegmentDetection.reset_season(media_item.id, 1)

      reloaded = Repo.preload(Repo.get!(MediaFile, first.id), :segments)
      assert reloaded.segment_analysis_state == "pending"
      assert reloaded.segment_analysis_attempts == 0
      assert reloaded.segments == []
    end
  end

  describe "season_status/2" do
    test "reports detected with the segments and their provenance" do
      {media_item, files} = season_fixture(2)

      for {media_file, _path} <- files do
        insert_segment(media_file, start_ms: 20_000, end_ms: 50_000, source: "chapters")
      end

      status = SegmentDetection.season_status(media_item.id, 1)

      assert status.state == :detected
      assert status.sources == ["chapters"]
      assert status.files == 2
      assert status.segments["intro"] == %{start_ms: 20_000, end_ms: 50_000, files: 2}
    end

    test "takes the median offset across every file carrying the type" do
      {media_item, [{first, _}, {second, _}, {third, _}]} = season_fixture(3)

      insert_segment(first, start_ms: 10_000, end_ms: 40_000)
      insert_segment(second, start_ms: 20_000, end_ms: 50_000)
      insert_segment(third, start_ms: 90_000, end_ms: 120_000)

      status = SegmentDetection.season_status(media_item.id, 1)

      assert status.segments["intro"] == %{start_ms: 20_000, end_ms: 50_000, files: 3}
    end

    test "reports a type found on only some files rather than dropping it" do
      {media_item, [{first, _}, {second, _}]} = season_fixture(2)

      insert_segment(first, type: "intro", start_ms: 20_000, end_ms: 50_000)

      insert_segment(second,
        type: "credits",
        start_ms: 1_400_000,
        end_ms: 1_490_000,
        source: "chapters"
      )

      status = SegmentDetection.season_status(media_item.id, 1)

      # Sampling one file used to report whichever type that file happened to
      # carry and call the other one missing.
      assert status.segments["intro"].files == 1
      assert status.segments["credits"].files == 1
      assert status.files == 2
    end

    test "reports every provenance a mixed season used, sorted" do
      {media_item, [{first, _}, {second, _}]} = season_fixture(2)

      insert_segment(first, source: "fingerprint")
      insert_segment(second, source: "chapters")

      assert SegmentDetection.season_status(media_item.id, 1).sources ==
               ["chapters", "fingerprint"]
    end

    test "reports partial when only some files resolved" do
      {media_item, [{first, _}, _second]} = season_fixture(2)

      %MediaSegment{}
      |> MediaSegment.changeset(%{
        media_file_id: first.id,
        type: "intro",
        start_ms: 1000,
        end_ms: 2000,
        source: "fingerprint",
        confidence: 0.6
      })
      |> Repo.insert!()

      assert SegmentDetection.season_status(media_item.id, 1).state == :partial
    end
  end

  describe "season_statuses/1" do
    test "summarises every season of a show in one pass" do
      {media_item, [{first, _}, _second]} = season_fixture(2)

      insert_segment(first)

      second_season_episode =
        episode_fixture(%{media_item_id: media_item.id, season_number: 2, episode_number: 1})

      second_season_file = media_file_fixture(%{episode_id: second_season_episode.id})
      insert_segment(second_season_file, start_ms: 30_000, end_ms: 60_000, source: "chapters")

      statuses = SegmentDetection.season_statuses(media_item.id)

      assert Map.keys(statuses) |> Enum.sort() == [1, 2]
      assert statuses[1].state == :partial
      assert statuses[1].files == 2
      assert statuses[2].state == :detected
      assert statuses[2].segments["intro"] == %{start_ms: 30_000, end_ms: 60_000, files: 1}
    end

    test "returns an empty map for a show with no files" do
      media_item = media_item_fixture(%{type: "tv_show"})

      assert SegmentDetection.season_statuses(media_item.id) == %{}
    end
  end

  defp insert_segment(media_file, opts \\ []) do
    %MediaSegment{}
    |> MediaSegment.changeset(%{
      media_file_id: media_file.id,
      type: Keyword.get(opts, :type, "intro"),
      start_ms: Keyword.get(opts, :start_ms, 20_000),
      end_ms: Keyword.get(opts, :end_ms, 50_000),
      source: Keyword.get(opts, :source, "fingerprint"),
      confidence: Keyword.get(opts, :confidence, 1.0)
    })
    |> Repo.insert!()
  end
end
