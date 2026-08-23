defmodule Mydia.Streaming.DeviceProfileTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.DeviceProfile

  describe "browser_default/0" do
    test "carries the container, video and audio lists Compatibility used to hardcode" do
      profile = DeviceProfile.browser_default()

      assert "mp4" in profile.containers
      assert "webm" in profile.containers
      assert "m4v" in profile.containers
      assert "h264" in profile.video_codecs
      assert "aac" in profile.audio_codecs
    end

    test "allows no HDR format, so an HDR file is never direct play by default" do
      assert DeviceProfile.browser_default().hdr_formats == []
    end
  end

  describe "container_allowed?/2" do
    test "matches exactly and case-insensitively" do
      profile = %DeviceProfile{containers: ["mp4", "mkv"]}

      assert DeviceProfile.container_allowed?(profile, "mp4")
      assert DeviceProfile.container_allowed?(profile, "MKV")
      refute DeviceProfile.container_allowed?(profile, "avi")
      refute DeviceProfile.container_allowed?(profile, nil)
    end

    test "does not substring match, so mp4 does not admit mp4x" do
      profile = %DeviceProfile{containers: ["mp4"]}

      refute DeviceProfile.container_allowed?(profile, "mp4x")
    end
  end

  describe "video_codec_allowed?/2" do
    test "substring matches so ffprobe display strings still resolve" do
      profile = %DeviceProfile{video_codecs: ["h264"]}

      assert DeviceProfile.video_codec_allowed?(profile, "h264")
      assert DeviceProfile.video_codec_allowed?(profile, "H264 (High)")
      refute DeviceProfile.video_codec_allowed?(profile, "hevc")
      refute DeviceProfile.video_codec_allowed?(profile, nil)
    end

    test "a native profile listing hevc admits hevc" do
      profile = %DeviceProfile{video_codecs: ["h264", "hevc"]}

      assert DeviceProfile.video_codec_allowed?(profile, "hevc")
    end
  end

  describe "audio_codec_allowed_or_absent?/2" do
    test "a nil audio codec is allowed" do
      assert DeviceProfile.audio_codec_allowed_or_absent?(%DeviceProfile{audio_codecs: []}, nil)
    end

    test "substring matches, and rejects what is not listed" do
      profile = %DeviceProfile{audio_codecs: ["aac"]}

      assert DeviceProfile.audio_codec_allowed_or_absent?(profile, "AAC 5.1")
      refute DeviceProfile.audio_codec_allowed_or_absent?(profile, "truehd")
    end
  end

  describe "hdr_allowed_or_absent?/2" do
    test "a nil hdr format is unconstrained" do
      assert DeviceProfile.hdr_allowed_or_absent?(%DeviceProfile{hdr_formats: []}, nil)
    end

    test "a present hdr format must be listed" do
      profile = %DeviceProfile{hdr_formats: ["hdr10"]}

      assert DeviceProfile.hdr_allowed_or_absent?(profile, "HDR10")
      refute DeviceProfile.hdr_allowed_or_absent?(profile, "dolby_vision")
    end
  end

  describe "from_map/1" do
    test "builds a profile from string-keyed JSON" do
      assert {:ok, profile} =
               DeviceProfile.from_map(%{
                 "containers" => ["mkv", "mp4"],
                 "videoCodecs" => ["h264", "hevc"],
                 "audioCodecs" => ["aac", "ac3"],
                 "hdrFormats" => ["hdr10"]
               })

      assert profile.containers == ["mkv", "mp4"]
      assert profile.video_codecs == ["h264", "hevc"]
      assert profile.audio_codecs == ["aac", "ac3"]
      assert profile.hdr_formats == ["hdr10"]
    end

    test "downcases every entry so matching never has to" do
      assert {:ok, profile} = DeviceProfile.from_map(%{"containers" => ["MKV"]})
      assert profile.containers == ["mkv"]
    end

    test "defaults missing lists to empty" do
      assert {:ok, profile} = DeviceProfile.from_map(%{"containers" => ["mp4"]})
      assert profile.video_codecs == []
    end

    test "rejects a list longer than 64 entries" do
      too_many = Enum.map(1..65, &"codec#{&1}")
      assert :error = DeviceProfile.from_map(%{"videoCodecs" => too_many})
    end

    test "rejects an entry longer than 64 characters" do
      assert :error = DeviceProfile.from_map(%{"containers" => [String.duplicate("a", 65)]})
    end

    test "rejects a non-list value" do
      assert :error = DeviceProfile.from_map(%{"containers" => "mp4"})
    end

    test "rejects a non-map input" do
      assert :error = DeviceProfile.from_map("mp4")
    end

    test "never creates atoms from input keys" do
      before = :erlang.system_info(:atom_count)
      DeviceProfile.from_map(%{"totallyNewKeyName#{System.unique_integer([:positive])}" => ["x"]})
      assert :erlang.system_info(:atom_count) == before
    end
  end
end
