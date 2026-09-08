defmodule Mydia.Downloads.FfmpegMp4HwaccelTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.FfmpegMp4Transcoder
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc]
  }

  defp args(opts) do
    FfmpegMp4Transcoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out.mp4", :p1080, opts)
  end

  test "without capabilities the arguments are unchanged" do
    result = args([])

    assert "libx264" in result
    refute "-hwaccel" in result
  end

  test "a decodable source uses the hardware encoder" do
    result = args(capabilities: @vaapi, source_codec: "hevc")

    assert "h264_vaapi" in result
    assert Enum.find_index(result, &(&1 == "-hwaccel")) < Enum.find_index(result, &(&1 == "-i"))
  end

  test "the fragmented MP4 flags survive acceleration" do
    # These are what make the file playable before the download completes;
    # losing them would break progressive playback silently.
    result = args(capabilities: @vaapi, source_codec: "hevc")

    assert "+frag_keyframe+empty_moov+default_base_moof" in result
  end

  test "the resolution preset is applied through the filter, not -s" do
    # -s and a hardware filter chain cannot both set geometry; -s would force a
    # software scale after the frames are already on the GPU.
    result = args(capabilities: @vaapi, source_codec: "hevc")

    refute "-s" in result
    assert Enum.any?(result, &String.contains?(&1, "scale_vaapi"))
  end

  test "retries a hardware failure once and no more" do
    output = "Device creation failed: -5."

    assert FfmpegMp4Transcoder.retry_in_software?(%{
             hwaccel_retried: false,
             output_buffer: output
           })

    refute FfmpegMp4Transcoder.retry_in_software?(%{hwaccel_retried: true, output_buffer: output})
  end

  test "an ordinary encode failure is never retried" do
    refute FfmpegMp4Transcoder.retry_in_software?(%{
             hwaccel_retried: false,
             output_buffer: "Invalid data found when processing input"
           })
  end
end
