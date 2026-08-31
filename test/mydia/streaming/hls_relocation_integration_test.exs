defmodule Mydia.Streaming.HlsRelocationIntegrationTest do
  @moduledoc """
  Runs a real FFmpeg and asserts that a relocated window produces the segment
  the published playlist promised, at the media time it promised.

  This is the Task 0 spike, kept. The design rests on an FFmpeg flag
  interaction, and a flag interaction is exactly the kind of thing that breaks
  silently on an FFmpeg upgrade.

  Tagged so it does not run in the default suite: it needs the ffmpeg binary
  and takes seconds rather than milliseconds. Excluded by default in
  test_helper.exs; run explicitly with `--include ffmpeg`.
  """
  use ExUnit.Case, async: false

  @moduletag :ffmpeg

  # A real ExUnit skip rather than an `if available? do ... else assert true`
  # branch, matching test/mydia/streaming/ffmpeg_scale_live_test.exs: a host
  # genuinely missing ffmpeg or ffprobe reports these as skipped, never as
  # passed.
  if is_nil(System.find_executable("ffmpeg")) or
       is_nil(System.find_executable("ffprobe")) do
    @moduletag skip: "ffmpeg/ffprobe not found on PATH"
  end

  alias Mydia.Streaming.{FfmpegHlsTranscoder, SegmentPlan}

  # The relocated segment must land on the media time the playlist promised.
  # Measured residual with the correct flags is about 21ms, constant across
  # offsets (the spike saw the same 21ms at t=400 that this test sees at
  # t=100), because it is a fixed muxer artifact rather than drift that
  # scales with position. Dropping `-muxdelay 0 -muxpreload 0` shifts it by
  # about +1.38s. This tolerance sits deliberately between the two: wide
  # enough for encoder jitter, tight enough that losing the muxer flags
  # fails loudly.
  @start_time_tolerance_seconds 0.25

  setup do
    tmp = Path.join(System.tmp_dir!(), "hls-relocation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    source = Path.join(tmp, "source.mp4")

    # A 120s synthetic source: deterministic, no fixture to commit, and long
    # enough that segment 25 is well past any first window.
    {_out, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=320x240:rate=25:duration=120",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=120",
          "-c:v",
          "libx264",
          "-preset",
          "ultrafast",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-shortest",
          source
        ],
        stderr_to_stdout: true
      )

    %{tmp: tmp, source: source}
  end

  test "a relocated window writes the promised filename at the promised time", %{
    tmp: tmp,
    source: source
  } do
    out = Path.join(tmp, "out")
    File.mkdir_p!(out)

    target_index = 25
    expected_start = SegmentPlan.start_time(elem(SegmentPlan.build(120.0), 1), target_index)
    assert expected_start == 100.0

    args =
      FfmpegHlsTranscoder.build_ffmpeg_args(source, out,
        start_position: trunc(expected_start),
        start_number: target_index,
        grid_aligned: true,
        absolute_timestamps: true
      )

    {_out, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

    segment = Path.join(out, SegmentPlan.segment_name(target_index))

    assert File.exists?(segment),
           "relocated window did not write #{SegmentPlan.segment_name(target_index)}"

    {start_time, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "format=start_time",
        "-of",
        "csv=p=0",
        segment
      ])

    actual = start_time |> String.trim() |> String.to_float()

    # The segment must carry its real media time, not restart near zero.
    # Without -copyts this is where the design fails.
    assert_in_delta actual, expected_start, @start_time_tolerance_seconds
  end
end
