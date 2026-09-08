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

    # Shared by the full-hardware and hybrid tests below: both only assert
    # that ffmpeg accepts the argument list, so a plain testsrc clip is
    # enough, and building it once instead of once per test avoids encoding
    # the same file three times.
    source = build_source("testsrc=size=640x480:rate=24", "plain")

    {:ok, caps: caps, source: source}
  end

  defp run(args) do
    System.cmd(System.find_executable("ffmpeg"), args, stderr_to_stdout: true)
  end

  # Cleanup is registered before the encode runs, not after a successful
  # pattern match on its result: a generation failure must not leave a
  # partial file behind uncleaned.
  defp build_source(lavfi_filter, tag) do
    path =
      Path.join(
        System.tmp_dir!(),
        "hwaccel_src_#{tag}_#{System.unique_integer([:positive])}.mkv"
      )

    on_exit(fn -> File.rm(path) end)

    {_out, 0} =
      run([
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        lavfi_filter,
        "-t",
        "2",
        "-pix_fmt",
        "yuv420p",
        "-c:v",
        "libx264",
        path
      ])

    path
  end

  # Encodes `source` through `accel`'s argument list and returns the
  # resulting file's measured bitrate, per ffprobe. Used by the bitrate-cap
  # test to compare a capped encode against an uncapped control from the
  # same source and tier, rather than against a hardcoded ceiling.
  defp encode_and_measure(source, accel, tag) do
    out =
      Path.join(
        System.tmp_dir!(),
        "hwaccel_bitrate_#{tag}_#{System.unique_integer([:positive])}.mp4"
      )

    on_exit(fn -> File.rm(out) end)

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error", "-y"] ++
          accel.input ++ ["-i", source] ++ accel.video ++ [out]
      )

    assert status == 0, "#{tag} encode failed: #{output}"

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

    probe |> String.trim() |> String.to_integer()
  end

  test "the probe reports a device that can encode h264", %{caps: caps} do
    assert caps.backend == :vaapi
    assert :h264 in caps.encoders
    assert caps.device =~ "/dev/dri/renderD"
  end

  test "the full hardware argument list encodes a real file", %{caps: caps, source: source} do
    accel = Args.build(caps, source_codec: "h264", max_height: 360)

    assert accel.tier == :full_hardware

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error"] ++
          accel.input ++ ["-i", source] ++ accel.video ++ ["-f", "null", "-"]
      )

    assert status == 0, "hardware encode failed: #{output}"
  end

  test "the hybrid argument list encodes a real file", %{caps: caps, source: source} do
    # Forced by claiming the device decodes nothing, which is how this tier gets
    # exercised on hardware that does not need it.
    accel = Args.build(%{caps | decode_profiles: []}, source_codec: "h264", max_height: 360)

    assert accel.tier == :hybrid

    {output, status} =
      run(
        ["-hide_banner", "-loglevel", "error"] ++
          accel.input ++ ["-i", source] ++ accel.video ++ ["-f", "null", "-"]
      )

    assert status == 0, "hybrid encode failed: #{output}"
  end

  test "a bitrate cap is honoured by the hardware encoder", %{caps: caps} do
    # A plain testsrc clip compresses so well under CQP that its natural
    # bitrate can already sit below any cap worth testing, which would let a
    # threshold assertion pass even if -b:v/-maxrate/-rc_mode VBR silently
    # dropped out of rate_control_args/3. mandelbrot is a standard
    # torture-test source for exactly this: it has no static regions and its
    # detail keeps increasing as it zooms, so a CQP-23 encode of it lands far
    # above the 500k cap this test requests, guaranteeing the capped run has
    # real headroom to shrink into. The assertions below compare the capped
    # encode against an uncapped control from the same source and tier
    # instead of a bare threshold, so a regression that stops applying the
    # cap fails regardless of how compressible the source turns out to be.
    source = build_source("mandelbrot=size=640x480:rate=24", "entropy")

    control = Args.build(caps, source_codec: "h264")
    capped = Args.build(caps, source_codec: "h264", video_bitrate_kbps: 500)

    control_bitrate = encode_and_measure(source, control, "control")
    capped_bitrate = encode_and_measure(source, capped, "capped")

    assert capped_bitrate < control_bitrate * 0.6,
           "expected the 500k cap to shrink the output materially: " <>
             "control=#{control_bitrate}, capped=#{capped_bitrate}"

    assert capped_bitrate < 900_000,
           "expected the 500k cap to land near its target, got #{capped_bitrate}"
  end
end
