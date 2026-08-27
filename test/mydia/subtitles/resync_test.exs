defmodule Mydia.Subtitles.ResyncTest do
  use Mydia.DataCase, async: true

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

  # `run/2` itself has no end-to-end test here. Exercising it needs a media file
  # containing real speech, because a synthesised tone is not something a voice
  # detector registers, and committing a clip of real dialogue as a fixture is a
  # licensing question rather than a technical one. Every piece it composes is
  # covered: `decide/4` and `cue_spans/2` below, the NIF in
  # `test/mydia/subsync_test.exs`, and enqueueing in
  # `test/mydia/subtitles/resync_enqueue_test.exs`.
  #
  # The whole path HAS been walked by hand, against a real 115 minute film from
  # the production library, before Task 5 was written. That run is what produced
  # the `@min_cues` floor and the measured 0.629 against 0.440 separation in the
  # spec's calibration section. Re-run that calibration over more titles before
  # freezing either threshold.

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
