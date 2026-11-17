defmodule Mydia.Streaming.FfmpegHdrTonemapArgsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Hdr
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Streaming.HardwareAccel.Args
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.StreamPlan
  alias Mydia.Streaming.Tonemap

  @h "2*trunc(min(720\\,ih)/2)"

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc]
  }

  @hdr10 %Hdr{base: :hdr10}
  @hlg %Hdr{base: :hlg}
  @dv5 %Hdr{base: nil, dv_profile: 5}

  @zscale_chain "scale=-2:#{@h},zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709," <>
                  "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

  defp build(caps, hdr, tonemap) do
    Args.build(caps,
      source_codec: "hevc",
      max_height: 720,
      hdr: hdr,
      tonemap: tonemap
    )
  end

  defp vf(%Args{video: video}) do
    idx = Enum.find_index(video, &(&1 == "-vf"))
    Enum.at(video, idx + 1)
  end

  test "SDR in software is unchanged" do
    args = build(Capabilities.software("t"), %Hdr{}, %Tonemap{zscale: true})
    assert vf(args) == "scale=-2:#{@h}"
    assert args.tonemap == :none
  end

  test "HDR10 in software uses the zscale chain" do
    args = build(Capabilities.software("t"), @hdr10, %Tonemap{zscale: true})
    assert vf(args) == @zscale_chain
    assert args.tonemap == :zscale
    assert args.tier == :software
  end

  test "HLG with vaapi on full hardware still uses zscale in software" do
    args = build(@vaapi, @hlg, %Tonemap{zscale: true, vaapi: true})
    assert vf(args) == @zscale_chain
    assert args.tier == :software
  end

  test "HDR10 on full hardware with vaapi tonemaps on the GPU" do
    args = build(@vaapi, @hdr10, %Tonemap{zscale: true, vaapi: true})

    assert vf(args) ==
             "scale_vaapi=w=-2:h=#{@h},tonemap_vaapi=format=nv12:t=bt709:m=bt709:p=bt709"

    assert args.tier == :full_hardware
    assert args.tonemap == :vaapi
    assert "-hwaccel" in args.input
  end

  test "HDR10 on full hardware without vaapi drops to software" do
    args = build(@vaapi, @hdr10, %Tonemap{zscale: true})
    assert args.tier == :software
    assert args.input == []
    assert vf(args) == @zscale_chain
    assert "libx264" in args.video
    assert "yuv420p" in args.video
  end

  test "Dolby Vision profile 5 uses libplacebo and a vulkan device" do
    args = build(@vaapi, @dv5, %Tonemap{libplacebo: true, zscale: true, vaapi: true})
    assert args.input == ["-init_hw_device", "vulkan"]
    assert args.tier == :software
    assert args.tonemap == :libplacebo

    assert vf(args) ==
             "libplacebo=w=-2:h=#{@h}:colorspace=bt709:color_primaries=bt709:color_trc=bt709:" <>
               "range=tv:tonemapping=bt.2390:apply_dolbyvision=1:format=yuv420p"
  end

  test "HDR10 with no tonemap capability is a plain scale" do
    args = build(Capabilities.software("t"), @hdr10, Tonemap.none())
    assert vf(args) == "scale=-2:#{@h}"
    assert args.tonemap == :none
  end

  test "tonemap_method/3 picks libplacebo over zscale only when zscale is missing" do
    assert Args.tonemap_method(%Tonemap{libplacebo: true}, @hdr10, :software) == :libplacebo

    assert Args.tonemap_method(%Tonemap{libplacebo: true, zscale: true}, @hdr10, :software) ==
             :zscale

    assert Args.tonemap_method(%Tonemap{vaapi: true, zscale: true}, @hdr10, :hybrid) == :zscale
  end

  test "StreamPlan.for_hls records the tonemap method" do
    file = %MediaFile{
      codec: "hevc",
      audio_codec: "aac",
      hdr_format: :hdr10,
      metadata: %FileMetadata{width: 3840, height: 2160}
    }

    plan =
      StreamPlan.for_hls(file,
        max_bitrate: 4000,
        capabilities: Capabilities.software("t"),
        tonemap: %Tonemap{zscale: true}
      )

    assert plan.video.tonemap == :zscale
  end
end
