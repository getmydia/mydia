defmodule Mydia.LibrarySearchRestrictionsTest do
  use Mydia.DataCase, async: true

  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.LibrarySearch
  alias Mydia.LibrarySearch.{Result, Results, Section}
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  defp section(%Results{sections: sections}, type), do: Enum.find(sections, &(&1.type == type))

  defp titles(nil), do: []
  defp titles(%Section{results: results}), do: Enum.map(results, & &1.title)

  defp recategorize(media_item, category) do
    Repo.update_all(from(m in MediaItem, where: m.id == ^media_item.id),
      set: [category: to_string(category)]
    )

    Repo.get!(MediaItem, media_item.id)
  end

  describe "movie/tv_show sections" do
    test "a restricted scope never sees a movie outside its allowed categories" do
      user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

      media_item_fixture(%{type: "movie", title: "Restricted Thriller Alpha"})
      |> recategorize(:movie)

      {:ok, results} = LibrarySearch.search(user, "Restricted Thriller Alpha")

      assert titles(section(results, :movie)) == []
      assert results.total_count == 0
    end

    test "a restricted scope still sees a movie inside its allowed categories" do
      user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

      media_item_fixture(%{type: "movie", title: "Allowed Cartoon Beta"})
      |> recategorize(:cartoon_movie)

      {:ok, results} = LibrarySearch.search(user, "Allowed Cartoon Beta")

      assert titles(section(results, :movie)) == ["Allowed Cartoon Beta"]
    end

    test "an unrestricted scope (e.g. an admin) sees everything" do
      admin = admin_user_fixture()

      media_item_fixture(%{type: "movie", title: "Unrestricted Gamma"})
      |> recategorize(:movie)

      {:ok, results} = LibrarySearch.search(admin, "Unrestricted Gamma")

      assert titles(section(results, :movie)) == ["Unrestricted Gamma"]
    end
  end

  describe "episode section" do
    test "a restricted scope never sees an episode of a hidden show" do
      user = restricted_user_fixture(%{allowed_categories: ["cartoon_series"]})

      show =
        media_item_fixture(%{type: "tv_show", title: "Hidden Show Delta"})
        |> recategorize(:tv_show)

      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Hidden Pilot Episode"
      })

      {:ok, results} = LibrarySearch.search(user, "Hidden Pilot Episode")

      assert titles(section(results, :episode)) == []
      assert results.total_count == 0
    end

    test "a restricted scope still sees an episode of an allowed show" do
      user = restricted_user_fixture(%{allowed_categories: ["cartoon_series"]})

      show =
        media_item_fixture(%{type: "tv_show", title: "Allowed Show Epsilon"})
        |> recategorize(:cartoon_series)

      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        title: "Allowed Pilot Episode"
      })

      {:ok, results} = LibrarySearch.search(user, "Allowed Pilot Episode")

      assert [%Result{title: "Allowed Pilot Episode"}] = section(results, :episode).results
    end
  end
end
