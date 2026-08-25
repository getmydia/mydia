defmodule Mydia.Streaming.CodecProfileCompatibilityTest do
  @moduledoc """
  The regression this module exists for.

  A Fire HD 10 played `Lanterns.2026.S01E02.1080p.x265-ELiTE.mkv` and got
  "Could not open codec." The client advertised `hevc` because that is what
  libmpv's `decoder-list` reports — a libavcodec *build* list, blind to profile
  and bit depth — so the server direct-played a HEVC Main 10 stream at a
  MediaCodec decoder that only opens Main. Audio (AC3) decoded fine, which is
  why sound played under the error screen.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Streaming.{Compatibility, DeviceProfile}

  # The real file, as the production analyzer recorded it.
  defp lanterns_media_file do
    %MediaFile{
      codec: "hevc",
      audio_codec: "ac3",
      metadata: %FileMetadata{
        container: "mkv",
        streams: [
          %StreamInfo{
            index: 0,
            type: :video,
            codec: "hevc",
            profile: "Main 10",
            level: 120,
            bit_depth: 10,
            width: 1920,
            height: 960,
            frame_rate: 23.976,
            pixel_format: "yuv420p10le"
          },
          %StreamInfo{
            index: 1,
            type: :audio,
            codec: "ac3",
            channels: 6,
            channel_layout: "5.1(side)",
            sample_rate: 48_000
          }
        ]
      },
      relative_path: "Lanterns/Season 01/Lanterns.2026.S01E02.1080p.x265-ELiTE.mkv",
      library_path: %Mydia.Settings.LibraryPath{path: "/media/Series"}
    }
  end

  # Same container and codecs, but 8-bit Main — what the tablet can actually open.
  defp main8_media_file do
    file = lanterns_media_file()
    [video, audio] = file.metadata.streams

    %{
      file
      | metadata: %{
          file.metadata
          | streams: [%{video | profile: "Main", bit_depth: 8}, audio]
        }
    }
  end

  defp profile_claiming_hevc(codec_profiles) do
    %DeviceProfile{
      containers: ["mkv", "matroska", "mp4"],
      video_codecs: ["hevc", "h264"],
      audio_codecs: ["ac3", "aac"],
      hdr_formats: [],
      codec_profiles: codec_profiles
    }
  end

  defp bit_depth_at_most(depth) do
    {:ok, codec_profile} =
      Mydia.Streaming.CodecProfile.from_map(%{
        "type" => "video",
        "codec" => "hevc",
        "conditions" => [
          %{
            "property" => "VideoBitDepth",
            "condition" => "LessThanEqual",
            "value" => to_string(depth)
          }
        ]
      })

    codec_profile
  end

  describe "a client that states its HEVC limits" do
    test "does not get a Main 10 stream direct-played at it" do
      profile = profile_claiming_hevc([bit_depth_at_most(8)])

      refute Compatibility.check_compatibility(lanterns_media_file(), profile) == :direct_play
      refute Compatibility.check_compatibility(lanterns_media_file(), profile) == :needs_remux

      assert Compatibility.check_compatibility(lanterns_media_file(), profile) ==
               :needs_transcoding
    end

    test "still direct-plays 8-bit HEVC, so the constraint costs nothing it can decode" do
      profile = profile_claiming_hevc([bit_depth_at_most(8)])

      assert Compatibility.check_compatibility(main8_media_file(), profile) == :direct_play
    end

    test "gets Main 10 direct-played when it says it can decode 10-bit" do
      profile = profile_claiming_hevc([bit_depth_at_most(10)])

      assert Compatibility.check_compatibility(lanterns_media_file(), profile) == :direct_play
    end
  end

  describe "clients that attach no conditions" do
    test "keep the unconstrained behavior the flat allowlist always meant" do
      profile = profile_claiming_hevc([])

      assert Compatibility.check_compatibility(lanterns_media_file(), profile) == :direct_play
    end
  end

  describe "conditions and absent stream metadata" do
    test "a file with no stream detail fails a required condition closed" do
      file = lanterns_media_file()
      bare = %{file | metadata: %{file.metadata | streams: []}}

      profile = profile_claiming_hevc([bit_depth_at_most(8)])

      assert Compatibility.check_compatibility(bare, profile) == :needs_transcoding
    end
  end

  describe "audio conditions" do
    test "a channel cap pushes 5.1 AC3 away from direct play" do
      {:ok, stereo_only} =
        Mydia.Streaming.CodecProfile.from_map(%{
          "type" => "audio",
          "codec" => "ac3",
          "conditions" => [
            %{"property" => "AudioChannels", "condition" => "LessThanEqual", "value" => "2"}
          ]
        })

      profile = profile_claiming_hevc([stereo_only])

      assert Compatibility.check_compatibility(lanterns_media_file(), profile) ==
               :needs_transcoding
    end
  end

  describe "wire format" do
    test "a header carrying codec profiles round-trips into a working decision" do
      encoded =
        %{
          "containers" => ["mkv"],
          "videoCodecs" => ["hevc"],
          "audioCodecs" => ["ac3"],
          "hdrFormats" => [],
          "codecProfiles" => [
            %{
              "type" => "video",
              "codec" => "hevc",
              "conditions" => [
                %{
                  "property" => "VideoBitDepth",
                  "condition" => "LessThanEqual",
                  "value" => "8"
                }
              ]
            }
          ]
        }
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert %DeviceProfile{} = profile = DeviceProfile.decode_header(encoded)
      assert [_one] = profile.codec_profiles

      assert Compatibility.check_compatibility(lanterns_media_file(), profile) ==
               :needs_transcoding
    end

    test "a payload with a malformed condition is treated as absent, not as trusted" do
      encoded =
        %{
          "containers" => ["mkv"],
          "videoCodecs" => ["hevc"],
          "audioCodecs" => ["ac3"],
          "codecProfiles" => [
            %{
              "type" => "video",
              "codec" => "hevc",
              "conditions" => [
                %{"property" => "NotAProperty", "condition" => "Equals", "value" => "8"}
              ]
            }
          ]
        }
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert DeviceProfile.decode_header(encoded) == nil
    end
  end
end
