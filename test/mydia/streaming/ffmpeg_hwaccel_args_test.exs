defmodule Mydia.Streaming.FfmpegHwaccelArgsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc]
  }

  defp args(opts), do: FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)

  defp media_file(codec), do: %MediaFile{codec: codec, audio_codec: "aac"}

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  describe "with no capabilities available" do
    test "produces exactly today's software arguments" do
      result = args(video_codec: "libx264")

      assert "libx264" in result
      refute "h264_vaapi" in result
      refute "-hwaccel" in result
      assert "yuv420p" in result
    end
  end

  describe "with a VAAPI device" do
    test "hwaccel flags precede the input" do
      # -hwaccel after -i is silently ignored: ffmpeg has already chosen a
      # decoder by then.
      result = args(capabilities: @vaapi, media_file: media_file("hevc"))

      assert index_of(result, "-hwaccel") < index_of(result, "-i")
    end

    test "a decodable source uses the full hardware tier" do
      result = args(capabilities: @vaapi, media_file: media_file("hevc"))

      assert "h264_vaapi" in result
      assert "-hwaccel_output_format" in result
      refute "libx264" in result
      refute "yuv420p" in result
    end

    test "an undecodable source uses the hybrid tier" do
      result = args(capabilities: @vaapi, media_file: media_file("av1"))

      assert "h264_vaapi" in result
      assert "-init_hw_device" in result
      refute "-hwaccel_output_format" in result
    end

    test "a stream copy is never accelerated" do
      # Acceleration must not turn a copy into a transcode.
      result = args(capabilities: @vaapi, media_file: media_file("h264"), video_codec: "copy")

      assert "copy" in result
      refute "-hwaccel" in result
      refute "h264_vaapi" in result
    end

    test "the HLS muxing arguments are untouched" do
      result = args(capabilities: @vaapi, media_file: media_file("hevc"))

      assert "-hls_time" in result
      assert "temp_file" in result
      assert index_of(result, "-f") < index_of(result, "/tmp/out/index.m3u8")
    end

    test "a bitrate cap still reaches the encoder" do
      result = args(capabilities: @vaapi, media_file: media_file("hevc"), max_bitrate: 3000)

      assert "-rc_mode" in result
      assert "VBR" in result
      assert "2872k" in result
    end
  end
end
