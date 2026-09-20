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

  test "never offers a DVB or XSUB bitmap as deliverable text" do
    media_file =
      with_streams([
        %StreamInfo{index: 4, type: :subtitle, codec: "dvb_subtitle", language: "ger"},
        %StreamInfo{index: 5, type: :subtitle, codec: "xsub", language: "ita"}
      ])

    tracks = Extractor.list_subtitle_tracks(media_file)

    assert [dvb, xsub] = Enum.filter(tracks, & &1.embedded)
    assert dvb.format == "dvb_subtitle"
    refute dvb.deliverable
    assert xsub.format == "xsub"
    refute xsub.deliverable
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

  describe "disposition flags on embedded tracks" do
    test "carries forced and hearing_impaired from the stored stream capture" do
      media_file = %Mydia.Library.MediaFile{
        id: Ecto.UUID.generate(),
        metadata: %Mydia.Library.Structs.FileMetadata{
          streams: [
            %Mydia.Library.Structs.StreamInfo{
              index: 2,
              type: :subtitle,
              codec: "subrip",
              language: "eng",
              title: "English (Signs & Songs)",
              is_forced: true,
              is_hearing_impaired: false
            },
            %Mydia.Library.Structs.StreamInfo{
              index: 3,
              type: :subtitle,
              codec: "subrip",
              language: "eng",
              title: "English",
              is_forced: false,
              is_hearing_impaired: true
            }
          ]
        }
      }

      [signs, dialogue] = Mydia.Subtitles.Extractor.list_subtitle_tracks(media_file)

      assert signs.forced == true
      assert signs.hearing_impaired == false
      assert dialogue.forced == false
      assert dialogue.hearing_impaired == true
    end

    test "defaults both flags to false when the capture leaves them nil" do
      media_file = %Mydia.Library.MediaFile{
        id: Ecto.UUID.generate(),
        metadata: %Mydia.Library.Structs.FileMetadata{
          streams: [
            %Mydia.Library.Structs.StreamInfo{
              index: 0,
              type: :subtitle,
              codec: "subrip",
              language: "jpn",
              title: nil,
              is_forced: nil,
              is_hearing_impaired: nil
            }
          ]
        }
      }

      [track] = Mydia.Subtitles.Extractor.list_subtitle_tracks(media_file)

      assert track.forced == false
      assert track.hearing_impaired == false
    end
  end
end
