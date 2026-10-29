defmodule Mydia.Jobs.MediaImport.PathsItemTest do
  use Mydia.DataCase, async: false

  @moduletag :tmp_dir

  alias Mydia.Jobs.MediaImport.Paths

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp library(tmp, type, attrs \\ %{}) do
    path = Path.join(tmp, "#{type}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    library_path_fixture(
      Map.merge(%{type: type, path: path, auto_organize: false, auto_rename: false}, attrs)
    )
  end

  test "movie dir is title (year) under the library root", %{tmp_dir: tmp} do
    lib = library(tmp, "movies")
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})

    assert Paths.item_destination_dir(movie, nil, lib, []) ==
             Path.join(lib.path, "Glass Harbor (2019)")
  end

  test "episode dir is show folder plus Season NN", %{tmp_dir: tmp} do
    lib = library(tmp, "series")
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})
    ep = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 5})

    assert Paths.item_destination_dir(show, ep, lib, []) ==
             Path.join([lib.path, "The Quiet Meridian", "Season 02"])
  end

  test "series without an episode is the show folder", %{tmp_dir: tmp} do
    lib = library(tmp, "series")
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})

    assert Paths.item_destination_dir(show, nil, lib, []) ==
             Path.join(lib.path, "The Quiet Meridian")
  end

  test "auto_organize uses the category path", %{tmp_dir: tmp} do
    lib =
      library(tmp, "movies", %{auto_organize: true, category_paths: %{"anime_movie" => "Anime"}})

    movie =
      media_item_fixture(%{type: "movie", title: "Paper Lanterns", year: 2001})
      |> Ecto.Changeset.change(category: "anime_movie")
      |> Mydia.Repo.update!()

    assert Paths.item_destination_dir(movie, nil, lib, []) ==
             Path.join([lib.path, "Anime", "Paper Lanterns (2001)"])
  end

  test "item_filename keeps the original name when rename is off" do
    movie = %Mydia.Media.MediaItem{type: "movie", title: "Glass Harbor", year: 2019}

    assert Paths.item_filename(movie, nil, "glass.harbor.2019.1080p.mkv", false, nil) ==
             "glass.harbor.2019.1080p.mkv"
  end

  test "item_filename renames a movie when rename is on" do
    movie = %Mydia.Media.MediaItem{type: "movie", title: "Glass Harbor", year: 2019}
    name = Paths.item_filename(movie, nil, "glass.harbor.2019.1080p.mkv", true, nil)
    assert name =~ "Glass Harbor"
    assert Path.extname(name) == ".mkv"
  end
end
