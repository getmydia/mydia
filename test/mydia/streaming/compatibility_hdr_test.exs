defmodule Mydia.Streaming.CompatibilityHdrTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Streaming.{Compatibility, DeviceProfile, Tonemap}

  @zscale %Tonemap{zscale: true}
  @both %Tonemap{zscale: true, libplacebo: true}

  defp file(hdr_attrs, container \\ "mp4") do
    struct!(
      %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{container: container},
        relative_path: "video.#{container}"
      },
      hdr_attrs
    )
  end

  defp profile(hdr_formats) do
    %DeviceProfile{
      containers: ["mp4"],
      video_codecs: ["hevc"],
      audio_codecs: ["aac"],
      hdr_formats: hdr_formats
    }
  end

  defp verdict(file, hdr_formats, tonemap) do
    Compatibility.check_compatibility(file, profile(hdr_formats), tonemap: tonemap)
  end

  test "SDR plays directly" do
    assert verdict(file(%{}), [], @zscale) == :direct_play
  end

  test "HDR10 plays directly on a client that lists hdr10" do
    assert verdict(file(%{hdr_format: :hdr10}), ["hdr10"], @zscale) == :direct_play
  end

  test "HDR10 is transcoded for a client without HDR when the server can tonemap" do
    assert verdict(file(%{hdr_format: :hdr10}), [], @zscale) == :needs_transcoding
  end

  test "HDR in a remuxable container goes to transcoding, never remux" do
    assert verdict(file(%{hdr_format: :hdr10}, "mkv"), [], @zscale) == :needs_transcoding
  end

  test "Dolby Vision 8 with an HDR10 base plays on an hdr10 client" do
    f = file(%{hdr_format: :hdr10, dolby_vision_profile: 8})
    assert verdict(f, ["hdr10"], @zscale) == :direct_play
  end

  test "Dolby Vision 5 is transcoded when libplacebo is available" do
    f = file(%{dolby_vision_profile: 5})
    assert verdict(f, ["hdr10", "hlg"], @both) == :needs_transcoding
  end

  test "Dolby Vision 5 stays direct play when the server cannot tonemap it" do
    f = file(%{dolby_vision_profile: 5})
    assert verdict(f, ["hdr10"], @zscale) == :direct_play
  end

  test "HDR10+ plays on a client that lists hdr10+" do
    assert verdict(file(%{hdr_format: :hdr10_plus}), ["hdr10+"], @zscale) == :direct_play
  end

  test "HDR10 stays direct play when the server cannot tonemap" do
    assert verdict(file(%{hdr_format: :hdr10}), [], Tonemap.none()) == :direct_play
  end

  test "the shipped player's list accepts every HDR flavour" do
    shipped = ["hdr10", "hdr10+", "hlg", "dolby_vision"]

    for attrs <- [
          %{hdr_format: :hdr10},
          %{hdr_format: :hdr10_plus},
          %{hdr_format: :hlg},
          %{hdr_format: :hdr10, dolby_vision_profile: 8},
          %{dolby_vision_profile: 5}
        ] do
      assert verdict(file(attrs), shipped, @both) == :direct_play
    end
  end

  test "conditions_reject?/3 is true for HDR the client cannot show" do
    assert Compatibility.conditions_reject?(file(%{hdr_format: :hdr10}), profile([]),
             tonemap: @zscale
           )
  end

  test "conditions_reject?/3 is false for HDR the client lists" do
    refute Compatibility.conditions_reject?(file(%{hdr_format: :hdr10}), profile(["hdr10"]),
             tonemap: @zscale
           )
  end

  test "hdr_rejects?/3 is false for SDR" do
    refute Compatibility.hdr_rejects?(file(%{}), profile([]), @zscale)
  end
end
