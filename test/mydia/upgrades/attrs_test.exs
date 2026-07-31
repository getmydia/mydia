defmodule Mydia.Upgrades.AttrsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.{FileMetadata, Quality}
  alias Mydia.Upgrades.Attrs

  describe "from_media_file/2 resolution mapping" do
    test "maps the analyzer's 4K to the canonical 2160p" do
      file = %MediaFile{resolution: "4K", size: 1024 * 1024}
      assert %{resolution: "2160p"} = Attrs.from_media_file(file, :movie)
    end

    test "maps 1440p down to the nearest canonical rung, 1080p" do
      file = %MediaFile{resolution: "1440p", size: 1024 * 1024}
      assert %{resolution: "1080p"} = Attrs.from_media_file(file, :movie)
    end

    test "passes through an already canonical resolution" do
      file = %MediaFile{resolution: "1080p", size: 1024 * 1024}
      assert %{resolution: "1080p"} = Attrs.from_media_file(file, :movie)
    end

    test "yields nil for an unmappable resolution rather than guessing" do
      file = %MediaFile{resolution: "potato", size: 1024 * 1024}
      assert %{resolution: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 codec mapping" do
    test "strips the profile suffix from an H.264 display name" do
      file = %MediaFile{codec: "H.264 (High)", size: 1024 * 1024}
      assert %{video_codec: "h264"} = Attrs.from_media_file(file, :movie)
    end

    test "strips the profile suffix from an HEVC display name" do
      file = %MediaFile{codec: "HEVC (Main 10)", size: 1024 * 1024}
      assert %{video_codec: "h265"} = Attrs.from_media_file(file, :movie)
    end

    test "lowercases a bare codec name" do
      file = %MediaFile{codec: "AV1", size: 1024 * 1024}
      assert %{video_codec: "av1"} = Attrs.from_media_file(file, :movie)
    end

    test "maps bare x265 to the canonical h265" do
      file = %MediaFile{codec: "x265", size: 1024 * 1024}
      assert %{video_codec: "h265"} = Attrs.from_media_file(file, :movie)
    end

    test "maps bare x264 to the canonical h264" do
      file = %MediaFile{codec: "x264", size: 1024 * 1024}
      assert %{video_codec: "h264"} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 audio splitting" do
    test "splits a fused codec and channel string into both dimensions" do
      file = %MediaFile{audio_codec: "DD+ 5.1", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_codec == "eac3"
      assert attrs.audio_channels == "5.1"
    end

    test "maps the Stereo label to canonical 2.0" do
      file = %MediaFile{audio_codec: "AAC Stereo", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_codec == "aac"
      assert attrs.audio_channels == "2.0"
    end

    test "maps the Mono label to canonical 1.0" do
      file = %MediaFile{audio_codec: "AC3 Mono", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_codec == "ac3"
      assert attrs.audio_channels == "1.0"
    end

    test "leaves channels nil when the string carries no channel info" do
      file = %MediaFile{audio_codec: "PCM", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_channels == nil
    end

    test "prefers Atmos over TrueHD when a fused string carries both" do
      file = %MediaFile{audio_codec: "TrueHD Atmos", size: 1024 * 1024}
      attrs = Attrs.from_media_file(file, :movie)
      assert attrs.audio_codec == "atmos"
    end
  end

  describe "from_media_file/2 hdr mapping" do
    test "maps the Dolby Vision display name to its canonical token" do
      file = %MediaFile{hdr_format: "Dolby Vision", size: 1024 * 1024}
      assert %{hdr_format: "dolby_vision"} = Attrs.from_media_file(file, :movie)
    end

    test "maps the HDR10+ display name to its canonical token" do
      file = %MediaFile{hdr_format: "HDR10+", size: 1024 * 1024}
      assert %{hdr_format: "hdr10+"} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_media_file/2 source and size" do
    test "lifts source out of nested metadata to a top level key" do
      file = %MediaFile{metadata: %FileMetadata{source: "BluRay"}, size: 1024 * 1024}
      assert %{source: "BluRay"} = Attrs.from_media_file(file, :movie)
    end

    test "converts bytes to megabytes" do
      file = %MediaFile{size: 8 * 1024 * 1024 * 1024}
      assert %{file_size_mb: 8192} = Attrs.from_media_file(file, :movie)
    end

    test "leaves file_size_mb nil when size is nil" do
      file = %MediaFile{size: nil}
      assert %{file_size_mb: nil} = Attrs.from_media_file(file, :movie)
    end
  end

  describe "from_quality/3" do
    test "normalizes a parsed release title into the same vocabulary" do
      quality = %Quality{resolution: "2160p", codec: "x265", source: "BluRay", hdr_format: "DV"}
      attrs = Attrs.from_quality(quality, 20 * 1024 * 1024 * 1024, :movie)

      assert attrs.resolution == "2160p"
      assert attrs.video_codec == "h265"
      assert attrs.source == "BluRay"
      assert attrs.hdr_format == "dolby_vision"
      assert attrs.file_size_mb == 20_480
    end

    test "leaves unmentioned dimensions nil" do
      quality = %Quality{resolution: "1080p"}
      attrs = Attrs.from_quality(quality, nil, :movie)

      assert attrs.audio_codec == nil
      assert attrs.audio_channels == nil
      assert attrs.source == nil
    end
  end
end
