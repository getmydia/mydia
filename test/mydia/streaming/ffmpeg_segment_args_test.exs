defmodule Mydia.Streaming.FfmpegSegmentArgsTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.SegmentPlan

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp value_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  describe "segment naming" do
    test "uses a five-digit pattern that SegmentPlan can reproduce" do
      assert value_after(args([]), "-hls_segment_filename") == "/tmp/out/segment_%05d.ts"
    end

    test "renames nothing until a segment is complete" do
      # Without temp_file a partially written segment exists on disk, and the
      # session would serve a truncated file to the player.
      assert value_after(args([]), "-hls_flags") == "temp_file"
    end
  end

  describe "start_number" do
    test "defaults to zero so a first window numbers from the start of the file" do
      assert value_after(args([]), "-start_number") == "0"
    end

    test "carries the absolute index of a relocated window" do
      # The playlist names segment_00100.ts for t=400s. A relocated encoder has
      # to write that exact filename, not segment_00000.ts.
      assert value_after(args(start_number: 100), "-start_number") == "100"
    end
  end

  describe "timestamps" do
    test "keeps source timestamps so a relocated segment carries its real media time" do
      assert "-copyts" in args(start_number: 100)
    end

    test "zeroes the muxer delay, which -copyts alone does not correct for" do
      # Measured in the design spike: the TS muxer's defaults put every window,
      # including the first, 1.4s away from the time the published playlist
      # declares for it. -copyts does not touch this. Dropping either of these
      # two silently reintroduces that offset on every segment of every session.
      result = args(start_number: 100)

      assert value_after(result, "-muxdelay") == "0"
      assert value_after(result, "-muxpreload") == "0"
    end

    test "never applies the seek offset twice" do
      # -output_ts_offset on top of -copyts double-applies it. Measured and
      # rejected in the spike.
      refute "-output_ts_offset" in args(start_number: 100)
    end
  end

  describe "keyframe alignment" do
    test "forces keyframes onto the segment grid when re-encoding" do
      assert value_after(args(grid_aligned: true), "-force_key_frames") ==
               "expr:gte(t,n_forced*#{SegmentPlan.default_segment_seconds()})"
    end

    test "omits forced keyframes when not asked for" do
      # A copied video stream has the keyframes the source gave it. Asking
      # FFmpeg to force them on a copy is an error, not a no-op.
      refute "-force_key_frames" in args([])
    end
  end

  describe "existing behaviour is preserved" do
    test "still segments at the plan's segment length" do
      assert value_after(args([]), "-hls_time") ==
               to_string(SegmentPlan.default_segment_seconds())
    end

    test "still keeps every segment in FFmpeg's own playlist" do
      assert value_after(args([]), "-hls_list_size") == "0"
    end

    test "still ends with the playlist path" do
      assert List.last(args([])) == "/tmp/out/index.m3u8"
    end

    test "still places -ss before -i" do
      result = args(start_position: 400)
      assert Enum.find_index(result, &(&1 == "-ss")) < Enum.find_index(result, &(&1 == "-i"))
    end
  end
end
