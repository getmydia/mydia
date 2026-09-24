defmodule Mydia.Library.ExportTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.Export
  alias Mydia.Library.Export.Row

  defp row_for(rows, id_title), do: Enum.find(rows, &(&1.title == id_title))

  describe "rows/0" do
    test "returns an empty list for an empty library" do
      assert Export.rows() == []
    end

    test "a movie counts its version files and ignores trashed files and extras" do
      profile = quality_profile_fixture(%{name: "Crisp 1080"})

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "The Lantern Keeper",
          year: 2021,
          tmdb_id: 900_001,
          imdb_id: "tt9000001",
          quality_profile_id: profile.id
        })

      media_file_fixture(%{media_item_id: movie.id, size: 1_000})
      media_file_fixture(%{media_item_id: movie.id, size: 2_000})
      media_file_fixture(%{media_item_id: movie.id, size: 50, extra_kind: :trailer})

      trashed = media_file_fixture(%{media_item_id: movie.id, size: 9_999})
      {:ok, _} = Library.update_media_file(trashed, %{trashed_at: DateTime.utc_now()})

      assert [%Row{} = row] = Export.rows()
      assert row.type == "movie"
      assert row.title == "The Lantern Keeper"
      assert row.year == 2021
      assert row.tmdb_id == 900_001
      assert row.imdb_id == "tt9000001"
      assert row.quality_profile == "Crisp 1080"
      assert row.monitored == true
      assert row.file_count == 2
      assert row.size_bytes == 3_000
      assert row.episode_count == nil
      assert row.episodes_with_files == nil
      assert %DateTime{} = row.added_at
    end

    test "a show counts files reached through episodes (media_item_id is NULL on them)" do
      show = media_item_fixture(%{type: "tv_show", title: "Harbor of Echoes", tvdb_id: 800_001})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      _e3 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})

      f1 = media_file_fixture(%{episode_id: e1.id, size: 700})
      assert is_nil(f1.media_item_id)
      media_file_fixture(%{episode_id: e2.id, size: 300})

      assert [row] = Export.rows()
      assert row.type == "tv_show"
      assert row.tvdb_id == 800_001
      assert row.file_count == 2
      assert row.size_bytes == 1_000
      assert row.episode_count == 3
      assert row.episodes_with_files == 2
    end

    test "a multi-episode file counts once but covers every linked episode" do
      show = media_item_fixture(%{type: "tv_show", title: "Salt Road"})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      file = media_file_fixture(%{episode_id: e1.id, size: 500})
      Library.link_file_to_episodes(file, [e1, e2])

      assert [row] = Export.rows()
      assert row.file_count == 1
      assert row.size_bytes == 500
      assert row.episode_count == 2
      assert row.episodes_with_files == 2
    end

    test "an item with no files reports zeros and nil optional fields" do
      media_item_fixture(%{type: "movie", title: "Paper Comet"})

      assert [row] = Export.rows()
      assert row.file_count == 0
      assert row.size_bytes == 0
      assert row.tmdb_id == nil
      assert row.quality_profile == nil
    end

    test "carries the library path's root path" do
      lp = library_path_fixture(%{type: "movies"})
      media_item_fixture(%{type: "movie", title: "Quiet Tides", library_path_id: lp.id})

      assert [row] = Export.rows()
      assert row.library_path == lp.path
    end

    test "sorts by type, then case-insensitive title, then year" do
      media_item_fixture(%{type: "tv_show", title: "alpha Station"})
      media_item_fixture(%{type: "movie", title: "beacon", year: 2020})
      media_item_fixture(%{type: "movie", title: "Beacon", year: 2010})
      media_item_fixture(%{type: "movie", title: "Amber Field"})

      assert Enum.map(Export.rows(), &{&1.type, &1.title, &1.year}) == [
               {"movie", "Amber Field", 2024},
               {"movie", "Beacon", 2010},
               {"movie", "beacon", 2020},
               {"tv_show", "alpha Station", 2024}
             ]
    end
  end
end
