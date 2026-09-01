defmodule Mydia.Media.ExcludeCategoriesTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media

  import Mydia.MediaFixtures

  setup do
    live = categorized_media_item_fixture(%{title: "Harbor Lights", type: "tv_show"}, :tv_show)

    anime =
      categorized_media_item_fixture(%{title: "Comet Circuit", type: "tv_show"}, :anime_series)

    unclassified =
      categorized_media_item_fixture(%{title: "Paper Districts", type: "tv_show"}, nil)

    movie = categorized_media_item_fixture(%{title: "Glass Meridian", type: "movie"}, :movie)

    %{live: live, anime: anime, unclassified: unclassified, movie: movie}
  end

  describe "list_media_items/1 with :exclude_categories" do
    test "drops the excluded categories", %{live: live, anime: anime} do
      titles =
        [type: "tv_show", exclude_categories: ["anime_series"]]
        |> Media.list_media_items()
        |> Enum.map(& &1.title)

      assert live.title in titles
      refute anime.title in titles
    end

    test "keeps items whose category is still nil", %{unclassified: unclassified} do
      titles =
        [type: "tv_show", exclude_categories: ["anime_series"]]
        |> Media.list_media_items()
        |> Enum.map(& &1.title)

      assert unclassified.title in titles
    end

    test "accepts atoms as well as strings", %{anime: anime} do
      titles =
        [type: "tv_show", exclude_categories: [:anime_series]]
        |> Media.list_media_items()
        |> Enum.map(& &1.title)

      refute anime.title in titles
    end

    test "an empty exclusion list changes nothing", %{anime: anime} do
      titles =
        [type: "tv_show", exclude_categories: []]
        |> Media.list_media_items()
        |> Enum.map(& &1.title)

      assert anime.title in titles
    end
  end

  describe "list_media_items/1 with :base_query" do
    test "starts from the supplied query and still applies other filters", %{anime: anime} do
      import Ecto.Query

      base = from(m in Mydia.Media.MediaItem, where: m.category == "anime_series")

      titles =
        [base_query: base, type: "tv_show"]
        |> Media.list_media_items()
        |> Enum.map(& &1.title)

      assert titles == [anime.title]
    end
  end

  describe "counts" do
    test "count_tv_shows/1 respects the exclusion" do
      assert Media.count_tv_shows() == 3
      assert Media.count_tv_shows(exclude_categories: ["anime_series"]) == 2
    end

    test "count_movies/1 respects the exclusion" do
      assert Media.count_movies() == 1
      assert Media.count_movies(exclude_categories: ["movie"]) == 0
    end
  end
end
