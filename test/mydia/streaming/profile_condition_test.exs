defmodule Mydia.Streaming.ProfileConditionTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.{CodecProfile, ProfileCondition}

  # The stream that broke playback on a Fire HD 10: HEVC Main 10, 10-bit. The
  # server direct-played it because the client claimed "hevc", and mpv's
  # MediaCodec decoder would not open it.
  defp main10_stream do
    %StreamInfo{
      type: :video,
      codec: "hevc",
      profile: "Main 10",
      level: 120,
      bit_depth: 10,
      width: 1920,
      height: 960,
      frame_rate: 23.976,
      pixel_format: "yuv420p10le"
    }
  end

  defp main8_stream do
    %StreamInfo{
      type: :video,
      codec: "hevc",
      profile: "Main",
      level: 120,
      bit_depth: 8,
      width: 1920,
      height: 1080,
      frame_rate: 23.976,
      pixel_format: "yuv420p"
    }
  end

  defp condition(property, condition, value, opts \\ []) do
    %ProfileCondition{
      property: property,
      condition: condition,
      value: value,
      required: Keyword.get(opts, :required, true)
    }
  end

  describe "parse_property/1 and parse_condition/1" do
    test "resolve known names case-insensitively" do
      assert ProfileCondition.parse_property("VideoBitDepth") == :video_bit_depth
      assert ProfileCondition.parse_property("  videoprofile ") == :video_profile
      assert ProfileCondition.parse_condition("LessThanEqual") == :less_than_equal
    end

    test "return :invalid rather than minting an atom for unknown input" do
      assert ProfileCondition.parse_property("TotallyMadeUpProperty") == :invalid
      assert ProfileCondition.parse_condition("Sideways") == :invalid
      assert ProfileCondition.parse_property(nil) == :invalid
      assert ProfileCondition.parse_condition(%{}) == :invalid
    end
  end

  describe "numeric conditions" do
    test "less_than_equal rejects the 10-bit stream and accepts the 8-bit one" do
      cond_ = condition(:video_bit_depth, :less_than_equal, "8")

      refute ProfileCondition.satisfied?(cond_, main10_stream())
      assert ProfileCondition.satisfied?(cond_, main8_stream())
    end

    test "greater_than_equal, equals and not_equals compare numerically" do
      assert ProfileCondition.satisfied?(
               condition(:width, :less_than_equal, "1920"),
               main10_stream()
             )

      refute ProfileCondition.satisfied?(
               condition(:width, :greater_than_equal, "3840"),
               main10_stream()
             )

      assert ProfileCondition.satisfied?(condition(:video_level, :equals, "120"), main10_stream())

      refute ProfileCondition.satisfied?(
               condition(:video_level, :not_equals, "120"),
               main10_stream()
             )
    end

    test "equals_any matches one of several numbers" do
      assert ProfileCondition.satisfied?(
               condition(:video_bit_depth, :equals_any, "8|10"),
               main10_stream()
             )

      refute ProfileCondition.satisfied?(
               condition(:video_bit_depth, :equals_any, "8|12"),
               main10_stream()
             )
    end

    test "a float property compares without truncation surprises" do
      assert ProfileCondition.satisfied?(
               condition(:video_framerate, :less_than_equal, "30"),
               main10_stream()
             )

      refute ProfileCondition.satisfied?(
               condition(:video_framerate, :less_than_equal, "23"),
               main10_stream()
             )
    end
  end

  describe "string conditions" do
    test "video_profile matches case- and space-insensitively" do
      assert ProfileCondition.satisfied?(
               condition(:video_profile, :equals, "main 10"),
               main10_stream()
             )

      assert ProfileCondition.satisfied?(
               condition(:video_profile, :equals_any, "Main|Main 10"),
               main10_stream()
             )

      refute ProfileCondition.satisfied?(
               condition(:video_profile, :equals_any, "Main|Main Still Picture"),
               main10_stream()
             )
    end

    test "an ordering comparison on a profile name is treated as malformed" do
      # Required, so the malformed constraint fails closed.
      refute ProfileCondition.satisfied?(
               condition(:video_profile, :less_than_equal, "Main"),
               main10_stream()
             )
    end
  end

  describe "absent metadata" do
    test "a required condition fails closed when the property is missing" do
      bare = %StreamInfo{type: :video, codec: "hevc"}

      refute ProfileCondition.satisfied?(condition(:video_bit_depth, :less_than_equal, "8"), bare)
      refute ProfileCondition.satisfied?(condition(:video_bit_depth, :less_than_equal, "8"), nil)
    end

    test "an optional condition passes when the property is missing" do
      bare = %StreamInfo{type: :video, codec: "hevc"}

      assert ProfileCondition.satisfied?(
               condition(:video_bit_depth, :less_than_equal, "8", required: false),
               bare
             )
    end

    test "a non-numeric value on a numeric property does not widen direct play" do
      refute ProfileCondition.satisfied?(
               condition(:video_bit_depth, :less_than_equal, "eight"),
               main10_stream()
             )
    end
  end

  describe "from_map/1" do
    test "parses a well-formed condition and defaults isRequired to true" do
      assert {:ok, parsed} =
               ProfileCondition.from_map(%{
                 "property" => "VideoBitDepth",
                 "condition" => "LessThanEqual",
                 "value" => "8"
               })

      assert parsed.property == :video_bit_depth
      assert parsed.condition == :less_than_equal
      assert parsed.required
    end

    test "honors an explicit isRequired false" do
      assert {:ok, parsed} =
               ProfileCondition.from_map(%{
                 "property" => "Width",
                 "condition" => "LessThanEqual",
                 "value" => "1920",
                 "isRequired" => false
               })

      refute parsed.required
    end

    test "rejects unknown names and empty values instead of dropping them" do
      assert ProfileCondition.from_map(%{
               "property" => "Nope",
               "condition" => "Equals",
               "value" => "1"
             }) == :error

      assert ProfileCondition.from_map(%{
               "property" => "Width",
               "condition" => "Nope",
               "value" => "1"
             }) == :error

      assert ProfileCondition.from_map(%{
               "property" => "Width",
               "condition" => "Equals",
               "value" => ""
             }) == :error
    end
  end

  describe "CodecProfile" do
    test "the Fire HD 10 profile rejects Main 10 and accepts Main" do
      {:ok, profile} =
        CodecProfile.from_map(%{
          "type" => "video",
          "codec" => "hevc",
          "conditions" => [
            %{"property" => "VideoBitDepth", "condition" => "LessThanEqual", "value" => "8"}
          ]
        })

      assert CodecProfile.applies?(profile, :video, "hevc")
      assert CodecProfile.applies?(profile, :video, "HEVC")
      refute CodecProfile.applies?(profile, :audio, "hevc")
      refute CodecProfile.applies?(profile, :video, "h264")

      refute CodecProfile.satisfied?(profile, main10_stream())
      assert CodecProfile.satisfied?(profile, main8_stream())
    end

    test "an empty condition list claims the codec unconditionally" do
      {:ok, profile} = CodecProfile.from_map(%{"type" => "video", "codec" => "hevc"})

      assert CodecProfile.satisfied?(profile, main10_stream())
    end

    test "one bad condition rejects the whole codec profile" do
      assert CodecProfile.from_map(%{
               "type" => "video",
               "codec" => "hevc",
               "conditions" => [
                 %{"property" => "VideoBitDepth", "condition" => "LessThanEqual", "value" => "8"},
                 %{"property" => "Bogus", "condition" => "Equals", "value" => "1"}
               ]
             }) == :error
    end

    test "rejects an empty codec that would match every stream" do
      assert CodecProfile.from_map(%{"type" => "video", "codec" => ""}) == :error
      assert CodecProfile.from_map(%{"type" => "video", "codec" => "   "}) == :error
    end
  end
end
