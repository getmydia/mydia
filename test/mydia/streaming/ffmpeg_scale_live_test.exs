defmodule Mydia.Streaming.FfmpegScaleLiveTest do
  # Runs the scale filter the transcoder actually emits through a real FFmpeg.
  #
  # Every other test in this directory asserts on the argument *string*, which
  # is why a filter that FFmpeg rejects outright reached a final review: a
  # source shorter than the cap passes its own height through the clamp
  # untouched, and an odd height there makes libx264 with -pix_fmt yuv420p
  # refuse to open the encoder. No playlist is ever written, so the client's
  # playlist wait times out and the viewer sees a generic playback error with
  # nothing in it that points at the filter.
  #
  # Tagged :requires_ffmpeg, which test_helper.exs deliberately does NOT
  # exclude — this is meant to run.
  use ExUnit.Case, async: true

  alias Mydia.Library.ThumbnailGenerator
  alias Mydia.Streaming.FfmpegHlsTranscoder

  @moduletag :requires_ffmpeg

  # The filter exactly as the transcoder builds it, not a copy of it. A test
  # that hardcoded the string would keep passing after the transcoder drifted.
  defp emitted_filter(max_height) do
    args =
      FfmpegHlsTranscoder.build_ffmpeg_args(
        "/tmp/unused-input.mkv",
        "/tmp/unused-output",
        video_codec: "libx264",
        max_height: max_height
      )

    index = Enum.find_index(args, &(&1 == "-vf"))
    refute is_nil(index), "expected a -vf filter for max_height #{max_height}"
    Enum.at(args, index + 1)
  end

  # Encodes one frame of a synthetic source through the filter, exactly as
  # production does: a bare argument list handed to a port, no shell.
  defp encode(source_size, max_height) do
    output =
      Path.join(
        System.tmp_dir!(),
        "mydia_scale_#{source_size}_#{max_height}_#{:rand.uniform(1_000_000)}.mp4"
      )

    on_exit(fn -> File.rm(output) end)

    {out, status} =
      System.cmd(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=#{source_size}:rate=30:duration=0.2",
          "-frames:v",
          "1",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-vf",
          emitted_filter(max_height),
          "-y",
          output
        ],
        stderr_to_stdout: true
      )

    {status, out, output}
  end

  defp dimensions(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=width,height",
          "-of",
          "csv=p=0",
          path
        ],
        stderr_to_stdout: true
      )

    out |> String.trim() |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

  defp assert_encodes(source_size, max_height) do
    {status, out, output} = encode(source_size, max_height)

    assert status == 0,
           "ffmpeg refused #{source_size} at a #{max_height} cap:\n#{out}"

    dimensions(output)
  end

  describe "the emitted scale filter, through FFmpeg" do
    @tag :requires_ffmpeg
    test "encodes an odd-height source that is shorter than the cap" do
      if ThumbnailGenerator.ffmpeg_available?() do
        # The regression case. 405 is below the 720 ceiling, so the clamp
        # returns it unchanged and libx264 sees an odd height. Both dimensions
        # come back even, and the width tracks the rounded height rather than
        # staying at 640, which is what keeps the aspect ratio.
        assert assert_encodes("640x405", 720) == [638, 404]
      else
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      end
    end

    @tag :requires_ffmpeg
    test "downscales a wider-than-16:9 source to the cap without distorting it" do
      if ThumbnailGenerator.ffmpeg_available?() do
        # 1920x804 is 2.39:1. The old `-s 1280x720` squished this; the filter
        # keeps the aspect ratio and lands on the cap exactly.
        assert assert_encodes("1920x804", 720) == [1720, 720]
      else
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      end
    end

    @tag :requires_ffmpeg
    test "leaves a source below the cap at its own size" do
      if ThumbnailGenerator.ffmpeg_available?() do
        assert assert_encodes("640x480", 1080) == [640, 480]
      else
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      end
    end

    @tag :requires_ffmpeg
    test "rounds an odd source height down rather than up" do
      if ThumbnailGenerator.ffmpeg_available?() do
        # 1079 -> 1078, never 1080: rounding up would upscale by a line, which
        # the no-upscale clamp exists to prevent.
        assert assert_encodes("1920x1079", 1080) == [1918, 1078]
      else
        IO.puts("Skipping test: FFmpeg not available")
        assert true
      end
    end
  end
end
