defmodule Mydia.Subtitles.ExtractorStreamsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.SettingsFixtures
  alias Mydia.Subtitles.Extractor

  defp with_streams(streams) do
    MediaFixtures.media_file_fixture(%{
      metadata: %FileMetadata{streams: streams}
    })
    |> Repo.preload(:library_path)
  end

  test "reads embedded subtitle tracks from stored streams without running ffprobe" do
    media_file =
      with_streams([
        %StreamInfo{index: 0, type: :video, codec: "h264"},
        %StreamInfo{index: 1, type: :audio, codec: "eac3"},
        %StreamInfo{
          index: 2,
          type: :subtitle,
          codec: "subrip",
          language: "eng",
          title: "English"
        },
        %StreamInfo{index: 3, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "spa"}
      ])

    tracks = Extractor.list_subtitle_tracks(media_file)

    assert [srt, pgs] = Enum.filter(tracks, & &1.embedded)

    assert srt.track_id == 2
    assert srt.language == "eng"
    assert srt.title == "English"
    assert srt.format == "srt"
    assert srt.deliverable

    assert pgs.track_id == 3
    assert pgs.format == "pgs"
    refute pgs.deliverable
  end

  # Extractor already hard-depends on ffmpeg/ffprobe being on PATH (it shells
  # out to both elsewhere in this module), so the fallback path is exercised
  # for real here rather than with a nonexistent file: a nonexistent file
  # makes the ffprobe branch return `[]` regardless of whether it actually
  # ran, which would let a broken fallback pass silently. This muxes a real
  # subtitle stream into a throwaway one-second video with ffmpeg, points a
  # media file fixture's library path at it, and asserts on the actual values
  # get_embedded_subtitles/1 and build_embedded_track/1 produce from real
  # ffprobe JSON.
  test "reads embedded subtitle tracks via ffprobe when the file was never analyzed" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extractor_ffprobe_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    srt_path = Path.join(tmp_dir, "sub.srt")
    File.write!(srt_path, "1\n00:00:00,000 --> 00:00:01,000\nHello world\n\n")

    relative_path = "video.mkv"
    video_path = Path.join(tmp_dir, relative_path)

    {_output, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-f",
          "lavfi",
          "-i",
          "color=c=black:s=64x64:d=1:r=1",
          "-i",
          srt_path,
          "-c:v",
          "libx264",
          "-c:s",
          "srt",
          "-map",
          "0:v",
          "-map",
          "1:s",
          "-metadata:s:s:0",
          "language=eng",
          "-y",
          video_path
        ],
        stderr_to_stdout: true
      )

    library_path = SettingsFixtures.library_path_fixture(%{path: tmp_dir})

    media_file =
      MediaFixtures.media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: relative_path,
        metadata: nil
      })
      |> Repo.preload(:library_path)

    tracks = Extractor.list_subtitle_tracks(media_file)

    assert [track] = Enum.filter(tracks, & &1.embedded)
    assert track.track_id == 1
    assert track.language == "eng"
    assert track.format == "srt"
    assert track.deliverable
  end

  test "external sidecars are always deliverable" do
    media_file = with_streams([])

    {:ok, _subtitle} =
      %Mydia.Subtitles.Subtitle{}
      |> Mydia.Subtitles.Subtitle.changeset(%{
        media_file_id: media_file.id,
        language: "en",
        format: "srt",
        subtitle_hash: "hash-#{System.unique_integer([:positive])}",
        file_path: "/tmp/nope.srt",
        provider: "relay"
      })
      |> Repo.insert()

    assert [track] = Extractor.list_subtitle_tracks(media_file)
    refute track.embedded
    assert track.deliverable
  end
end
