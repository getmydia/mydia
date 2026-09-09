defmodule Mydia.Streaming.StreamPlanTest do
  @moduledoc """
  The plan is the single record of what FFmpeg will do to a stream. It exists
  because two modules used to decide that independently: the transcoder chose
  `copy` or `libx264` from the bitrate cap, while the GraphQL resolver chose
  `:copy` or `:transcode` from the client's strategy, and the dashboard read
  the resolver's answer. A 480p rung on an HLS_COPY strategy therefore showed
  a green "Direct Play" badge while FFmpeg re-encoded HEVC to H.264.

  These tests pin the decision itself, with no FFmpeg process and no database.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.StreamPlan

  defp media_file(attrs) do
    base = %MediaFile{
      relative_path: "film.mkv",
      library_path: %LibraryPath{path: "/tmp"},
      codec: "h264",
      audio_codec: "aac",
      metadata: %FileMetadata{width: 1920, height: 1080}
    }

    struct!(base, attrs)
  end

  defp software_opts(extra) do
    Keyword.merge([capabilities: Capabilities.software("test")], extra)
  end

  describe "for_hls/2 video action" do
    test "a compatible codec with no cap is copied" do
      plan = StreamPlan.for_hls(media_file(codec: "h264"), software_opts([]))

      assert plan.video.action == :copy
      assert plan.video.from_codec == "h264"
      assert plan.video.to_codec == "h264"
      assert plan.container == :hls_ts
    end

    test "an incompatible codec is encoded to h264" do
      plan = StreamPlan.for_hls(media_file(codec: "hevc"), software_opts([]))

      assert plan.video.action == :encode
      assert plan.video.from_codec == "hevc"
      assert plan.video.to_codec == "h264"
    end

    test "a bitrate cap forces an encode even on a compatible codec" do
      # This is the reported bug's exact shape: strategy HLS_COPY on an H.264
      # source, plus the 480p rung's 1500kbps cap. FFmpeg re-encodes; the
      # plan must say so.
      plan = StreamPlan.for_hls(media_file(codec: "h264"), software_opts(max_bitrate: 1500))

      assert plan.video.action == :encode
      assert plan.max_bitrate_kbps == 1500
    end

    test "a genuine downscale forces an encode with no bitrate cap" do
      # reencodes_video?/2 ignored max_height entirely, so a height-only
      # request stream-copied at full resolution and silently dropped the
      # downscale the caller asked for.
      plan = StreamPlan.for_hls(media_file(codec: "h264"), software_opts(max_height: 480))

      assert plan.video.action == :encode
      assert plan.video.to_height == 480
    end

    test "a height at or above the source is not a downscale and stays a copy" do
      # The trap this guards: effective_max_height/1 folds in the operator's
      # MAX_TRANSCODE_HEIGHT ceiling, so "a height is set" is true for every
      # session on a configured server. Only an actual reduction may force an
      # encode, or a 720p file under a 1080p ceiling would start transcoding.
      plan = StreamPlan.for_hls(media_file(codec: "h264"), software_opts(max_height: 1080))

      assert plan.video.action == :copy
    end

    test "an unknown source height never forces an encode" do
      # FFmpeg's own min(h, ih) clamp in height_expression/1 already makes the
      # scale filter a no-op when the source is smaller, so guessing here
      # would transcode files that need nothing.
      file = media_file(codec: "h264", metadata: %FileMetadata{width: nil, height: nil})

      plan = StreamPlan.for_hls(file, software_opts(max_height: 480))

      assert plan.video.action == :copy
    end

    test "an explicit video_codec opt wins over the derived decision" do
      plan =
        StreamPlan.for_hls(media_file(codec: "hevc"), software_opts(video_codec: "copy"))

      assert plan.video.action == :copy
    end
  end

  describe "for_hls/2 output geometry" do
    test "reports source and output dimensions for a downscale" do
      file = media_file(codec: "hevc", metadata: %FileMetadata{width: 1920, height: 1080})

      plan = StreamPlan.for_hls(file, software_opts(max_height: 480))

      assert plan.video.from_width == 1920
      assert plan.video.from_height == 1080
      assert plan.video.to_width == 854
      assert plan.video.to_height == 480
    end

    test "output height is rounded down to even, matching the scale expression" do
      # AccelArgs.height_expression/1 emits 2*trunc(min(h,ih)/2), so an odd
      # requested height produces an even output. Reporting the requested
      # number would put a resolution on the dashboard FFmpeg never wrote.
      file = media_file(codec: "hevc", metadata: %FileMetadata{width: 1920, height: 1080})

      plan = StreamPlan.for_hls(file, software_opts(max_height: 481))

      assert plan.video.to_height == 480
    end

    test "a copied stream reports the source dimensions as the output" do
      plan = StreamPlan.for_hls(media_file(codec: "h264"), software_opts([]))

      assert plan.video.to_height == 1080
      assert plan.video.to_width == 1920
    end

    test "reads dimensions from metadata.streams in preference to the flat fields" do
      # lib/mydia/streaming/README.md: metadata.streams is the populated
      # source. The flat fields are a fallback for older rows.
      file =
        media_file(
          codec: "h264",
          metadata: %FileMetadata{
            width: 1920,
            height: 1080,
            streams: [%StreamInfo{index: 0, type: :video, width: 3840, height: 2160}]
          }
        )

      assert StreamPlan.source_dimensions(file) == {3840, 2160}
    end

    test "falls back to the flat metadata fields when streams are absent" do
      file = media_file(codec: "h264", metadata: %FileMetadata{width: 1280, height: 720})

      assert StreamPlan.source_dimensions(file) == {1280, 720}
    end

    test "reports nil dimensions when neither source has them" do
      file = media_file(codec: "h264", metadata: %FileMetadata{})

      assert StreamPlan.source_dimensions(file) == {nil, nil}
    end
  end

  describe "for_hls/2 audio action" do
    test "aac audio is copied" do
      plan = StreamPlan.for_hls(media_file(audio_codec: "aac"), software_opts([]))

      assert plan.audio.action == :copy
      assert plan.audio.to_codec == "aac"
    end

    test "eac3 audio is encoded to aac" do
      plan = StreamPlan.for_hls(media_file(audio_codec: "eac3"), software_opts([]))

      assert plan.audio.action == :encode
      assert plan.audio.from_codec == "eac3"
      assert plan.audio.to_codec == "aac"
    end

    test "the decision follows the mapped stream, not the first one" do
      # media_file.audio_codec describes the FIRST audio stream. When language
      # selection maps a different one, deciding from the first would report
      # "copy" while FFmpeg encodes, or the reverse.
      file =
        media_file(
          audio_codec: "aac",
          metadata: %FileMetadata{
            width: 1920,
            height: 1080,
            streams: [
              %StreamInfo{index: 1, type: :audio, codec: "aac", language: "jpn", channels: 2},
              %StreamInfo{index: 2, type: :audio, codec: "eac3", language: "eng", channels: 6}
            ]
          }
        )

      plan = StreamPlan.for_hls(file, software_opts(audio_language: ["eng"]))

      assert plan.audio.stream_index == 2
      assert plan.audio.from_codec == "eac3"
      assert plan.audio.action == :encode
      assert plan.audio.language == "eng"
      assert plan.audio.channels == 6
    end

    test "carries the raw selected stream so builders need not re-select" do
      # The argument builders pass this straight to
      # AudioTrackSelector.ffmpeg_map_args/1. Re-running select_for_playback/2
      # there would repeat the plan's most expensive step and would let the
      # -map arguments disagree with the audio decision beside them.
      file =
        media_file(
          metadata: %FileMetadata{
            width: 1920,
            height: 1080,
            streams: [
              %StreamInfo{index: 1, type: :audio, codec: "eac3", language: "eng", channels: 6}
            ]
          }
        )

      plan = StreamPlan.for_hls(file, software_opts([]))

      assert %StreamInfo{index: 1} = plan.selected_audio
    end
  end

  describe "encodes_video?/3" do
    test "a nil media file always encodes" do
      assert StreamPlan.encodes_video?(nil, nil, nil)
    end

    test "agrees with the plan it backs" do
      file = media_file(codec: "h264")

      assert StreamPlan.encodes_video?(file, 1500, nil)
      refute StreamPlan.encodes_video?(file, nil, nil)
    end
  end

  describe "for_remux/2" do
    test "video is never encoded" do
      # REMUX means repackaging. The strategy is only offered because the
      # client can already decode the video, so touching it would be pure
      # waste and would contradict the candidate the client accepted.
      plan = StreamPlan.for_remux(media_file(codec: "hevc"), [])

      assert plan.video.action == :copy
      assert plan.video.from_codec == "hevc"
      assert plan.video.to_codec == "hevc"
      assert plan.container == :fmp4
      assert plan.video.tier == nil
      assert plan.accel == nil
    end

    test "a compatible mapped audio track is copied" do
      # The mapped stream, not media_file.audio_codec, decides this: without an
      # analysed audio stream select_for_playback/2 returns nil, and a nil
      # selection always copies regardless of codec (see the next test), which
      # would make this pass for the wrong reason.
      file =
        media_file(
          audio_codec: "aac",
          metadata: %FileMetadata{
            width: 1920,
            height: 1080,
            streams: [%StreamInfo{index: 1, type: :audio, codec: "aac"}]
          }
        )

      plan = StreamPlan.for_remux(file, [])

      assert plan.audio.action == :copy
    end

    test "an incompatible mapped audio track is encoded to aac" do
      # A blanket -c copy would put e.g. E-AC-3 into the fMP4 while the
      # advertised MIME still said mp4a.40.2, so the browser plays silence.
      file =
        media_file(
          audio_codec: "eac3",
          metadata: %FileMetadata{
            width: 1920,
            height: 1080,
            streams: [%StreamInfo{index: 1, type: :audio, codec: "eac3"}]
          }
        )

      plan = StreamPlan.for_remux(file, [])

      assert plan.audio.action == :encode
      assert plan.audio.to_codec == "aac"
    end

    test "geometry is the source's, unchanged" do
      plan = StreamPlan.for_remux(media_file(codec: "h264"), [])

      assert plan.video.from_height == 1080
      assert plan.video.to_height == 1080
      assert plan.video.from_width == 1920
      assert plan.video.to_width == 1920
    end
  end
end
