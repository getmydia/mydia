defmodule Mydia.Streaming.HardwareAccel.ArgsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Streaming.HardwareAccel.Args
  alias Mydia.Streaming.HardwareAccel.Capabilities

  defp vaapi(decode_profiles) do
    %Capabilities{
      backend: :vaapi,
      device: "/dev/dri/renderD128",
      encoders: [:h264],
      decode_profiles: decode_profiles
    }
  end

  defp software, do: Capabilities.software("no device")

  defp filter(%Args{video: video}), do: Enum.at(video, Enum.find_index(video, &(&1 == "-vf")) + 1)

  describe "tier selection" do
    test "software capabilities give the software tier" do
      assert %Args{tier: :software} = Args.build(software(), source_codec: "hevc")
    end

    test "a decodable source gives the full hardware tier" do
      assert %Args{tier: :full_hardware} = Args.build(vaapi([:hevc, :av1]), source_codec: "hevc")
    end

    test "an undecodable source gives the hybrid tier" do
      assert %Args{tier: :hybrid} = Args.build(vaapi([:hevc]), source_codec: "av1")
    end

    test "a device that cannot encode h264 gives software" do
      caps = %Capabilities{
        backend: :vaapi,
        device: "/dev/dri/renderD128",
        encoders: [],
        decode_profiles: [:hevc]
      }

      assert %Args{tier: :software} = Args.build(caps, source_codec: "hevc")
    end

    test "an unknown source codec gives hybrid, never full hardware" do
      # Failing open here would hand the GPU a stream it cannot decode and
      # produce a dead session rather than a slow one.
      assert %Args{tier: :hybrid} = Args.build(vaapi([:hevc]), source_codec: "some_new_codec")
    end
  end

  describe "software arguments are unchanged from today" do
    test "the full uncapped CRF argument list" do
      args = Args.build(software(), source_codec: "av1")

      assert args.input == []

      assert args.video == [
               "-c:v",
               "libx264",
               "-preset",
               "medium",
               "-pix_fmt",
               "yuv420p",
               "-profile:v",
               "high",
               "-g",
               "60",
               "-bf",
               "0",
               "-vf",
               "scale=-2:2*trunc(ih/2)",
               "-crf",
               "23"
             ]
    end

    test "the capped ABR argument list" do
      args =
        Args.build(software(), source_codec: "av1", max_height: 720, video_bitrate_kbps: 2872)

      assert args.video == [
               "-c:v",
               "libx264",
               "-preset",
               "medium",
               "-pix_fmt",
               "yuv420p",
               "-profile:v",
               "high",
               "-g",
               "60",
               "-bf",
               "0",
               "-vf",
               "scale=-2:2*trunc(min(720\\,ih)/2)",
               "-b:v",
               "2872k",
               "-maxrate",
               "2872k",
               "-bufsize",
               "5744k"
             ]
    end
  end

  describe "full hardware arguments" do
    test "hwaccel input args name the probed device" do
      args = Args.build(vaapi([:hevc]), source_codec: "hevc")

      assert args.input == [
               "-hwaccel",
               "vaapi",
               "-hwaccel_device",
               "/dev/dri/renderD128",
               "-hwaccel_output_format",
               "vaapi"
             ]
    end

    test "uses scale_vaapi with the same expression as the software filter" do
      args = Args.build(vaapi([:hevc]), source_codec: "hevc", max_height: 720)

      assert filter(args) == "scale_vaapi=w=-2:h=2*trunc(min(720\\,ih)/2):format=nv12"
    end

    test "drops -pix_fmt yuv420p" do
      # The filter chain already lands frames in nv12. Leaving the flag in makes
      # ffmpeg insert a download and re-upload that costs more than it saves.
      args = Args.build(vaapi([:hevc]), source_codec: "hevc")

      refute "-pix_fmt" in args.video
    end

    test "constant quality is CQP at the measured qp" do
      args = Args.build(vaapi([:hevc]), source_codec: "hevc")

      assert args.video == [
               "-c:v",
               "h264_vaapi",
               "-profile:v",
               "high",
               "-g",
               "60",
               "-bf",
               "0",
               "-vf",
               "scale_vaapi=w=-2:h=2*trunc(ih/2):format=nv12",
               "-rc_mode",
               "CQP",
               "-qp",
               "23"
             ]
    end

    test "a bitrate cap pins rc_mode to VBR" do
      args = Args.build(vaapi([:hevc]), source_codec: "hevc", video_bitrate_kbps: 2872)

      assert Enum.chunk_every(args.video, 2) |> Enum.member?(["-rc_mode", "VBR"])
      assert Enum.chunk_every(args.video, 2) |> Enum.member?(["-b:v", "2872k"])
      refute "-qp" in args.video
    end
  end

  describe "hybrid arguments" do
    test "init_hw_device and filter_hw_device are required for hwupload" do
      args = Args.build(vaapi([:hevc]), source_codec: "av1")

      assert args.input == [
               "-init_hw_device",
               "vaapi=hw:/dev/dri/renderD128",
               "-filter_hw_device",
               "hw"
             ]
    end

    test "keeps the software scale filter and appends the upload" do
      args = Args.build(vaapi([:hevc]), source_codec: "av1", max_height: 720)

      assert filter(args) == "scale=-2:2*trunc(min(720\\,ih)/2),format=nv12,hwupload"
    end

    test "encodes with the hardware encoder" do
      args = Args.build(vaapi([:hevc]), source_codec: "av1")

      assert "h264_vaapi" in args.video
      refute "libx264" in args.video
    end
  end

  describe "a non-positive height ceiling" do
    test "warns and falls back to the source resolution on every tier" do
      log =
        capture_log(fn ->
          assert filter(Args.build(software(), source_codec: "av1", max_height: 0)) ==
                   "scale=-2:2*trunc(ih/2)"
        end)

      assert log =~ "non-positive transcode height ceiling"
    end
  end
end
