defmodule Mydia.Streaming.CodecTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.Codec

  describe "normalize_video_codec/1" do
    test "normalizes H.264 variants" do
      assert Codec.normalize_video_codec("h264") == "h264"
      assert Codec.normalize_video_codec("H.264") == "h264"
      assert Codec.normalize_video_codec("H.264 (High)") == "h264"
      assert Codec.normalize_video_codec("x264") == "h264"
      assert Codec.normalize_video_codec("avc") == "h264"
      assert Codec.normalize_video_codec("avc1") == "h264"
    end

    test "normalizes HEVC/H.265 variants" do
      assert Codec.normalize_video_codec("hevc") == "hevc"
      assert Codec.normalize_video_codec("HEVC") == "hevc"
      assert Codec.normalize_video_codec("h265") == "hevc"
      assert Codec.normalize_video_codec("H.265") == "hevc"
      assert Codec.normalize_video_codec("x265") == "hevc"
      assert Codec.normalize_video_codec("x.265") == "hevc"
    end

    test "normalizes VP9 variants" do
      assert Codec.normalize_video_codec("vp9") == "vp9"
      assert Codec.normalize_video_codec("VP9") == "vp9"
      assert Codec.normalize_video_codec("vp09") == "vp9"
    end

    test "normalizes AV1 variants" do
      assert Codec.normalize_video_codec("av1") == "av1"
      assert Codec.normalize_video_codec("AV1") == "av1"
      assert Codec.normalize_video_codec("av01") == "av1"
    end

    test "normalizes MPEG-4 variants" do
      assert Codec.normalize_video_codec("mpeg4") == "mpeg4"
      assert Codec.normalize_video_codec("MPEG-4") == "mpeg4"
      assert Codec.normalize_video_codec("xvid") == "mpeg4"
      assert Codec.normalize_video_codec("divx") == "mpeg4"
    end

    test "returns nil for nil input" do
      assert Codec.normalize_video_codec(nil) == nil
    end

    test "returns lowercase for unknown codecs" do
      assert Codec.normalize_video_codec("SomeUnknownCodec") == "someunknowncodec"
    end
  end

  describe "normalize_audio_codec/1" do
    test "normalizes AAC variants" do
      assert Codec.normalize_audio_codec("aac") == "aac"
      assert Codec.normalize_audio_codec("AAC") == "aac"
      assert Codec.normalize_audio_codec("AAC (LC)") == "aac"
      assert Codec.normalize_audio_codec("AAC 5.1") == "aac"
    end

    test "normalizes AC-3/Dolby Digital variants" do
      assert Codec.normalize_audio_codec("ac3") == "ac3"
      assert Codec.normalize_audio_codec("AC-3") == "ac3"
      assert Codec.normalize_audio_codec("ac-3") == "ac3"
      assert Codec.normalize_audio_codec("Dolby Digital") == "ac3"
      assert Codec.normalize_audio_codec("AC3 5.1") == "ac3"
      assert Codec.normalize_audio_codec("DD5.1") == "ac3"
    end

    test "normalizes E-AC3/Dolby Digital Plus variants" do
      # "DD+ 5.1" is what FileAnalyzer writes for an eac3 stream.
      assert Codec.normalize_audio_codec("DD+ 5.1") == "eac3"
      assert Codec.normalize_audio_codec("DD+") == "eac3"
      assert Codec.normalize_audio_codec("eac3") == "eac3"
      assert Codec.normalize_audio_codec("E-AC-3") == "eac3"
      assert Codec.normalize_audio_codec("DDP5.1") == "eac3"
      assert Codec.normalize_audio_codec("Dolby Digital Plus") == "eac3"
    end

    test "normalizes DTS variants" do
      assert Codec.normalize_audio_codec("dts") == "dts"
      assert Codec.normalize_audio_codec("DTS") == "dts"
    end

    test "normalizes DTS-HD variants" do
      assert Codec.normalize_audio_codec("dts-hd") == "dts-hd"
      assert Codec.normalize_audio_codec("DTS-HD MA") == "dts-hd"
      assert Codec.normalize_audio_codec("dts-hdma") == "dts-hd"
      assert Codec.normalize_audio_codec("DTS-X") == "dts-hd"
    end

    test "normalizes TrueHD variants" do
      assert Codec.normalize_audio_codec("truehd") == "truehd"
      assert Codec.normalize_audio_codec("TrueHD") == "truehd"
      assert Codec.normalize_audio_codec("mlp") == "truehd"
    end

    test "normalizes common web codecs" do
      assert Codec.normalize_audio_codec("mp3") == "mp3"
      assert Codec.normalize_audio_codec("opus") == "opus"
      assert Codec.normalize_audio_codec("vorbis") == "vorbis"
      assert Codec.normalize_audio_codec("flac") == "flac"
    end

    test "returns nil for nil input" do
      assert Codec.normalize_audio_codec(nil) == nil
    end

    test "returns lowercase for unknown codecs" do
      assert Codec.normalize_audio_codec("SomeUnknownCodec") == "someunknowncodec"
    end
  end

  describe "browser_compatible_video?/1" do
    test "returns true for browser-compatible codecs" do
      assert Codec.browser_compatible_video?("h264") == true
      assert Codec.browser_compatible_video?("H.264") == true
      assert Codec.browser_compatible_video?("vp9") == true
      assert Codec.browser_compatible_video?("av1") == true
      assert Codec.browser_compatible_video?("vp8") == true
    end

    test "returns false for incompatible codecs" do
      assert Codec.browser_compatible_video?("hevc") == false
      assert Codec.browser_compatible_video?("H.265") == false
      assert Codec.browser_compatible_video?("mpeg4") == false
      assert Codec.browser_compatible_video?("wmv3") == false
    end

    test "returns false for nil" do
      assert Codec.browser_compatible_video?(nil) == false
    end
  end

  describe "browser_compatible_audio?/1" do
    test "returns true for browser-compatible codecs" do
      assert Codec.browser_compatible_audio?("aac") == true
      assert Codec.browser_compatible_audio?("AAC") == true
      assert Codec.browser_compatible_audio?("mp3") == true
      assert Codec.browser_compatible_audio?("opus") == true
      assert Codec.browser_compatible_audio?("vorbis") == true
      assert Codec.browser_compatible_audio?("flac") == true
    end

    test "returns false for incompatible codecs" do
      assert Codec.browser_compatible_audio?("ac3") == false
      assert Codec.browser_compatible_audio?("dts") == false
      assert Codec.browser_compatible_audio?("truehd") == false
      assert Codec.browser_compatible_audio?("dts-hd") == false
    end

    test "returns false for nil" do
      assert Codec.browser_compatible_audio?(nil) == false
    end
  end
end
