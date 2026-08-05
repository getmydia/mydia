defmodule Mydia.Streaming.FfmpegScaleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Streaming.FfmpegHlsTranscoder

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  defp filter(args), do: Enum.at(args, index_of(args, "-vf") + 1)

  describe "build_ffmpeg_args/3 scaling" do
    test "still evens the height when no ceiling is requested" do
      # Native resolution is the correct default: a forced transcode caused by
      # an incompatible codec should not also silently downgrade resolution.
      # But "no ceiling" cannot mean "no filter": an odd source height then
      # reaches libx264 untouched and kills the encode. This is the DEFAULT
      # path — direct connection, Original rung, no configured ceiling — so it
      # is the one most worth pinning.
      assert filter(args(video_codec: "libx264")) == "scale=-2:2*trunc(ih/2)"
    end

    test "the uncapped filter cannot downscale" do
      # `2*trunc(ih/2)` is at most `ih` and never below `ih - 1`, so the only
      # thing it can do to an even source is nothing at all. Anything that
      # clamped here would be a silent resolution downgrade on every
      # transcode, which is the behaviour this branch exists to remove.
      result = filter(args(video_codec: "libx264"))

      refute String.contains?(result, "min(")
      refute result =~ ~r/\d{3,}/
    end

    test "never emits the old fixed -s geometry" do
      # -s forces exact dimensions with no aspect handling, which squishes
      # anything that is not 16:9. It must not come back.
      refute "-s" in args(video_codec: "libx264", max_height: 720)
    end

    test "emits an aspect-preserving scale filter for a requested height" do
      assert filter(args(video_codec: "libx264", max_height: 720)) ==
               "scale=-2:2*trunc(min(720\\,ih)/2)"
    end

    test "escapes the comma rather than shell-quoting the expression" do
      # Arguments go to a port with no shell, so a shell-quoted
      # 'min(1080,ih)' arrives with its quotes intact and fails to parse.
      # FFmpeg reads a bare comma as a filter separator, so it must be
      # backslash-escaped instead.
      result = filter(args(video_codec: "libx264", max_height: 1080))

      assert result == "scale=-2:2*trunc(min(1080\\,ih)/2)"
      refute String.contains?(result, "'")
    end

    test "rounds the clamped height down to an even number" do
      # The clamp returns `ih` untouched whenever the source is shorter than
      # the cap, so an odd-height source reaches libx264 as-is. With
      # -pix_fmt yuv420p that fails to open the encoder outright, killing the
      # transcode before a playlist exists — see ffmpeg_scale_live_test.exs,
      # which runs this exact filter through FFmpeg.
      assert filter(args(video_codec: "libx264", max_height: 720)) =~ "2*trunc("
    end

    test "ignores a non-positive ceiling but still evens the height" do
      # Only reachable through a misconfigured streaming.max_transcode_height;
      # the config schema rejects it, but a stale cached runtime config could
      # still carry one. Silently ignoring it would leave the operator
      # wondering why their ceiling does nothing, so it logs — and the encode
      # still gets the evening filter, since a bad ceiling is no reason to
      # hand libx264 an odd height.
      log =
        capture_log(fn ->
          assert filter(args(video_codec: "libx264", max_height: 0)) ==
                   "scale=-2:2*trunc(ih/2)"

          assert filter(args(video_codec: "libx264", max_height: -720)) ==
                   "scale=-2:2*trunc(ih/2)"
        end)

      assert log =~ "non-positive transcode height ceiling (0)"
      assert log =~ "non-positive transcode height ceiling (-720)"
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
