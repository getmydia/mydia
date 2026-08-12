defmodule Mydia.Subtitles.ExtractorStreamsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Repo
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

  test "falls back to ffprobe when the file was never analyzed" do
    media_file = MediaFixtures.media_file_fixture(%{metadata: nil}) |> Repo.preload(:library_path)

    # The fixture path does not exist on disk, so the ffprobe branch yields nothing
    # rather than raising. What matters is that it does not crash.
    assert is_list(Extractor.list_subtitle_tracks(media_file))
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
