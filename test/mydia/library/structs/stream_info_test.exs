defmodule Mydia.Library.Structs.StreamInfoTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.StreamInfo

  describe "from_ffprobe_stream/1" do
    test "parses a video stream" do
      stream = %{
        "index" => 0,
        "codec_type" => "video",
        "codec_name" => "hevc",
        "codec_long_name" => "H.265 / HEVC",
        "profile" => "Main 10",
        "level" => 153,
        "width" => 3840,
        "height" => 2160,
        "avg_frame_rate" => "24000/1001",
        "pix_fmt" => "yuv420p10le",
        "color_space" => "bt2020nc",
        "color_transfer" => "smpte2084",
        "color_primaries" => "bt2020",
        "display_aspect_ratio" => "16:9",
        "bit_rate" => "38100000"
      }

      assert %StreamInfo{} = info = StreamInfo.from_ffprobe_stream(stream)
      assert info.type == :video
      assert info.index == 0
      assert info.codec == "hevc"
      assert info.profile == "Main 10"
      assert info.level == 153
      assert info.width == 3840
      assert info.height == 2160
      assert info.frame_rate == 23.976
      assert info.bit_depth == 10
      assert info.color_transfer == "smpte2084"
      assert info.bitrate == 38_100_000
    end

    test "parses an audio stream with tags and disposition" do
      stream = %{
        "index" => 1,
        "codec_type" => "audio",
        "codec_name" => "truehd",
        "channels" => 8,
        "channel_layout" => "7.1",
        "sample_rate" => "48000",
        "bit_rate" => "6200000",
        "tags" => %{"language" => "eng", "title" => "Atmos"},
        "disposition" => %{"default" => 1, "comment" => 0}
      }

      assert %StreamInfo{} = info = StreamInfo.from_ffprobe_stream(stream)
      assert info.type == :audio
      assert info.channels == 8
      assert info.channel_layout == "7.1"
      assert info.sample_rate == 48_000
      assert info.language == "eng"
      assert info.title == "Atmos"
      assert info.is_default == true
      assert info.is_commentary == false
    end

    test "reads uppercase Matroska tag keys" do
      stream = %{
        "index" => 2,
        "codec_type" => "subtitle",
        "codec_name" => "subrip",
        "tags" => %{"LANGUAGE" => "spa", "TITLE" => "Spanish"}
      }

      info = StreamInfo.from_ffprobe_stream(stream)
      assert info.language == "spa"
      assert info.title == "Spanish"
    end

    test "extracts the Dolby Vision profile from side data" do
      stream = %{
        "index" => 0,
        "codec_type" => "video",
        "codec_name" => "hevc",
        "side_data_list" => [
          %{"side_data_type" => "DOVI configuration record", "dv_profile" => 7}
        ]
      }

      assert StreamInfo.from_ffprobe_stream(stream).dolby_vision_profile == 7
    end

    test "scrubs invalid UTF-8 out of titles" do
      stream = %{
        "index" => 1,
        "codec_type" => "audio",
        "codec_name" => "aac",
        "tags" => %{"title" => <<"Commentary ", 0xFF, 0xFE>>}
      }

      title = StreamInfo.from_ffprobe_stream(stream).title
      assert String.valid?(title)
      assert String.starts_with?(title, "Commentary ")
    end

    test "returns nil for a malformed frame rate rather than raising" do
      stream = %{
        "index" => 0,
        "codec_type" => "video",
        "codec_name" => "h264",
        "avg_frame_rate" => "0/0"
      }

      assert StreamInfo.from_ffprobe_stream(stream).frame_rate == nil
    end

    test "falls back to 8-bit depth for an 8-bit pixel format" do
      stream = %{"index" => 0, "codec_type" => "video", "pix_fmt" => "yuv420p"}
      assert StreamInfo.from_ffprobe_stream(stream).bit_depth == 8
    end

    test "drops attachment and data streams" do
      assert StreamInfo.from_ffprobe_stream(%{"codec_type" => "attachment"}) == nil
      assert StreamInfo.from_ffprobe_stream(%{"codec_type" => "data"}) == nil
      assert StreamInfo.from_ffprobe_stream(%{}) == nil
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through string-keyed maps" do
      original = %StreamInfo{
        index: 1,
        type: :audio,
        codec: "eac3",
        channels: 6,
        channel_layout: "5.1",
        is_default: false,
        is_forced: false
      }

      assert original |> StreamInfo.to_map() |> StreamInfo.from_map() == original
    end

    test "to_map drops nil fields but keeps false booleans" do
      map = StreamInfo.to_map(%StreamInfo{index: 0, type: :video, is_default: false})

      refute Map.has_key?(map, "width")
      refute Map.has_key?(map, "language")
      assert map["type"] == "video"
      assert map["is_default"] == false
    end

    test "from_map ignores unknown keys" do
      info = StreamInfo.from_map(%{"type" => "video", "codec" => "av1", "bogus" => 1})
      assert info.type == :video
      assert info.codec == "av1"
    end
  end
end
