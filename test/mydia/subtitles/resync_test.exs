defmodule Mydia.Subtitles.ResyncTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
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
    # `subtitles` row that was never going to exist.
    #
    # `subtitle_spans/2` folds every `Delivery.content/3` error into the same
    # `{:skip, :no_cues}` outward result, so a missing-sidecar-row failure and
    # a failed embedded extraction are impossible to tell apart from the
    # return value alone. This test sidesteps that by giving the embedded
    # branch something to actually succeed on: a real subtitle stream muxed
    # into the fixture. On the sidecar branch that stream is invisible (there
    # is no `subtitles` row for it) and the result is `{:skip, :no_cues}`. On
    # the embedded branch, ffmpeg extracts its one real cue and the pipeline
    # reaches the confidence gate, which declines a single cue as
    # `:too_few_cues` (miles under `@min_cues`) rather than `:no_cues`. That
    # divergence is the proof the numeric ref reached ffmpeg extraction and
    # not the sidecar lookup.
    @tag :requires_ffmpeg
    test "a numeric track_ref reaches the embedded extraction path, not the sidecar lookup" do
      media_file =
        MediaFixtures.media_file_fixture(%{relative_path: "resync-embedded-fixture.mkv"})
        |> Repo.preload(:library_path)

      File.mkdir_p!(media_file.library_path.path)
      media_path = Path.join(media_file.library_path.path, media_file.relative_path)
      on_exit(fn -> File.rm_rf(media_file.library_path.path) end)

      subtitle_index = mux_audio_and_subtitle!(media_path)

      assert {:skip, :too_few_cues} = Resync.run(media_file, to_string(subtitle_index))
    end
  end

  # Builds a one-second silent-audio file with one real embedded subtitle
  # cue, and returns the container's stream index for that subtitle. The
  # index is read back from ffprobe rather than assumed, since the explicit
  # `-map` order determines it and hard-coding it would silently stop proving
  # anything if that order ever changed.
  defp mux_audio_and_subtitle!(media_path) do
    srt_path = media_path <> ".srt"

    File.write!(srt_path, """
    1
    00:00:00,000 --> 00:00:01,000
    Hello there.
    """)

    mux_args = [
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "anullsrc=r=8000:cl=mono",
      "-i",
      srt_path,
      "-t",
      "1",
      "-map",
      "0:a",
      "-map",
      "1:s",
      "-c:a",
      "aac",
      "-c:s",
      "srt",
      "-y",
      media_path
    ]

    {_output, 0} = System.cmd("ffmpeg", mux_args, stderr_to_stdout: true)
    File.rm(srt_path)

    probe_args = [
      "-v",
      "error",
      "-select_streams",
      "s",
      "-show_entries",
      "stream=index",
      "-of",
      "csv=p=0",
      media_path
    ]

    {probe_output, 0} = System.cmd("ffprobe", probe_args)
    probe_output |> String.trim() |> String.to_integer()
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

  # Regression coverage for the allocation hazard documented on
  # `Mydia.Subsync.align/2` and `native/mydia_subsync/src/align.rs`:
  # `ilass::align_nosplit` sizes an internal buffer from the spread between
  # the largest and smallest timestamp it receives, with no ceiling of its
  # own. `drop_out_of_range_cues/2` is what keeps a malformed or OCR'd cue
  # from ever reaching that call.
  describe "drop_out_of_range_cues/2" do
    test "drops a cue that falls beyond the media file's known duration" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: 3600.0}}
      in_range = {10_000, 12_000}
      # 1 hour of duration + the 10 minute margin puts the bound at
      # 4_200_000ms; this cue's end lands 1ms past it.
      out_of_range = {4_199_999, 4_200_001}

      assert Resync.drop_out_of_range_cues([in_range, out_of_range], media_file) == [in_range]
    end

    test "keeps a cue comfortably within the media file's known duration" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: 3600.0}}
      cues = [{10_000, 12_000}, {3_500_000, 3_500_500}]

      assert Resync.drop_out_of_range_cues(cues, media_file) == cues
    end

    test "falls back to a fixed ceiling when the media file's duration is not yet known" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: nil}}
      within_fallback = {10_000, 21_600_000}
      beyond_fallback = {10_000, 21_600_001}

      assert Resync.drop_out_of_range_cues([within_fallback, beyond_fallback], media_file) == [
               within_fallback
             ]
    end

    # Regression guard for the one-sided filter that only ever checked
    # `start_ms >= 0`: a two-digit-hour typo like "99:00:00,000 --> 00:00:02,000"
    # parses to {356_400_000, 2_000}. The start is non-negative and the end is
    # well under the bound, so the old filter let it straight through. `to_spans/1`
    # in `native/mydia_subsync/src/align.rs` then reorders it with `new_safe`
    # into a span from 2_000 to 356_400_000, which is exactly the unbounded
    # spread `ilass::align_nosplit` sizes its allocation from.
    test "drops a reversed cue whose start is far beyond the bound even though its end is small" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: 3600.0}}
      reversed = {356_400_000, 2_000}

      assert Resync.drop_out_of_range_cues([reversed], media_file) == []
    end

    test "keeps a normal cue when a reversed out-of-range cue is filtered alongside it" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: 3600.0}}
      normal = {10_000, 12_000}
      reversed = {356_400_000, 2_000}

      assert Resync.drop_out_of_range_cues([normal, reversed], media_file) == [normal]
    end

    test "drops a cue whose start exceeds the bound even when its end is within range" do
      media_file = %MediaFile{metadata: %FileMetadata{duration: 3600.0}}
      # Bound is 4_200_000ms (1 hour duration + the 10 minute margin). The end
      # alone would pass the old start-only check.
      cue = {4_200_001, 12_000}

      assert Resync.drop_out_of_range_cues([cue], media_file) == []
    end
  end
end
