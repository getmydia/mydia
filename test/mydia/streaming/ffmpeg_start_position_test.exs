defmodule Mydia.Streaming.FfmpegStartPositionTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  describe "build_ffmpeg_args/3 start_position" do
    test "omits -ss entirely when no start position is given" do
      refute "-ss" in args([])
    end

    test "omits -ss when the start position is zero" do
      refute "-ss" in args(start_position: 0)
    end

    test "emits -ss with the requested offset in seconds" do
      result = args(start_position: 4200)

      assert "-ss" in result
      assert Enum.at(result, index_of(result, "-ss") + 1) == "4200"
    end

    test "places -ss before -i so FFmpeg uses fast input seeking" do
      # Output seeking (-ss after -i) decodes and discards everything up to the
      # offset, which for a resume an hour in would take far longer than the
      # user is willing to wait.
      result = args(start_position: 4200)

      assert index_of(result, "-ss") < index_of(result, "-i")
    end

    test "keeps the input path immediately after -i" do
      result = args(start_position: 4200)

      assert Enum.at(result, index_of(result, "-i") + 1) == "/tmp/in.mkv"
    end

    test "still ends with the playlist path" do
      assert List.last(args(start_position: 60)) == "/tmp/out/index.m3u8"
    end
  end
end
