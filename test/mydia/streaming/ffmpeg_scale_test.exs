defmodule Mydia.Streaming.FfmpegScaleTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  defp filter(args), do: Enum.at(args, index_of(args, "-vf") + 1)

  describe "build_ffmpeg_args/3 scaling" do
    test "emits no scale filter when no height is requested" do
      # Native resolution is the correct default: a forced transcode caused by
      # an incompatible codec should not also silently downgrade resolution.
      refute "-vf" in args(video_codec: "libx264")
    end

    test "never emits the old fixed -s geometry" do
      # -s forces exact dimensions with no aspect handling, which squishes
      # anything that is not 16:9. It must not come back.
      refute "-s" in args(video_codec: "libx264", max_height: 720)
    end

    test "emits an aspect-preserving scale filter for a requested height" do
      assert filter(args(video_codec: "libx264", max_height: 720)) ==
               "scale=-2:min(720\\,ih)"
    end

    test "escapes the comma rather than shell-quoting the expression" do
      # Arguments go to a port with no shell, so a shell-quoted
      # 'min(1080,ih)' arrives with its quotes intact and fails to parse.
      # FFmpeg reads a bare comma as a filter separator, so it must be
      # backslash-escaped instead.
      result = filter(args(video_codec: "libx264", max_height: 1080))

      assert result == "scale=-2:min(1080\\,ih)"
      refute String.contains?(result, "'")
    end

    test "clamps rather than upscales, via min() against the input height" do
      # A 480p source with the 1080p rung selected must stay 480p. The clamp
      # lives in the filter itself so the transcoder needs no probe.
      assert filter(args(video_codec: "libx264", max_height: 1080)) =~ "ih"
    end

    test "emits no scale filter on a stream-copy path" do
      # There is no decoded frame to scale when the video stream is copied.
      refute "-vf" in args(video_codec: "copy", max_height: 720)
    end

    test "still ends with the playlist path" do
      assert List.last(args(video_codec: "libx264", max_height: 720)) ==
               "/tmp/out/index.m3u8"
    end
  end
end
