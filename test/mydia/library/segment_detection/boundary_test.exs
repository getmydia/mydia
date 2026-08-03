defmodule Mydia.Library.SegmentDetection.BoundaryTest do
  # refine_end/2 mutates Application env for the ffmpeg path, so serial.
  use ExUnit.Case, async: false

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.SegmentDetection.Boundary

  setup do
    on_exit(fn -> Application.delete_env(:mydia, :ffmpeg_path) end)

    :ok
  end

  describe "parse_black_intervals/2" do
    test "extracts black start times and offsets them by the window start" do
      output = """
      [blackdetect @ 0x55] black_start:2.5 black_end:3.1 black_duration:0.6
      [blackdetect @ 0x55] black_start:18.25 black_end:20 black_duration:1.75
      """

      # Window began at 1_300_000ms, so times are relative to that.
      assert Boundary.parse_black_intervals(output, 1_300_000) == [1_302_500, 1_318_250]
    end

    test "parses ffmpeg's real output, including whole-second timestamps" do
      output =
        "[Parsed_blackdetect_0 @ 0x703384003700] " <>
          "black_start:19 black_end:19.5 black_duration:0.5\n"

      assert Boundary.parse_black_intervals(output, 6_000) == [25_000]
    end

    test "returns an empty list when no black interval was reported" do
      assert Boundary.parse_black_intervals("no detections here", 0) == []
    end

    test "ignores malformed black_start values" do
      output = "[blackdetect] black_start:abc black_end:1.0\n"

      assert Boundary.parse_black_intervals(output, 0) == []
    end

    test "keeps the detections that precede a truncated final line" do
      output = "[blackdetect] black_start:4.0 black_end:4.5\n[blackdetect] black_st"

      assert Boundary.parse_black_intervals(output, 0) == [4_000]
    end
  end

  describe "pick_end/2" do
    test "snaps to the latest black start inside the window" do
      assert Boundary.pick_end([1_290_000, 1_310_000], 1_300_000) == 1_310_000
    end

    test "keeps the original end when there are no candidates" do
      assert Boundary.pick_end([], 1_300_000) == 1_300_000
    end
  end

  describe "search_window/1" do
    test "spans the detected end plus and minus the window" do
      assert {1_280_000, 40_000} = Boundary.search_window(1_300_000)
    end

    test "clamps at the start of the file without searching past the end" do
      assert {0, 25_000} = Boundary.search_window(5_000)
    end
  end

  describe "refine_end/2" do
    test "returns the original end when ffmpeg cannot run" do
      Application.put_env(:mydia, :ffmpeg_path, "/nonexistent/ffmpeg-binary")

      assert Boundary.refine_end("/some/file.mkv", 1_300_000) == 1_300_000
    end

    test "returns the original end when ffmpeg cannot read the file" do
      assert Boundary.refine_end("/nonexistent/definitely-not-here.mkv", 1_300_000) == 1_300_000
    end

    @tag :tmp_dir
    test "snaps the end back to the black cut in a generated clip", %{tmp_dir: tmp_dir} do
      # 25s white, then a 0.5s black cut, then 4.5s more white. The true picture
      # end is at 25_000ms; a fingerprint-derived end lands a second past it.
      #
      # The black cut is deliberately shorter than blackdetect's default minimum
      # duration of 2.0s, so this fails if @min_black_duration is reverted.
      path = Path.join(tmp_dir, "credits.mp4")

      assert {:ok, _} =
               Ffmpeg.run([
                 "-nostdin",
                 "-y",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=c=white:s=64x48:r=10:d=25",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=c=black:s=64x48:r=10:d=0.5",
                 "-f",
                 "lavfi",
                 "-i",
                 "color=c=white:s=64x48:r=10:d=4.5",
                 "-filter_complex",
                 "[0:v][1:v][2:v]concat=n=3:v=1:a=0[out]",
                 "-map",
                 "[out]",
                 "-c:v",
                 "libx264",
                 "-preset",
                 "ultrafast",
                 "-pix_fmt",
                 "yuv420p",
                 path
               ])

      refined = Boundary.refine_end(path, 26_000)

      assert refined != 26_000
      assert_in_delta refined, 25_000, 200
    end
  end
end
