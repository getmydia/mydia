defmodule Mydia.Streaming.FfmpegAudioMapTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.FfmpegHlsTranscoder

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  # Every "-map" argument's value, in order, so a test can assert on the
  # mapping without depending on where it sits among the codec flags.
  defp maps(args) do
    args
    |> Enum.zip(Enum.drop(args, 1))
    |> Enum.filter(fn {flag, _value} -> flag == "-map" end)
    |> Enum.map(fn {_flag, value} -> value end)
  end

  defp value_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp audio(index, language, opts \\ []) do
    %StreamInfo{
      index: index,
      type: :audio,
      codec: Keyword.get(opts, :codec, "aac"),
      language: language,
      channels: Keyword.get(opts, :channels, 2),
      is_default: Keyword.get(opts, :is_default, false),
      is_commentary: false
    }
  end

  defp media_file(streams, attrs \\ []) do
    %MediaFile{
      path: "/tmp/in.mkv",
      codec: "h264",
      audio_codec: Keyword.get(attrs, :audio_codec, "aac"),
      media_item: Keyword.get(attrs, :media_item),
      episode: Keyword.get(attrs, :episode),
      metadata: %FileMetadata{streams: streams}
    }
  end

  defp video_stream, do: %StreamInfo{index: 0, type: :video, codec: "h264", height: 1080}

  describe "audio stream mapping" do
    test "maps the English track over a Russian one the container flags default" do
      # The reported bug. Without -map, ffmpeg's implicit selection takes the
      # stream with the most channels, which is the 5.1 Russian dub here.
      file =
        media_file([
          video_stream(),
          audio(1, "rus", is_default: true, channels: 6),
          audio(2, "eng", channels: 2)
        ])

      assert maps(args(media_file: file, audio_language: ["en"])) == ["0:V:0?", "0:2?"]
    end

    test "maps the video stream as 0:V:0 so embedded cover art cannot win" do
      # Capital V excludes attached pictures. A file with a cover-art JPEG
      # muxed as a video stream would otherwise be able to become the video
      # track under 0:v:0.
      file = media_file([video_stream(), audio(1, "eng")])

      assert value_after(args(media_file: file, audio_language: ["en"]), "-map") == "0:V:0?"
    end

    test "maps by absolute container index, not audio-relative position" do
      # `-map 0:2` and `-map 0:a:2` mean different streams. StreamInfo stores
      # ffprobe's absolute index, so the argument has to be the absolute form.
      file =
        media_file([
          video_stream(),
          audio(1, "rus", is_default: true),
          audio(2, "fre"),
          audio(3, "eng")
        ])

      assert maps(args(media_file: file, audio_language: ["en"])) == ["0:V:0?", "0:3?"]
    end

    test "honours the configured preference order through the device override" do
      file = media_file([video_stream(), audio(1, "eng"), audio(2, "jpn")])

      assert maps(args(media_file: file, audio_language: ["ja"])) == ["0:V:0?", "0:2?"]
      assert maps(args(media_file: file, audio_language: ["en"])) == ["0:V:0?", "0:1?"]
    end

    test "the per-show preference outranks the per-device one" do
      file = media_file([video_stream(), audio(1, "eng"), audio(2, "jpn")])

      assert maps(args(media_file: file, audio_language: ["en"], show_audio_language: ["ja"])) ==
               ["0:V:0?", "0:2?"]
    end

    test "both maps are optional so a stale index degrades instead of aborting" do
      # The index comes from metadata.streams, written at analysis time. A
      # file replaced on disk without re-analysis can leave it pointing past
      # the real stream list, and a mandatory map makes ffmpeg exit with
      # "Stream map '0:N' matches no streams" rather than play. That is a
      # regression against the implicit selection this replaced, so both maps
      # carry ffmpeg's trailing `?`.
      file = media_file([video_stream(), audio(1, "eng")])

      assert Enum.all?(
               maps(args(media_file: file, audio_language: ["en"])),
               &String.ends_with?(&1, "?")
             )
    end
  end

  describe "backward compatibility" do
    test "emits no -map for a file with no analysed streams" do
      # Anything scanned before per-stream analysis existed. Emitting no -map
      # leaves ffmpeg's implicit selection in place, which is exactly how those
      # files played before this change: unchanged, rather than broken.
      file = media_file([])

      assert maps(args(media_file: file, audio_language: ["en"])) == []
    end

    test "emits no -map when there is no media_file at all" do
      assert maps(args(video_codec: "libx264")) == []
    end

    test "emits no -map for a file whose streams are video only" do
      file = media_file([video_stream()])

      assert maps(args(media_file: file, audio_language: ["en"])) == []
    end
  end

  describe "remux path" do
    defp remux_args(opts) do
      Mydia.Streaming.FfmpegRemuxer.build_ffmpeg_args("/tmp/in.mkv", opts)
    end

    test "maps the preferred track instead of letting -c copy reduce to one" do
      # `-c copy` copies the codec, not every stream. Without -map, ffmpeg
      # still reduces to one stream per type, so remux dropped the
      # original-language track exactly as the transcode path did.
      file =
        media_file([
          video_stream(),
          audio(1, "rus", is_default: true, channels: 6),
          audio(2, "eng", channels: 2)
        ])

      assert maps(remux_args(media_file: file, audio_language: ["en"])) == ["0:V:0?", "0:2?"]
    end

    test "still stream-copies rather than re-encoding" do
      file = media_file([video_stream(), audio(1, "eng")])
      args = remux_args(media_file: file, audio_language: ["en"])

      assert value_after(args, "-c") == "copy"
    end

    test "encodes the audio when the mapped stream is one the client cannot decode" do
      # REMUX is offered on the strength of media_file.audio_codec, the FIRST
      # audio stream. Here that is AAC, so the candidate advertised
      # mp4a.40.2 — and then language selection maps the AC3 track. A blanket
      # `-c copy` would put AC3 in the fMP4 under an MIME promising AAC, which
      # the client's canPlayType check never approved.
      file =
        media_file(
          [
            video_stream(),
            audio(1, "eng", codec: "aac", channels: 2),
            audio(2, "jpn", codec: "ac3", channels: 6)
          ],
          audio_codec: "aac"
        )

      args = remux_args(media_file: file, audio_language: ["ja"])

      assert value_after(args, "-c:a") == "aac"
      # The video is why REMUX was chosen; it must not start re-encoding.
      assert value_after(args, "-c:v") == "copy"
      refute value_after(args, "-c") == "copy"
    end

    test "keeps the blanket copy when the mapped stream is already compatible" do
      file =
        media_file(
          [
            video_stream(),
            audio(1, "jpn", codec: "ac3", channels: 6),
            audio(2, "eng", codec: "aac", channels: 2)
          ],
          audio_codec: "ac3"
        )

      assert value_after(remux_args(media_file: file, audio_language: ["en"]), "-c") == "copy"
    end

    test "emits no -map for an unanalysed file, preserving the old behaviour" do
      assert maps(remux_args(duration: 100.0)) == []
    end

    test "keeps the seek and duration arguments intact" do
      file = media_file([video_stream(), audio(1, "eng")])
      args = remux_args(media_file: file, seek_seconds: 120, duration: 300.0)

      assert value_after(args, "-ss") == "120"
      assert value_after(args, "-t") == "180.0"
    end

    test "places -map after the input, where ffmpeg expects output selection" do
      # -map before -i would refer to an input that does not exist yet.
      file = media_file([video_stream(), audio(1, "eng")])
      args = remux_args(media_file: file, audio_language: ["en"])

      assert Enum.find_index(args, &(&1 == "-i")) <
               Enum.find_index(args, &(&1 == "-map"))
    end
  end

  describe "codec decision follows the mapped stream" do
    test "transcodes when the selected track is not browser-compatible" do
      # media_file.audio_codec describes the FIRST audio stream. Here that is
      # AAC, so the old code would emit "-c:a copy" while mapping the DTS
      # track, putting an undecodable stream in the segments.
      file =
        media_file(
          [
            video_stream(),
            audio(1, "eng", codec: "aac", channels: 2),
            audio(2, "rus", codec: "dts", channels: 6)
          ],
          audio_codec: "aac"
        )

      assert value_after(args(media_file: file, audio_language: ["ru"]), "-c:a") == "aac"
    end

    test "copies when the selected track is browser-compatible" do
      file =
        media_file(
          [
            video_stream(),
            audio(1, "rus", codec: "dts", channels: 6),
            audio(2, "eng", codec: "aac", channels: 2)
          ],
          audio_codec: "dts"
        )

      assert value_after(args(media_file: file, audio_language: ["en"]), "-c:a") == "copy"
    end
  end
end
