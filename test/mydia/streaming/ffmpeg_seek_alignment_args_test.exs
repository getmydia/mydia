defmodule Mydia.Streaming.FfmpegSeekAlignmentArgsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel.Capabilities

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args(
      "/tmp/in.mkv",
      "/tmp/out",
      [capabilities: Capabilities.software("test")] ++ opts
    )
  end

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  defp value_after(args, flag) do
    case index_of(args, flag) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  describe "copied audio after a seek" do
    test "drops copied audio from before the seek point when video is re-encoded" do
      result = args(start_position: 27, video_codec: "libx264", audio_codec: "copy")

      assert value_after(result, "-copypriorss:a") == "0"
    end

    test "sits right after the audio codec, among the output options" do
      result = args(start_position: 27, video_codec: "libx264", audio_codec: "copy")

      assert index_of(result, "-copypriorss:a") == index_of(result, "-c:a") + 2
      assert index_of(result, "-copypriorss:a") > index_of(result, "-i")
    end

    test "applies to a :full relocation, whose timestamps stay absolute" do
      result =
        args(
          start_position: 28,
          start_number: 7,
          grid_aligned: true,
          absolute_timestamps: true,
          video_codec: "libx264",
          audio_codec: "copy"
        )

      assert value_after(result, "-copypriorss:a") == "0"
      assert "-copyts" in result
    end

    test "follows the plan for a HEVC file with AAC audio" do
      # The case production actually hits: HEVC is re-encoded, and AAC is
      # copied under the default :copy_when_compatible policy.
      file = %MediaFile{
        path: "/tmp/in.mkv",
        codec: "hevc",
        audio_codec: "aac",
        metadata: %FileMetadata{streams: []}
      }

      assert value_after(args(media_file: file, start_position: 27), "-copypriorss:a") == "0"
    end

    test "leaves a copied video's audio alone" do
      # Copied video also starts on the keyframe, so its audio has to as well.
      refute "-copypriorss:a" in args(
               start_position: 27,
               video_codec: "copy",
               audio_codec: "copy"
             )
    end

    test "does nothing without a seek" do
      refute "-copypriorss:a" in args(
               start_position: 0,
               video_codec: "libx264",
               audio_codec: "copy"
             )

      refute "-copypriorss:a" in args(video_codec: "libx264", audio_codec: "copy")
    end

    test "does nothing when audio is re-encoded" do
      refute "-copypriorss:a" in args(start_position: 27, video_codec: "libx264")
    end
  end

  describe "a pinned keyframe" do
    test "seeks just past the keyframe" do
      result =
        args(seek_keyframe: 20.0, start_position: 27, video_codec: "copy", audio_codec: "copy")

      assert value_after(result, "-ss") == "20.200"
    end

    test "wins over the requested position" do
      result = args(seek_keyframe: 1233.458, start_position: 1234, video_codec: "copy")

      assert value_after(result, "-ss") == "1233.658"
    end

    test "stays an input seek" do
      result = args(seek_keyframe: 20.0, start_position: 27, video_codec: "copy")

      assert index_of(result, "-ss") < index_of(result, "-i")
    end

    test "a keyframe at zero is the start of the file, so no seek at all" do
      refute "-ss" in args(seek_keyframe: 0.0, start_position: 5, video_codec: "copy")
    end

    test "never trims audio, because only copied video is ever pinned" do
      refute "-copypriorss:a" in args(
               seek_keyframe: 20.0,
               start_position: 27,
               video_codec: "copy",
               audio_codec: "copy"
             )
    end

    test "without one, the whole-second position is used as before" do
      assert value_after(args(start_position: 27, video_codec: "copy"), "-ss") == "27"
    end
  end
end
