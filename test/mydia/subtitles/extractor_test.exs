defmodule Mydia.Subtitles.ExtractorTest do
  use Mydia.DataCase, async: true

  import Ecto.Query

  alias Mydia.Subtitles.Extractor
  alias Mydia.Subtitles.Subtitle

  import Mydia.MediaFixtures

  defp insert_subtitle(media_file, attrs) do
    base = %{
      media_file_id: media_file.id,
      language: "en",
      provider: "sidecar",
      subtitle_hash: "hash-#{System.unique_integer([:positive])}",
      file_path: "/tmp/whatever-#{System.unique_integer([:positive])}.srt",
      format: "srt"
    }

    {:ok, subtitle} =
      %Mydia.Subtitles.Subtitle{}
      |> Mydia.Subtitles.Subtitle.changeset(Map.merge(base, attrs))
      |> Mydia.Repo.insert()

    subtitle
  end

  describe "list_external_subtitle_tracks/1" do
    setup do
      %{media_file: media_file_fixture()}
    end

    test "carries the subtitle's origin", %{media_file: media_file} do
      insert_subtitle(media_file, %{origin: "upload"})

      assert [%{origin: :upload}] = Extractor.list_external_subtitle_tracks(media_file.id)
    end

    test "falls back to :provider for an origin the changeset would never allow through", %{
      media_file: media_file
    } do
      subtitle = insert_subtitle(media_file, %{origin: "sidecar"})

      # Subtitle.changeset/2 runs validate_inclusion(:origin, @origins), so no
      # ordinary insert or update can produce an unrecognized value here. Bypass
      # the changeset with a raw update to actually reach origin_atom/1's
      # catch-all clause, not just its literal matches. Do not "fix" this back
      # into insert_subtitle/2; that would stop exercising the fallback at all.
      Mydia.Repo.update_all(
        from(s in Subtitle, where: s.id == ^subtitle.id),
        set: [origin: "bogus"]
      )

      assert [%{origin: :provider}] = Extractor.list_external_subtitle_tracks(media_file.id)
    end

    test "titles a plain track by language name", %{media_file: media_file} do
      insert_subtitle(media_file, %{origin: "sidecar"})

      assert [%{title: "English"}] = Extractor.list_external_subtitle_tracks(media_file.id)
    end

    test "titles a forced track", %{media_file: media_file} do
      insert_subtitle(media_file, %{origin: "sidecar", forced: true})

      assert [%{title: "English (Forced)"}] =
               Extractor.list_external_subtitle_tracks(media_file.id)
    end

    test "titles a hearing-impaired track", %{media_file: media_file} do
      insert_subtitle(media_file, %{origin: "sidecar", hearing_impaired: true})

      assert [%{title: "English (SDH)"}] = Extractor.list_external_subtitle_tracks(media_file.id)
    end

    test "forced wins when both flags are set", %{media_file: media_file} do
      insert_subtitle(media_file, %{origin: "sidecar", forced: true, hearing_impaired: true})

      assert [%{title: "English (Forced)"}] =
               Extractor.list_external_subtitle_tracks(media_file.id)
    end
  end

  describe "list_subtitle_tracks/2 embedded origin" do
    alias Mydia.Library.Structs.FileMetadata
    alias Mydia.Library.Structs.StreamInfo

    test "embedded tracks from the stream capture carry origin :embedded" do
      media_file =
        media_file_fixture(%{
          metadata: %FileMetadata{
            streams: [
              %StreamInfo{
                index: 0,
                type: :subtitle,
                codec: "subrip",
                language: "eng",
                title: "English"
              }
            ]
          }
        })
        |> Mydia.Repo.preload(:library_path)

      assert [%{origin: :embedded}] = Extractor.list_subtitle_tracks(media_file)
    end
  end
end
