defmodule Mydia.Streaming.HlsSeekAlignmentIntegrationTest do
  @moduledoc """
  Runs a real FFmpeg against the arguments the HLS transcoder builds and
  measures what a viewer sees after a seek: whether copied audio starts with
  the video, whether a :full session's first encoder cuts segments on the
  published grid, and whether a pinned stream copy starts on its keyframe.

  The source has a keyframe every 10s, and a white flash and a 1kHz beep that
  start together 3s into every 10s, so audio drifting from video shows up as a
  gap between the flash and the beep in the output.

  Tagged :ffmpeg like hls_relocation_integration_test.exs, and for the same
  reason: it guards FFmpeg flag behaviour that can change silently on an
  upgrade, needs the binaries, and takes seconds. Excluded by default; run it
  with `--include ffmpeg`, and after any FFmpeg bump.
  """
  use ExUnit.Case, async: false

  @moduletag :ffmpeg

  if is_nil(System.find_executable("ffmpeg")) or
       is_nil(System.find_executable("ffprobe")) do
    @moduletag skip: "ffmpeg/ffprobe not found on PATH"
  end

  alias Mydia.Streaming.{FfmpegHlsTranscoder, HlsSession, KeyframeLocator, SegmentPlan}
  alias Mydia.Streaming.HardwareAccel.Capabilities

  # Measured 3-13ms with -copypriorss:a 0 and 7.2s without it.
  @sync_tolerance 0.05
  # About one frame at 24fps.
  @grid_tolerance 0.05

  setup_all do
    tmp =
      Path.join(System.tmp_dir!(), "hls-seek-alignment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    mkv = Path.join(tmp, "source.mkv")

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "color=c=black:s=320x240:r=24:d=60," <>
        "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(mod(t,10),3,3.5)'",
      "-f",
      "lavfi",
      "-i",
      "sine=f=1000:sample_rate=48000:d=60," <>
        "volume=0:enable='not(between(mod(t,10),3,3.5))'",
      # veryfast keeps x264's B-frames, so the MKV carries the decode delay that
      # triggers FFmpeg's 3/23s seek pull-back.
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-g",
      "240",
      "-keyint_min",
      "240",
      "-sc_threshold",
      "0",
      "-c:a",
      "aac",
      "-b:a",
      "128k",
      mkv
    ])

    mp4 = Path.join(tmp, "source.mp4")
    ffmpeg!(["-i", mkv, "-c", "copy", mp4])

    ts = Path.join(tmp, "source.ts")
    ffmpeg!(["-i", mkv, "-c", "copy", ts])

    %{tmp: tmp, mkv: mkv, mp4: mp4, ts: ts}
  end

  test "a :window resume that copies audio starts both streams at the seek point",
       %{tmp: tmp, mkv: mkv} do
    out =
      run_hls(mkv, Path.join(tmp, "window_copy_audio"),
        start_position: 27,
        video_codec: "libx264",
        audio_codec: "copy"
      )

    segment = Path.join(out, SegmentPlan.segment_name(0))

    assert_in_delta first_pts(segment, "a:0"), first_pts(segment, "v:0"), @sync_tolerance
    assert_markers_in_sync(out)
  end

  test "a :full relocation that copies audio keeps absolute time and sync",
       %{tmp: tmp, mkv: mkv} do
    out =
      run_hls(mkv, Path.join(tmp, "full_relocation"),
        start_position: 28,
        start_number: 7,
        grid_aligned: true,
        absolute_timestamps: true,
        video_codec: "libx264",
        audio_codec: "copy"
      )

    segment = Path.join(out, SegmentPlan.segment_name(7))

    assert_in_delta first_pts(segment, "v:0"), 28.0, @sync_tolerance
    assert_in_delta first_pts(segment, "a:0"), 28.0, @sync_tolerance
    assert_markers_in_sync(out)
  end

  test "a resumed :full session's first encoder cuts segments on the published grid",
       %{tmp: tmp, mkv: mkv} do
    {:ok, plan} = SegmentPlan.build(60.0)
    first_index = SegmentPlan.index_for_time(plan, 30)

    out =
      run_hls(mkv, Path.join(tmp, "full_first_encoder"),
        start_position: HlsSession.encoder_start_position(plan, first_index, 30),
        start_number: first_index,
        grid_aligned: true,
        absolute_timestamps: true,
        video_codec: "libx264",
        audio_codec: "copy"
      )

    for index <- first_index..(first_index + 2) do
      assert_in_delta segment_start(Path.join(out, SegmentPlan.segment_name(index))),
                      SegmentPlan.start_time(plan, index),
                      @grid_tolerance
    end
  end

  test "a pinned MKV stream copy starts on the keyframe at or before the target",
       %{tmp: tmp, mkv: mkv} do
    assert {:ok, keyframe} = KeyframeLocator.locate(mkv, 27)
    # The muxer may shift every timestamp by the B-frame delay.
    assert_in_delta keyframe, 20.0, 0.2

    assert_pinned_copy_starts_on(mkv, Path.join(tmp, "pinned_mkv"), keyframe, 27)
  end

  test "a pinned MP4 stream copy starts on the keyframe the lookup found", %{tmp: tmp, mp4: mp4} do
    # MP4 seeks by decode timestamp, so 27s lands on the keyframe at 20 just
    # as MKV does. Only a target inside the B-frame delay before a keyframe
    # (under a quarter second) would land on that keyframe instead.
    assert {:ok, keyframe} = KeyframeLocator.locate(mp4, 27)
    assert_in_delta keyframe, 20.0, 0.2

    assert_pinned_copy_starts_on(mp4, Path.join(tmp, "pinned_mp4"), keyframe, 27)
  end

  test "an MPEG-TS source has no keyframe to pin", %{ts: ts} do
    # If this ever returns a keyframe, do not trust it: a TS copy seek lands
    # after its target. HlsSession.seek_opts/3 excludes TS by container for
    # exactly that reason.
    assert KeyframeLocator.locate(ts, 27) == :none
  end

  defp assert_pinned_copy_starts_on(source, out_dir, keyframe, start_position) do
    # absolute_timestamps only so the output carries source time to measure
    # against. The seek is input-side and identical without it.
    out =
      run_hls(source, out_dir,
        seek_keyframe: keyframe,
        start_position: start_position,
        video_codec: "copy",
        audio_codec: "copy",
        absolute_timestamps: true
      )

    assert_in_delta first_pts(Path.join(out, SegmentPlan.segment_name(0)), "v:0"),
                    keyframe,
                    0.001
  end

  defp run_hls(source, out, opts) do
    File.mkdir_p!(out)

    args =
      FfmpegHlsTranscoder.build_ffmpeg_args(
        source,
        out,
        [capabilities: Capabilities.software("integration test")] ++ opts
      )

    {output, status} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    assert status == 0, "ffmpeg failed: #{output}"
    out
  end

  defp ffmpeg!(args) do
    {output, status} =
      System.cmd("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y" | args],
        stderr_to_stdout: true
      )

    assert status == 0, "ffmpeg failed: #{output}"
  end

  defp first_pts(segment, stream) do
    {output, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        stream,
        "-show_entries",
        "packet=pts_time",
        "-of",
        "csv=p=0",
        segment
      ])

    output |> String.split("\n", trim: true) |> hd() |> to_seconds()
  end

  defp segment_start(segment) do
    {output, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "format=start_time",
        "-of",
        "csv=p=0",
        segment
      ])

    to_seconds(output)
  end

  # Every flash and beep in the output should start together. blackdetect's
  # black_end is where a flash begins and silencedetect's silence_end is where
  # a beep begins.
  defp assert_markers_in_sync(out) do
    {log, _status} =
      System.cmd(
        "ffmpeg",
        [
          "-hide_banner",
          "-i",
          Path.join(out, "index.m3u8"),
          "-vf",
          "blackdetect=d=0.1:pix_th=0.10",
          "-af",
          "silencedetect=n=-30dB:d=0.1",
          "-f",
          "null",
          "-"
        ],
        stderr_to_stdout: true
      )

    flashes = Regex.scan(~r/black_end:([\d.]+)/, log) |> Enum.map(fn [_, t] -> to_seconds(t) end)
    beeps = Regex.scan(~r/silence_end: ([\d.]+)/, log) |> Enum.map(fn [_, t] -> to_seconds(t) end)

    # The last black and silent stretch runs to the end of the file, so its
    # "end" is EOF rather than a marker (measured 52ms apart), and is dropped.
    pairs = flashes |> Enum.zip(beeps) |> Enum.drop(-1)
    assert pairs != [], "no markers detected in #{out}"

    for {flash, beep} <- pairs do
      assert_in_delta flash, beep, @sync_tolerance
    end
  end

  defp to_seconds(text) do
    {value, _rest} = text |> String.trim() |> String.trim_trailing(",") |> Float.parse()
    value
  end
end
