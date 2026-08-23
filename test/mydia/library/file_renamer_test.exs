defmodule Mydia.Library.FileRenamerTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.Quality
  alias Mydia.Library.FileRenamer

  describe "build_quality_info/1" do
    test "builds Quality from MediaFile with full metadata" do
      file = %Mydia.Library.MediaFile{
        resolution: "1080p",
        codec: "x264",
        audio_codec: "DTS",
        hdr_format: nil,
        dolby_vision_profile: nil,
        metadata: %Mydia.Library.Structs.FileMetadata{source: "BluRay"}
      }

      result = FileRenamer.build_quality_info(file)

      assert %Quality{} = result
      assert result.resolution == "1080p"
      assert result.source == "BluRay"
      assert result.codec == "x264"
      assert result.audio == "DTS"
      refute Quality.hdr?(result)
      assert result.hdr_format == nil
      refute result.dolby_vision
      assert result.proper == false
      assert result.repack == false
    end

    test "builds Quality with a base HDR format" do
      file = %Mydia.Library.MediaFile{
        resolution: "2160p",
        codec: "x265",
        audio_codec: "TrueHD Atmos",
        hdr_format: :hdr10,
        dolby_vision_profile: nil,
        metadata: %Mydia.Library.Structs.FileMetadata{source: "BluRay"}
      }

      result = FileRenamer.build_quality_info(file)

      assert result.resolution == "2160p"
      assert Quality.hdr?(result)
      assert result.hdr_format == :hdr10
      refute result.dolby_vision
      assert result.audio == "TrueHD Atmos"
    end

    test "builds Quality with Dolby Vision from a profile on the MediaFile" do
      file = %Mydia.Library.MediaFile{
        resolution: "2160p",
        codec: "x265",
        audio_codec: "TrueHD Atmos",
        hdr_format: :hdr10,
        dolby_vision_profile: 8,
        metadata: %Mydia.Library.Structs.FileMetadata{source: "BluRay"}
      }

      result = FileRenamer.build_quality_info(file)

      assert result.dolby_vision
      assert result.hdr_format == :hdr10
    end

    test "handles nil metadata gracefully" do
      file = %Mydia.Library.MediaFile{
        resolution: "720p",
        codec: "x264",
        audio_codec: nil,
        hdr_format: nil,
        metadata: nil
      }

      result = FileRenamer.build_quality_info(file)

      assert result.resolution == "720p"
      assert result.source == nil
      assert result.codec == "x264"
      assert result.audio == nil
    end

    test "handles empty FileMetadata struct" do
      file = %Mydia.Library.MediaFile{
        resolution: "1080p",
        codec: "x265",
        audio_codec: "AAC",
        hdr_format: nil,
        metadata: %Mydia.Library.Structs.FileMetadata{}
      }

      result = FileRenamer.build_quality_info(file)

      assert result.source == nil
      assert result.codec == "x265"
      assert result.audio == "AAC"
    end

    test "handles all nil fields" do
      file = %Mydia.Library.MediaFile{
        resolution: nil,
        codec: nil,
        audio_codec: nil,
        hdr_format: nil,
        metadata: nil
      }

      result = FileRenamer.build_quality_info(file)

      assert %Quality{} = result
      assert result.resolution == nil
      assert result.source == nil
      assert result.codec == nil
      assert result.audio == nil
      refute Quality.hdr?(result)
    end
  end
end
