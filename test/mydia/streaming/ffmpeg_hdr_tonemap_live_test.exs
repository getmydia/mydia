defmodule Mydia.Streaming.FfmpegHdrTonemapLiveTest do
  # Runs the zscale tonemap chain the transcoder emits through a real FFmpeg.
  #
  # The argument tests assert on the string; only FFmpeg can say whether it
  # accepts it, and whether a frame that arrives tagged HDR comes out tagged
  # and shaped as SDR. Same shape as ffmpeg_scale_live_test.exs: tagged
  # :requires_ffmpeg, which is not excluded, and a real ExUnit skip when the
  # host cannot run it (ffmpeg without zscale, or without libx265).
  use ExUnit.Case, async: true

  alias Mydia.HdrFixture
  alias Mydia.Library.MediaFile
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.Tonemap

  @moduletag :requires_ffmpeg

  filters_and_encoders = fn ->
    case System.find_executable("ffmpeg") do
      nil ->
        nil

      ffmpeg ->
        {filters, _} = System.cmd(ffmpeg, ["-hide_banner", "-filters"], stderr_to_stdout: true)
        {encoders, _} = System.cmd(ffmpeg, ["-hide_banner", "-encoders"], stderr_to_stdout: true)
        {filters, encoders}
    end
  end

  skip_reason =
    case filters_and_encoders.() do
      nil ->
        "ffmpeg not found on PATH"

      {filters, encoders} ->
        cond do
          is_nil(System.find_executable("ffprobe")) -> "ffprobe not found on PATH"
          not String.contains?(filters, " zscale ") -> "ffmpeg has no zscale filter"
          not String.contains?(encoders, "libx265") -> "ffmpeg has no libx265 encoder"
          true -> nil
        end
    end

  if skip_reason, do: @moduletag(skip: skip_reason)

  @moduletag :tmp_dir

  defp transcode(clip, format, out_dir) do
    File.mkdir_p!(out_dir)

    args =
      FfmpegHlsTranscoder.build_ffmpeg_args(clip, out_dir,
        media_file: %MediaFile{codec: "hevc", hdr_format: format},
        tonemap: %Tonemap{zscale: true},
        capabilities: Capabilities.software("test"),
        max_height: 720
      )

    # Without this the test passes on an SDR-shaped plan that never tonemapped.
    assert Enum.any?(args, &String.contains?(&1, "zscale=t=linear")),
           "plan did not select the zscale chain: #{inspect(args)}"

    # The transcoder asks for progress on stdout and logs at info; the check
    # only needs the exit status and the files.
    {out, status} = System.cmd("ffmpeg", ["-nostdin" | args], stderr_to_stdout: true)
    {out, status}
  end

  defp probe_stream(path) do
    {out, status} =
      System.cmd(
        "ffprobe",
        [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=pix_fmt,color_transfer,color_primaries,color_space",
          "-of",
          "json",
          path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "ffprobe failed on #{path}:\n#{out}"
    out |> Jason.decode!() |> Map.fetch!("streams") |> hd()
  end

  defp assert_tonemapped(clip_fun, format, tmp_dir) do
    clip = clip_fun.(tmp_dir, 1080)
    out_dir = Path.join(tmp_dir, "out_#{format}")

    {out, status} = transcode(clip, format, out_dir)
    assert status == 0, "ffmpeg rejected the tonemap chain:\n#{out}"

    playlist = Path.join(out_dir, "index.m3u8")
    assert File.exists?(playlist)
    assert File.read!(playlist) =~ "segment_00000.ts"

    segment = Path.join(out_dir, "segment_00000.ts")
    assert File.stat!(segment).size > 0

    stream = probe_stream(segment)
    assert stream["pix_fmt"] == "yuv420p"

    assert stream["color_transfer"] in ["bt709", nil],
           "output is still tagged HDR: #{inspect(stream)}"

    assert stream["color_primaries"] != "bt2020"
    refute stream["color_transfer"] in ["smpte2084", "arib-std-b67"]
  end

  describe "the emitted zscale tonemap chain, through FFmpeg" do
    @tag :requires_ffmpeg
    test "turns an HDR10 clip into SDR", %{tmp_dir: tmp_dir} do
      assert_tonemapped(&HdrFixture.hdr10_clip/2, :hdr10, tmp_dir)
    end

    @tag :requires_ffmpeg
    test "turns an HLG clip into SDR", %{tmp_dir: tmp_dir} do
      assert_tonemapped(&HdrFixture.hlg_clip/2, :hlg, tmp_dir)
    end
  end
end
