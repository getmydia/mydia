defmodule Mydia.Streaming.FfmpegScaleLiveTest do
  # Runs the scale filter the transcoder actually emits through a real FFmpeg.
  #
  # Every other test in this directory asserts on the argument *string*, which
  # is why a filter FFmpeg rejects outright reached a final review twice. Both
  # escapes were the same mechanism: an odd frame height reaching libx264 with
  # -pix_fmt yuv420p, which refuses to open the encoder ("height not divisible
  # by 2", exit 187). No playlist is ever written, so the client's playlist
  # wait times out and the viewer sees a generic playback error with nothing
  # in it that points at the filter.
  #
  # The two ways an odd height gets there:
  #   * under a cap, when the source is shorter than it and the clamp returns
  #     `ih` untouched;
  #   * with no cap at all, which used to emit no filter whatsoever. That is
  #     the default path — direct connection, Original rung, no configured
  #     ceiling — so it is the one that matters most.
  #
  # Tagged :requires_ffmpeg, which test_helper.exs deliberately does NOT
  # exclude: this is meant to run. On a host genuinely without FFmpeg the
  # whole module skips (reported as skipped, never as passed) — run with
  # `--exclude requires_ffmpeg` to leave it out on purpose.
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  @moduletag :requires_ffmpeg

  # A real ExUnit skip rather than an `if available? do ... else assert true`
  # branch. The branch shape reports green on a host with no FFmpeg, which for
  # a test whose entire value is "FFmpeg accepted this argument" is the worst
  # possible outcome: it looks like coverage and is not.
  if is_nil(System.find_executable("ffmpeg")) or
       is_nil(System.find_executable("ffprobe")) do
    @moduletag skip: "ffmpeg/ffprobe not found on PATH"
  end

  # The filter exactly as the transcoder builds it, not a copy of it. A test
  # that hardcoded the string would keep passing after the transcoder drifted.
  #
  # `max_height: nil` is a real case, not a degenerate one: it is what an
  # uncapped session passes, and it must still produce a filter.
  defp emitted_filter(max_height) do
    args =
      FfmpegHlsTranscoder.build_ffmpeg_args(
        "/tmp/unused-input.mkv",
        "/tmp/unused-output",
        video_codec: "libx264",
        max_height: max_height
      )

    index = Enum.find_index(args, &(&1 == "-vf"))

    assert index, "the transcoder emitted no -vf filter for max_height #{inspect(max_height)}"

    Enum.at(args, index + 1)
  end

  # Encodes one frame of a synthetic source through the filter, with the same
  # encoder settings production uses (ffmpeg_hls_transcoder.ex:511-524) and the
  # same delivery: a bare argument list handed to a port, no shell.
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
          "-profile:v",
          "high",
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
    {out, status} =
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

    # Asserted rather than pattern-matched: a MatchError here reports as a
    # crash in the helper and buries ffprobe's own explanation.
    assert status == 0, "ffprobe failed on #{path}:\n#{out}"

    out |> String.trim() |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

  defp assert_encodes(source_size, max_height) do
    {status, out, output} = encode(source_size, max_height)

    assert status == 0,
           "ffmpeg refused #{source_size} at #{inspect(max_height)}:\n#{out}"

    dimensions(output)
  end

  describe "the emitted scale filter, through FFmpeg" do
    @tag :requires_ffmpeg
    test "encodes an odd-height source with no cap at all" do
      # The default path: no rung chosen, no relay clamp, no configured
      # ceiling. Emitting no filter here is what the old `-s 1280x720` used to
      # make impossible by accident, and removing that hardcoded geometry took
      # the accidental evening with it. 405 -> 404, and the width follows.
      assert assert_encodes("640x405", nil) == [638, 404]
    end

    @tag :requires_ffmpeg
    test "encodes an ordinary odd-height rip with no cap" do
      # 848x477 is a common SD rip shape. Same failure, no exotic source
      # needed to reach it.
      assert assert_encodes("848x477", nil) == [846, 476]
    end

    @tag :requires_ffmpeg
    test "leaves an even source untouched when there is no cap" do
      # The uncapped filter must not be a downscale in disguise: an even
      # source has to come back at exactly its own size.
      assert assert_encodes("1920x1080", nil) == [1920, 1080]
    end

    @tag :requires_ffmpeg
    test "encodes an odd-height source that is shorter than the cap" do
      # 405 is below the 720 ceiling, so the clamp returns it unchanged and
      # libx264 sees an odd height. Both dimensions come back even, and the
      # width tracks the rounded height rather than staying at 640, which is
      # what keeps the aspect ratio.
      assert assert_encodes("640x405", 720) == [638, 404]
    end

    @tag :requires_ffmpeg
    test "downscales a wider-than-16:9 source to the cap without distorting it" do
      # 1920x804 is 2.39:1. The old `-s 1280x720` squished this; the filter
      # keeps the aspect ratio and lands on the cap exactly.
      assert assert_encodes("1920x804", 720) == [1720, 720]
    end

    @tag :requires_ffmpeg
    test "leaves a source below the cap at its own size" do
      assert assert_encodes("640x480", 1080) == [640, 480]
    end

    @tag :requires_ffmpeg
    test "rounds an odd source height down rather than up" do
      # 1079 -> 1078, never 1080: rounding up would upscale by a line, which
      # the no-upscale clamp exists to prevent.
      assert assert_encodes("1920x1079", 1080) == [1918, 1078]
    end
  end
end
