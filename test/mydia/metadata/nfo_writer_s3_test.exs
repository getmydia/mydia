defmodule Mydia.Metadata.NfoWriterS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Metadata.Structs.{EpisodeData, MediaMetadata, SeasonInfo}
  alias Mydia.S3Helpers
  alias Mydia.Storage

  setup do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    %{lp: lp, loc: loc}
  end

  test "a movie NFO lands next to its object and is deleted with it", %{lp: lp, loc: loc} do
    rel = "Invented Film (2031)/Invented Film (2031).mkv"
    S3Helpers.put_object!(loc, rel, "v")
    item = movie_with_file(lp, rel)

    assert :ok = NfoWriter.write_for_media_item(item, lp)

    nfo = Path.join(lp.path, "Invented Film (2031)/Invented Film (2031).nfo")
    assert {:ok, xml} = Storage.read_path(nfo)
    assert xml =~ "<movie>"

    assert :ok = NfoWriter.delete_nfo_for_file(Path.join(lp.path, rel))
    refute Storage.path_exists?(nfo)
  end

  test "a show writes tvshow.nfo and season.nfo under its prefix" do
    {lp, loc} = S3Helpers.library_path!("series")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)

    rel = "Invented Show/Season 01/Invented Show - S01E01.mkv"
    S3Helpers.put_object!(loc, rel, "v")
    item = show_with_episode_file(lp, rel)

    assert :ok = NfoWriter.write_for_media_item(item, lp)
    assert Storage.path_exists?(Path.join(lp.path, "Invented Show/tvshow.nfo"))
    assert Storage.path_exists?(Path.join(lp.path, "Invented Show/Season 01/season.nfo"))

    assert Storage.path_exists?(
             Path.join(lp.path, "Invented Show/Season 01/Invented Show - S01E01.nfo")
           )
  end

  defp build_file(lp, rel, attrs \\ %{}) do
    struct(
      MediaFile,
      Map.merge(
        %{
          id: "file-1",
          relative_path: rel,
          library_path_id: lp.id,
          library_path: lp,
          episode_id: nil,
          trashed_at: nil
        },
        attrs
      )
    )
  end

  defp movie_with_file(lp, rel) do
    %MediaItem{
      id: "item-1",
      title: "Invented Film",
      type: "movie",
      tmdb_id: 900_001,
      metadata: %MediaMetadata{
        provider_id: "900001",
        provider: :metadata_relay,
        media_type: :movie,
        title: "Invented Film",
        year: 2031
      },
      media_files: [build_file(lp, rel)],
      episodes: []
    }
  end

  defp show_with_episode_file(lp, rel) do
    episode = %Episode{
      id: "ep-1",
      season_number: 1,
      episode_number: 1,
      title: "Pilot",
      air_date: ~D[2031-01-15],
      metadata: %EpisodeData{
        season_number: 1,
        episode_number: 1,
        name: "Pilot",
        air_date: ~D[2031-01-15]
      }
    }

    %MediaItem{
      id: "item-2",
      title: "Invented Show",
      type: "tv_show",
      tmdb_id: 900_002,
      metadata: %MediaMetadata{
        provider_id: "900002",
        provider: :metadata_relay,
        media_type: :tv_show,
        title: "Invented Show",
        seasons: [%SeasonInfo{season_number: 1, name: "Season 1"}]
      },
      media_files: [build_file(lp, rel, %{episode_id: "ep-1"})],
      episodes: [episode]
    }
  end
end
