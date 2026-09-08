defmodule Mydia.Streaming.HwaccelLiveTest do
  @moduledoc """
  Exercises real hardware. Skipped unless run with `--include hwaccel` on a host
  with a working VA device.

  Every other hwaccel test in this directory (`hardware_accel_test.exs`,
  `ffmpeg_hwaccel_args_test.exs`, `hwaccel_failure_classifier_test.exs`) asserts
  on argument lists as strings. This is the one place those strings are actually
  handed to ffmpeg: the whole value of this suite is proving that what
  `Mydia.Streaming.HardwareAccel.Args.build/2` emits is something ffmpeg
  accepts, not merely something that looks right.

  Requires `vainfo` (from `libva-utils`) and a usable `/dev/dri/renderD*` node.
  Tagged `:hwaccel`, a tag distinct from `:ffmpeg`: the latter needs only the
  ffmpeg binary, this needs a working GPU, so a developer with ffmpeg but no
  render node can run one without the other. Excluded by default in
  test_helper.exs; run explicitly with `--include hwaccel`.
  """
  use ExUnit.Case, async: false

  @moduletag :hwaccel

  alias Mydia.Streaming.HardwareAccel.Args
  alias Mydia.Streaming.HardwareAccel.Probe

  setup_all do
    caps = Probe.run(hwaccel: :auto)

    if caps.backend == :none do
      raise "no hardware device available: #{caps.reason}"
    end

    {:ok, caps: caps}
  end

  defp run(args) do
    System.cmd(System.find_executable("ffmpeg"), args, stderr_to_stdout: true)
  end

  defp source(codec, pix_fmt) do
    path = Path.join(System.tmp_dir!(), "hwaccel_src_#{codec}.mkv")

    {_out, 0} =
      run([
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=640x480:duration=2:rate=24",
        "-pix_fmt",
        pix_fmt,
        "-c:v",
        codec,
        path
      ])

    on_exit(fn -> File.rm(path) end)
    path
  end

  test "the probe reports a device that can encode h264", %{caps: caps} do
    assert caps.backend == :vaapi
    assert :h264 in caps.encoders
    assert caps.device =~ "/dev/dri/renderD"
  end

  test "the full hardware argument list encodes a real file", %{caps: caps} do
    path = source("libx264", "yuv420p")
    accel = Args.build(caps, source_codec: "h264", max_height: 360)

    assert accel.tier == :full_hardware

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error"] ++
          accel.input ++ ["-i", path] ++ accel.video ++ ["-f", "null", "-"]
      )

    assert status == 0, "hardware encode failed: #{output}"
  end

  test "the hybrid argument list encodes a real file", %{caps: caps} do
    # Forced by claiming the device decodes nothing, which is how this tier gets
    # exercised on hardware that does not need it.
    path = source("libx264", "yuv420p")
    accel = Args.build(%{caps | decode_profiles: []}, source_codec: "h264", max_height: 360)

    assert accel.tier == :hybrid

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error"] ++
          accel.input ++ ["-i", path] ++ accel.video ++ ["-f", "null", "-"]
      )

    assert status == 0, "hybrid encode failed: #{output}"
  end

  test "a bitrate cap is honoured by the hardware encoder", %{caps: caps} do
    path = source("libx264", "yuv420p")
    accel = Args.build(caps, source_codec: "h264", video_bitrate_kbps: 500)
    out = Path.join(System.tmp_dir!(), "hwaccel_capped.mp4")
    on_exit(fn -> File.rm(out) end)

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error", "-y"] ++
          accel.input ++ ["-i", path] ++ accel.video ++ [out]
      )

    assert status == 0, "capped encode failed: #{output}"

    {probe, 0} =
      System.cmd(System.find_executable("ffprobe"), [
        "-v",
        "error",
        "-show_entries",
        "format=bit_rate",
        "-of",
        "csv=p=0",
        out
      ])

    bitrate = probe |> String.trim() |> String.to_integer()
    assert bitrate < 900_000, "expected the 500k cap to hold, got #{bitrate}"
  end
end
