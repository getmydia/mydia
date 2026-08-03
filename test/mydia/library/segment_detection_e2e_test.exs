defmodule Mydia.Library.SegmentDetectionE2ETest do
  @moduledoc """
  Exercises the real decode, fingerprint, and correlate path.

  Every other segment detection test stubs the fingerprinter. This one does
  not: ffmpeg decodes actual audio, `fpcalc` fingerprints it, and `Correlator`
  finds the shared theme. It is therefore the only place a wrong `fpcalc` flag,
  a broken WAV window, or a bad frame-rate derivation shows up at all.

  ## Why the season is generated rather than committed

  No copyrighted media enters the repository. ffmpeg builds the fixture at
  setup from deterministic sources, so the audio is byte-identical run to run
  and the shared theme really is the same samples in every episode.

  ## Why the audio is noise mixed with a moving tone

  Chromaprint hashes chroma, which is pitch content. Broadband noise has no
  pitch, so every frame of it hashes to nearly the same value and any two clips
  look alike everywhere. Measured on this toolchain over two 20 second clips of
  140 frames each, generated with `anoisesrc` alone and different seeds: pink
  noise still produced a 16 frame false run, and white noise a 137 frame one. A
  fixture like that passes or fails for reasons that have nothing to do with
  the code under test.

  Mixing the noise into a tone whose pitch steps four times a second along an
  irrational progression gives consecutive frames something to differ about.
  The same measurement over that audio produces a false run of 0 frames, while
  two separate encodes of identical audio still match end to end.

  ## Why there is no skip branch

  ffmpeg and chromaprint both ship in `devenv.nix`, and the suite runs inside
  the devenv shell, so a missing binary is a broken environment rather than an
  unsupported one. A test that quietly asserts nothing is worse than no test,
  because it reads as coverage.

  There is deliberately no `:integration` tag either. `test/test_helper.exs`
  excludes `:external`, `:feature`, and `:requires_relay`, and nothing runs an
  extra pass with tags included, so a tag here would only be an opportunity for
  this to stop running without anybody noticing.
  """

  use Mydia.DataCase, async: false

  # Generating a season and fingerprinting six windows of it takes a few
  # seconds locally and rather more on a loaded CI runner.
  @moduletag timeout: 180_000

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.MediaFile
  alias Mydia.Library.SegmentDetection
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias Mydia.Library.SegmentDetection.Fingerprint.Fpcalc

  @theme_seconds 20
  @closing_seconds 25
  @body_seconds 60

  # Cold opens of different lengths, so a correct detection has to report a
  # different intro start per episode rather than one constant.
  @opens [2, 4, 6]

  # Frames land about every 124 ms and `Correlator` bridges gaps of up to three
  # of them, so a recovered boundary sits a little outside the real one. The
  # worst error measured across both segment types on this toolchain was 0.64 s.
  #
  # This is also deliberately below half the two second spacing between cold
  # opens: a detector answering with one constant offset for the whole season
  # could not satisfy every episode within it.
  @tolerance_ms 1_500

  # Longer than fpcalc's 120 second default on purpose. Below that threshold a
  # correct `-length` and a missing one produce the same answer, so a shorter
  # window could not tell them apart.
  @long_window_s 250

  setup_all do
    assert Ffmpeg.available?(),
           "ffmpeg is not on PATH. It ships in devenv.nix; run this suite with `./dev test`."

    assert Fingerprint.available?(),
           "fpcalc is not on PATH. chromaprint ships in devenv.nix; " <>
             "run this suite with `./dev test`."

    # A stub left behind by another module would let everything below pass
    # without a single real fingerprint being computed, which is the one thing
    # this module exists to do.
    assert Fingerprint.impl() == Fpcalc,
           "the fingerprint implementation is stubbed; this test must run the real one"

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "mydia_segment_e2e_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "media")
    cache = Path.join(base, "generated")
    File.mkdir_p!(dir)
    File.mkdir_p!(cache)

    # Fingerprints are cached through `GeneratedMedia`. Without an override the
    # run writes its blobs into priv/generated inside the repository.
    Application.put_env(:mydia, :generated_media_path, cache)

    on_exit(fn ->
      Application.delete_env(:mydia, :generated_media_path)
      File.rm_rf(base)
    end)

    %{dir: dir}
  end

  describe "fpcalc against real audio" do
    test "fingerprints the whole of a window longer than the fpcalc default", %{dir: dir} do
      clip = noise_clip!(Path.join(dir, "frame_rate.wav"), @long_window_s + 10, 7)

      assert {:ok, result} = Fingerprint.fingerprint(clip, 0, @long_window_s)

      frames_per_second = length(result.hashes) / @long_window_s

      # fpcalc without an explicit `-length` fingerprints only the first 120
      # seconds and discards the rest, which more than halves this figure over
      # a 250 second window while DURATION keeps reporting the full span.
      assert frames_per_second > 7.0,
             "only #{length(result.hashes)} frames for a #{@long_window_s}s window " <>
               "(#{Float.round(frames_per_second, 2)}/s); the window was truncated"

      # Chromaprint advances 1365 samples at 11025 Hz, so 124.17 ms per frame.
      # The truncation above lands near 264 ms instead, and every derived
      # timestamp then drifts further the longer the matched run.
      assert_in_delta result.frame_ms,
                      124.17,
                      10.0,
                      "derived frame duration #{Float.round(result.frame_ms, 2)} ms is not " <>
                        "Chromaprint's frame rate"

      assert result.window_start_ms == 0
    end

    test "records where in the file a window began", %{dir: dir} do
      clip = noise_clip!(Path.join(dir, "offset.wav"), 200, 11)

      assert {:ok, result} = Fingerprint.fingerprint(clip, 100, 60)

      # The credits window never starts at zero, so frame positions inside it
      # are meaningless without this offset.
      assert result.window_start_ms == 100_000
      assert length(result.hashes) > 60 * 7
    end
  end

  describe "analyze_season/2 on a generated season" do
    test "detects the shared opening theme and closing across the season", %{dir: dir} do
      {media_item, episodes} = build_season!(dir)

      assert :ok = SegmentDetection.analyze_season(media_item.id, 1)

      intro_starts =
        for %{file: file, open_seconds: open_seconds, duration: duration} <- episodes do
          reloaded = Repo.preload(Repo.get!(MediaFile, file.id), :segments)

          assert reloaded.segment_analysis_state == "detected",
                 "expected detection for #{file.relative_path}, got " <>
                   "#{reloaded.segment_analysis_state} " <>
                   "(#{reloaded.last_segment_analysis_error})"

          intro = Enum.find(reloaded.segments, &(&1.type == "intro"))
          assert intro, "no intro segment for #{file.relative_path}"
          assert intro.source == "fingerprint"

          # Two partners out of two attempted, so anything below the 0.4
          # exposure floor means the partners disagreed on where the theme was.
          assert intro.confidence >= 0.4

          assert_in_delta intro.start_ms, open_seconds * 1000, @tolerance_ms
          assert_in_delta intro.end_ms, (open_seconds + @theme_seconds) * 1000, @tolerance_ms

          credits = Enum.find(reloaded.segments, &(&1.type == "credits"))
          assert credits, "no credits segment for #{file.relative_path}"
          assert credits.source == "fingerprint"

          # The credits window starts two thirds of the way into the file, so
          # these two are wrong unless the window start is added back to the
          # frame positions the correlator returns.
          assert_in_delta credits.start_ms,
                          (duration - @closing_seconds) * 1000,
                          @tolerance_ms

          assert_in_delta credits.end_ms, duration * 1000, @tolerance_ms

          intro.start_ms
        end

      assert length(Enum.uniq(intro_starts)) == length(@opens),
             "the season resolved to fewer than #{length(@opens)} distinct intro starts " <>
               "(#{inspect(intro_starts)}), so the offsets are not being derived per file"
    end
  end

  # -- fixture generation ---------------------------------------------------

  # A season whose episodes share an opening theme and a closing, each with a
  # cold open and a body of its own. Returns the media item and one entry per
  # episode carrying its media file and the lengths asserted against.
  defp build_season!(dir) do
    theme = tone_clip!(Path.join(dir, "theme.wav"), @theme_seconds, 42, 4.7548776662)
    closing = tone_clip!(Path.join(dir, "closing.wav"), @closing_seconds, 77, 7.1415926536)

    library_path = library_path_fixture(%{type: "series", path: dir})
    media_item = media_item_fixture(%{type: "tv_show"})

    episodes =
      for {open_seconds, index} <- Enum.with_index(@opens, 1) do
        path = build_episode!(dir, index, open_seconds, theme, closing)
        duration = open_seconds + @theme_seconds + @body_seconds + @closing_seconds

        episode =
          episode_fixture(%{
            media_item_id: media_item.id,
            season_number: 1,
            episode_number: index
          })

        media_file =
          media_file_fixture(%{
            episode_id: episode.id,
            library_path_id: library_path.id,
            relative_path: Path.basename(path),
            # The fixture replaces :metadata wholesale rather than merging, so
            # the runtime both detection windows are derived from has to be
            # carried here or the file is skipped as not ready.
            metadata: %{"container" => "matroska", "duration" => duration * 1.0}
          })

        %{file: media_file, open_seconds: open_seconds, duration: duration}
      end

    {media_item, episodes}
  end

  # Cold open, shared theme, body, shared closing, concatenated and encoded to
  # Vorbis so the fingerprinter reads a lossy stream rather than the raw WAV it
  # would never be handed in a real library.
  defp build_episode!(dir, index, open_seconds, theme, closing) do
    open =
      tone_clip!(Path.join(dir, "open_#{index}.wav"), open_seconds, 900 + index, 3.236 + index)

    body =
      tone_clip!(Path.join(dir, "body_#{index}.wav"), @body_seconds, 100 + index, 5.618 + index)

    output = Path.join(dir, "s01e0#{index}.mka")

    {:ok, _output} =
      Ffmpeg.run([
        "-nostdin",
        "-i",
        open,
        "-i",
        theme,
        "-i",
        body,
        "-i",
        closing,
        "-filter_complex",
        "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1[out]",
        "-map",
        "[out]",
        "-c:a",
        "libvorbis",
        "-y",
        output
      ])

    output
  end

  # Pink noise mixed into a tone that steps pitch four times a second. `tone`
  # sets the progression and `seed` the noise, so clips differing in either are
  # distinguishable to Chromaprint while a clip reused verbatim is not.
  defp tone_clip!(path, seconds, seed, tone) do
    melody =
      "aevalsrc='0.6*sin(2*PI*t*160*pow(2,mod(floor(t*4)*#{tone},12)/12))':d=#{seconds}:s=44100"

    {:ok, _output} =
      Ffmpeg.run([
        "-nostdin",
        "-f",
        "lavfi",
        "-i",
        "anoisesrc=duration=#{seconds}:color=pink:seed=#{seed}:sample_rate=44100",
        "-f",
        "lavfi",
        "-i",
        melody,
        "-filter_complex",
        "[0:a][1:a]amix=inputs=2:duration=shortest[out]",
        "-map",
        "[out]",
        "-ac",
        "1",
        "-y",
        path
      ])

    path
  end

  # The frame-rate tests only measure how much of a window was fingerprinted,
  # so they do not need the tone the correlation fixture depends on.
  defp noise_clip!(path, seconds, seed) do
    {:ok, _output} =
      Ffmpeg.run([
        "-nostdin",
        "-f",
        "lavfi",
        "-i",
        "anoisesrc=duration=#{seconds}:color=pink:seed=#{seed}:sample_rate=44100",
        "-ac",
        "1",
        "-y",
        path
      ])

    path
  end
end
