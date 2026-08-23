defmodule Mydia.Streaming.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Streaming.Compatibility

  describe "check_compatibility/1" do
    test "returns :direct_play for H.264 + AAC in MP4" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        relative_path: "video.mp4",
        library_path: %Mydia.Settings.LibraryPath{path: "/path/to"}
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :direct_play for VP9 + Opus in WebM" do
      media_file = %MediaFile{
        codec: "vp9",
        audio_codec: "opus",
        metadata: %FileMetadata{container: "webm"},
        path: "/path/to/video.webm"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :direct_play for AV1 + AAC in MP4" do
      media_file = %MediaFile{
        codec: "av1",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :direct_play for case-insensitive codec names" do
      media_file = %MediaFile{
        codec: "H264",
        audio_codec: "AAC",
        metadata: %FileMetadata{container: "MP4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :direct_play for AVC codec variant" do
      media_file = %MediaFile{
        codec: "avc1",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :needs_transcoding for HEVC codec" do
      media_file = %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_transcoding for H.265 codec" do
      media_file = %MediaFile{
        codec: "h265",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_remux for MKV container with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "returns :needs_remux for AVI container with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "avi"},
        path: "/path/to/video.avi"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "returns :needs_remux for MOV container with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mov"},
        path: "/path/to/video.mov"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "returns :needs_remux for TS container with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "ts"},
        path: "/path/to/video.ts"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "returns :needs_remux for FLV container with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "flv"},
        path: "/path/to/video.flv"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "returns :needs_transcoding for MKV with incompatible video codec" do
      media_file = %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_transcoding for MKV with incompatible audio codec" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "dts",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_transcoding for AC3 audio codec" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "ac3",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_transcoding for DTS audio codec" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "dts",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :needs_transcoding when codec is nil" do
      media_file = %MediaFile{
        codec: nil,
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "returns :direct_play when audio_codec is nil (video-only files are allowed)" do
      # Videos without audio should still be playable if video codec is compatible
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: nil,
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "returns :needs_transcoding when container is nil and path has no extension" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{},
        relative_path: "video",
        library_path: %Mydia.Settings.LibraryPath{path: "/path/to"}
      }

      assert Compatibility.check_compatibility(media_file) == :needs_transcoding
    end

    test "uses file extension when container not in metadata" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{},
        relative_path: "video.mp4",
        library_path: %Mydia.Settings.LibraryPath{path: "/path/to"}
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end

    test "handles FFprobe format_name with comma-separated values" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{format_name: "mov,mp4,m4a,3gp,3g2,mj2"},
        path: "/path/to/video.mov"
      }

      # Should use first format (mov) which is remuxable with compatible codecs
      assert Compatibility.check_compatibility(media_file) == :needs_remux
    end

    test "handles FFprobe format_name with mp4" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{format_name: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(media_file) == :direct_play
    end
  end

  describe "transcoding_reason/1" do
    test "returns container format reason for MKV" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.transcoding_reason(media_file) == "Incompatible container format (mkv)"
    end

    test "returns video codec reason for HEVC" do
      media_file = %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.transcoding_reason(media_file) == "Incompatible video codec (hevc)"
    end

    test "returns audio codec reason for AC3" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "ac3",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.transcoding_reason(media_file) == "Incompatible audio codec (ac3)"
    end

    test "returns unknown reason for nil codec" do
      media_file = %MediaFile{
        codec: nil,
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.transcoding_reason(media_file) == "Incompatible video codec (unknown)"
    end

    test "returns video codec reason when both codec and container are incompatible" do
      media_file = %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      # Video codec issue takes precedence over container issue
      assert Compatibility.transcoding_reason(media_file) == "Incompatible video codec (hevc)"
    end
  end

  describe "remux_reason/1" do
    test "returns container remux reason" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.remux_reason(media_file) == "Container (mkv) requires remuxing to fMP4"
    end

    test "returns container remux reason for AVI" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "avi"},
        path: "/path/to/video.avi"
      }

      assert Compatibility.remux_reason(media_file) == "Container (avi) requires remuxing to fMP4"
    end
  end

  describe "needs_remux?/1" do
    test "returns true for MKV with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.needs_remux?(media_file) == true
    end

    test "returns false for MP4 with compatible codecs" do
      media_file = %MediaFile{
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.needs_remux?(media_file) == false
    end

    test "returns false for MKV with incompatible codecs" do
      media_file = %MediaFile{
        codec: "hevc",
        audio_codec: "dts",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      assert Compatibility.needs_remux?(media_file) == false
    end
  end

  describe "check_compatibility/2 with a device profile" do
    alias Mydia.Streaming.DeviceProfile

    defp mkv_hevc_file do
      %MediaFile{
        codec: "hevc",
        audio_codec: "ac3",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }
    end

    test "an mkv/hevc file needs transcoding under the browser default" do
      assert Compatibility.check_compatibility(mkv_hevc_file(), DeviceProfile.browser_default()) ==
               :needs_transcoding
    end

    test "the same file is direct play under a native profile listing mkv, hevc and ac3" do
      profile = %DeviceProfile{
        containers: ["mkv", "mp4"],
        video_codecs: ["h264", "hevc"],
        audio_codecs: ["aac", "ac3"],
        hdr_formats: []
      }

      assert Compatibility.check_compatibility(mkv_hevc_file(), profile) == :direct_play
    end

    test "a profile that allows the codecs but not the container gets remux, not direct play" do
      profile = %DeviceProfile{
        containers: ["mp4"],
        video_codecs: ["hevc"],
        audio_codecs: ["ac3"],
        hdr_formats: []
      }

      assert Compatibility.check_compatibility(mkv_hevc_file(), profile) == :needs_remux
    end

    test "an HDR file with browser-compatible codecs still direct plays with no profile" do
      # Regression guard. Compatibility did not read hdr_format before device
      # profiles existed, and it must not start now: the transcoder has no
      # tonemapping, so forcing a transcode here would produce washed-out SDR
      # from correct HDR. VP9 and AV1 HDR are the real cases; browsers decode
      # both natively.
      file = %MediaFile{
        codec: "vp9",
        audio_codec: "opus",
        hdr_format: "HDR10",
        metadata: %FileMetadata{container: "webm"},
        path: "/path/to/video.webm"
      }

      assert Compatibility.check_compatibility(file) == :direct_play
    end

    test "a profile that lists hdr_formats does not yet constrain playback" do
      # hdr_formats is parsed and validated but deliberately unenforced. If this
      # test starts failing, HDR enforcement was switched on; make sure it went
      # through Hdr.profile_tokens/1 and not string equality on the column.
      file = %MediaFile{
        codec: "hevc",
        audio_codec: "aac",
        hdr_format: "Dolby Vision",
        metadata: %FileMetadata{container: "mkv"},
        path: "/path/to/video.mkv"
      }

      profile = %DeviceProfile{
        containers: ["mkv"],
        video_codecs: ["hevc"],
        audio_codecs: ["aac"],
        hdr_formats: ["hdr10"]
      }

      assert Compatibility.check_compatibility(file, profile) == :direct_play
    end

    test "an RFC 6381 video codec string now resolves, widening the old exact match" do
      file = %MediaFile{
        codec: "avc1.640028",
        audio_codec: "aac",
        metadata: %FileMetadata{container: "mp4"},
        path: "/path/to/video.mp4"
      }

      assert Compatibility.check_compatibility(file) == :direct_play
    end
  end
end
