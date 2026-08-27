defmodule Mydia.Subtitles.ResyncTest do
  use Mydia.DataCase, async: true

  import ExUnit.CaptureLog

  alias Mydia.Library.MediaFile
  alias Mydia.MediaFixtures
  alias Mydia.Subtitles.Resync

  describe "decide/4" do
    test "accepts a confident, meaningful correction" do
      assert {:ok, -2500} = Resync.decide(-2500, 0, 252.0, 400)
    end

    test "adds the residual to an offset already stored for the track" do
      assert {:ok, -1300} = Resync.decide(-2500, 1200, 252.0, 400)
    end

    test "declines a low confidence result even when the offset looks large" do
      assert {:skip, :low_confidence} = Resync.decide(-261_500, 0, 30.0, 400)
    end

    test "declines a residual below the perception threshold" do
      assert {:skip, :already_synced} = Resync.decide(120, 0, 252.0, 400)
    end

    test "declines a small residual even when a large offset is already stored" do
      assert {:skip, :already_synced} = Resync.decide(120, 5000, 252.0, 400)
    end

    test "declines when the resulting absolute offset would be out of range" do
      assert {:skip, :implausible} = Resync.decide(200_000, 500_000, 252.0, 400)
    end

    test "declines when there are no spans to normalize against" do
      assert {:skip, :no_cues} = Resync.decide(0, 0, 0.0, 0)
    end

    test "treats the confidence threshold as inclusive at its boundary" do
      assert {:ok, -2500} = Resync.decide(-2500, 0, 200.0, 400)
    end

    # The regression guard for the defect real-media calibration found: a sparse
    # subtitle scores HIGHER per cue, so a wrong match walks through the
    # confidence check. Measured at 0.652 for 14 cues of the wrong film, well
    # clear of the 0.5 threshold, returning an offset 551 seconds out. The cue
    # count is checked before the score for exactly this reason.
    test "declines a sparse subtitle however confident the score looks" do
      assert {:skip, :too_few_cues} = Resync.decide(-551_528, 0, 9.128, 14)
    end

    test "declines a sparse subtitle just under the floor" do
      assert {:skip, :too_few_cues} = Resync.decide(-2500, 0, 125.0, 199)
    end

    test "accepts at the cue floor exactly" do
      assert {:ok, -2500} = Resync.decide(-2500, 0, 126.0, 200)
    end
  end

  # `run/2` has no full alignment end-to-end test here. Exercising the alignment
  # itself needs a media file containing real speech, because a synthesised
  # tone is not something a voice detector registers, and committing a clip of
  # real dialogue as a fixture is a licensing question rather than a technical
  # one. Every piece the alignment path composes is covered: `decide/4` and
  # `cue_spans/2` below, the NIF in `test/mydia/subsync_test.exs`, and
  # enqueueing in `test/mydia/subtitles/resync_enqueue_test.exs`.
  #
  # The whole path HAS been walked by hand, against a real 115 minute film from
  # the production library, before Task 5 was written. That run is what produced
  # the `@min_cues` floor and the measured 0.629 against 0.440 separation in the
  # spec's calibration section. Re-run that calibration over more titles before
  # freezing either threshold.
  #
  # The two `run/2` tests below don't need real speech: they cover input
  # handling that fails before alignment is ever reached.

  describe "run/2" do
    test "skips as :no_audio rather than raising when the media file has no resolvable path" do
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: nil,
        library_path: nil,
        path: nil
      }

      assert {:skip, :no_audio} = Resync.run(media_file, "3")
    end

    # Regression guard for the bug the coordinator caught: `Delivery.content/3`
    # dispatches on the type of its second argument alone (a binary looks up a
    # sidecar row by id, an integer extracts an embedded stream by ffprobe
    # index), but every `track_ref` this module holds is a string. Without
    # converting a numeric ref back to an integer first, an embedded track's
    # re-sync would always take the sidecar branch and fail looking up a
    # `subtitles` row that was never going to exist. `subtitle_spans/2` folds
    # every `Delivery.content/3` error into the same `{:skip, :no_cues}`
    # outward result either way, so the only place the two branches are still
    # distinguishable is the logged failure reason; that's what this test reads.
    @tag :requires_ffmpeg
    test "a numeric track_ref reaches the embedded extraction path, not the sidecar lookup" do
      media_file =
        MediaFixtures.media_file_fixture(%{relative_path: "resync-embedded-fixture.mp4"})
        |> Repo.preload(:library_path)

      File.mkdir_p!(media_file.library_path.path)
      audio_path = Path.join(media_file.library_path.path, media_file.relative_path)
      on_exit(fn -> File.rm_rf(media_file.library_path.path) end)

      generate_silent_audio!(audio_path)

      log =
        capture_log(fn ->
          assert {:skip, :no_cues} = Resync.run(media_file, "3")
        end)

      # The sidecar branch would fail with :subtitle_not_found (no such row in
      # `subtitles`). The embedded branch fails instead because stream index 3
      # does not exist in a file that only has an audio stream, which is the
      # proof the conversion routed this call correctly.
      refute log =~ "subtitle_not_found"
    end
  end

  defp generate_silent_audio!(path) do
    args = [
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "anullsrc=r=8000:cl=mono",
      "-t",
      "1",
      "-c:a",
      "aac",
      "-y",
      path
    ]

    {_output, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
  end

  describe "cue_spans/2" do
    test "extracts millisecond spans from srt" do
      srt = """
      1
      00:00:10,000 --> 00:00:12,000
      Hello there.

      2
      00:01:40,500 --> 00:01:43,250
      General Kenobi.
      """

      assert Resync.cue_spans(srt, "srt") == [{10_000, 12_000}, {100_500, 103_250}]
    end

    test "extracts millisecond spans from vtt with and without the hours segment" do
      vtt = """
      WEBVTT

      00:10.000 --> 00:12.000
      Hello there.

      01:40:00.000 --> 01:40:02.000
      Much later.
      """

      assert Resync.cue_spans(vtt, "vtt") == [{10_000, 12_000}, {6_000_000, 6_002_000}]
    end

    test "returns an empty list for content with no cues" do
      assert Resync.cue_spans("not a subtitle", "srt") == []
    end
  end
end
