defmodule Mydia.Library.SegmentDetection.Fingerprint.FpcalcTest do
  # Mutates Application env for the binary path, so serial.
  use ExUnit.Case, async: false

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.SegmentDetection.Fingerprint.Fpcalc
  alias Mydia.Library.SegmentDetection.Fingerprint.Result

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :fpcalc_path) end)

    :ok
  end

  describe "parse_output/1" do
    test "parses duration and fingerprint into a result" do
      output = """
      DURATION=120
      FINGERPRINT=1234567,2345678,3456789,4567890
      """

      assert {:ok, %Result{} = result} = Fpcalc.parse_output(output)
      assert result.hashes == [1_234_567, 2_345_678, 3_456_789, 4_567_890]

      # frame_ms is derived, never hardcoded: 120_000ms over 4 frames.
      assert_in_delta result.frame_ms, 30_000.0, 0.001
    end

    test "masks negative values into unsigned 32-bit" do
      output = """
      DURATION=1
      FINGERPRINT=-1,-2147483648
      """

      assert {:ok, %Result{hashes: [a, b]}} = Fpcalc.parse_output(output)
      assert a == 4_294_967_295
      assert b == 2_147_483_648
    end

    test "accepts a fractional duration" do
      output = """
      DURATION=10.5
      FINGERPRINT=1,2,3
      """

      assert {:ok, %Result{} = result} = Fpcalc.parse_output(output)
      assert_in_delta result.frame_ms, 3500.0, 0.001
    end

    test "errors when the fingerprint line is missing" do
      assert {:error, :no_fingerprint} = Fpcalc.parse_output("DURATION=120\n")
    end

    test "errors when the duration line is missing" do
      assert {:error, :no_duration} = Fpcalc.parse_output("FINGERPRINT=1,2,3\n")
    end

    test "errors on an empty fingerprint" do
      assert {:error, :no_fingerprint} = Fpcalc.parse_output("DURATION=120\nFINGERPRINT=\n")
    end
  end

  describe "available?/0" do
    test "is false when the configured binary does not resolve" do
      Application.put_env(:mydia, :fpcalc_path, "/nonexistent/fpcalc-binary")

      refute Fpcalc.available?()
    end
  end

  describe "fingerprint/3" do
    test "returns :fpcalc_not_found without decoding when the binary is missing" do
      Application.put_env(:mydia, :fpcalc_path, "/nonexistent/fpcalc-binary")

      assert {:error, :fpcalc_not_found} =
               Fpcalc.fingerprint("/nonexistent/episode.mkv", 0, 60)
    end

    @tag :requires_ffmpeg
    @tag :tmp_dir
    test "derives Chromaprint's real frame rate over a window longer than two minutes",
         %{tmp_dir: tmp_dir} do
      # Assert the binaries rather than skipping past them. devenv.nix provides
      # both ffmpeg and chromaprint, and CI runs its test jobs inside
      # `devenv shell`, so an absent binary is a broken environment rather than
      # an expected condition. A test that quietly passes without asserting
      # anything is worse than no test, because it reads as coverage.
      assert Ffmpeg.available?(),
             "ffmpeg not found; run the suite inside the devenv shell (./dev test)"

      assert Fpcalc.available?(),
             "fpcalc not found; chromaprint is in devenv.nix, run the suite inside the devenv shell (./dev test)"

      source = Path.join(tmp_dir, "episode.wav")
      # 310 seconds of audio so the 300 second window below is comfortably
      # longer than fpcalc's 120 second default -length.
      assert {:ok, _} =
               Ffmpeg.run([
                 "-nostdin",
                 "-f",
                 "lavfi",
                 "-i",
                 "anoisesrc=duration=310:color=pink:seed=7",
                 "-ac",
                 "1",
                 "-ar",
                 "11025",
                 "-y",
                 source
               ])

      assert {:ok, %Result{} = result} = Fpcalc.fingerprint(source, 5, 300)

      assert result.window_start_ms == 5_000
      assert length(result.hashes) > 2_000

      # Chromaprint runs at about 8.05 frames per second, so a correct run
      # derives roughly 124.17 ms per frame. A value anywhere near 600 means
      # -length was dropped from the fpcalc invocation: fpcalc then reads only
      # the first two minutes while DURATION still describes the whole input.
      assert_in_delta result.frame_ms, 124.17, 3.0
    end

    @tag :requires_ffmpeg
    @tag :tmp_dir
    test "falls back to output seeking when the container rejects input seeking",
         %{tmp_dir: tmp_dir} do
      assert Ffmpeg.available?(),
             "ffmpeg not found; run the suite inside the devenv shell (./dev test)"

      assert Fpcalc.available?(),
             "fpcalc not found; chromaprint is in devenv.nix, run the suite inside the devenv shell (./dev test)"

      # Real audio the stub hands back on the output-seeking path, so fpcalc
      # still runs for real and the assertion covers the whole chain.
      #
      # Its duration matches the requested window exactly, because real ffmpeg
      # decodes only the window and fpcalc's DURATION therefore describes the
      # fingerprinted span. A longer stub file would inflate frame_ms and be an
      # artifact of the stub rather than of the code under test.
      prepared = Path.join(tmp_dir, "prepared.wav")

      assert {:ok, _} =
               Ffmpeg.run([
                 "-nostdin",
                 "-f",
                 "lavfi",
                 "-i",
                 "anoisesrc=duration=130:color=pink:seed=11",
                 "-ac",
                 "1",
                 "-ar",
                 "11025",
                 "-y",
                 prepared
               ])

      # Stands in for a container that rejects `-ss` before `-i`. Input seeking
      # puts "-ss" in position 2; output seeking puts "-i" there.
      stub = Path.join(tmp_dir, "ffmpeg-stub")

      File.write!(stub, """
      #!/bin/sh
      if [ "$2" = "-ss" ]; then
        echo "Invalid data found when processing input" >&2
        exit 1
      fi
      eval "target=\\${$#}"
      cp #{prepared} "$target"
      """)

      File.chmod!(stub, 0o755)
      Application.put_env(:mydia, :ffmpeg_path, stub)
      on_exit(fn -> Application.delete_env(:mydia, :ffmpeg_path) end)

      assert {:ok, %Result{} = result} = Fpcalc.fingerprint("/any/episode.mkv", 7, 130)

      # Reaching a real fingerprint at all means the input-seek attempt failed
      # and the output-seek retry carried it.
      assert length(result.hashes) > 900
      assert result.window_start_ms == 7_000
      assert_in_delta result.frame_ms, 124.17, 3.0
    end
  end
end
