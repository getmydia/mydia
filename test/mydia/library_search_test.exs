defmodule Mydia.LibrarySearchTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.LibrarySearch
  alias Mydia.LibrarySearch.{Result, Results, Section}

  setup do
    %{user: user_fixture()}
  end

  defp section(%Results{sections: sections}, type) do
    Enum.find(sections, &(&1.type == type))
  end

  defp titles(%Section{results: results}), do: Enum.map(results, & &1.title)

  describe "search/3 with an unusable query" do
    test "returns no sections for a blank query", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Alien"})

      assert {:ok, %Results{sections: [], total_count: 0}} = LibrarySearch.search(user, "")
    end

    test "returns no sections for a whitespace-only query", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Alien"})

      assert {:ok, %Results{sections: [], total_count: 0}} = LibrarySearch.search(user, "  \t ")
    end
  end

  describe "search/3 matching" do
    test "matches a movie on title, case-insensitively", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Alien"})

      {:ok, results} = LibrarySearch.search(user, "ALIEN")

      assert titles(section(results, :movie)) == ["Alien"]
    end

    test "matches on original_title but ranks on title", %{user: user} do
      media_item_fixture(%{
        type: "movie",
        title: "The Wages of Fear",
        original_title: "Le Salaire de la Peur"
      })

      {:ok, results} = LibrarySearch.search(user, "salaire")

      movies = section(results, :movie)
      assert titles(movies) == ["The Wages of Fear"]
      assert [%Result{score: 25.0}] = movies.results
    end

    test "ANDs every token, independent of word order", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Long Day's Journey Into Night"})
      media_item_fixture(%{type: "movie", title: "Journey to the Center of the Earth"})

      {:ok, results} = LibrarySearch.search(user, "night journey")

      assert titles(section(results, :movie)) == ["Long Day's Journey Into Night"]
    end

    test "keeps movies and TV shows in separate sections", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Fargo"})
      media_item_fixture(%{type: "tv_show", title: "Fargo"})

      {:ok, results} = LibrarySearch.search(user, "fargo")

      assert titles(section(results, :movie)) == ["Fargo"]
      assert titles(section(results, :tv_show)) == ["Fargo"]
    end

    test "omits a section with no matches", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Fargo"})

      {:ok, results} = LibrarySearch.search(user, "fargo")

      assert section(results, :tv_show) == nil
    end
  end

  describe "search/3 LIKE escaping" do
    test "a percent sign does not match the whole library", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Alien"})
      media_item_fixture(%{type: "movie", title: "100% Wolf"})

      {:ok, results} = LibrarySearch.search(user, "100%")

      assert titles(section(results, :movie)) == ["100% Wolf"]
    end

    test "an underscore is literal, not a single-character wildcard", %{user: user} do
      media_item_fixture(%{type: "movie", title: "snake_case"})
      media_item_fixture(%{type: "movie", title: "snakeXcase"})

      {:ok, results} = LibrarySearch.search(user, "snake_case")

      assert titles(section(results, :movie)) == ["snake_case"]
    end

    test "a backslash is literal", %{user: user} do
      media_item_fixture(%{type: "movie", title: "AC\\DC Live"})
      media_item_fixture(%{type: "movie", title: "ACDC Live"})

      {:ok, results} = LibrarySearch.search(user, "ac\\dc")

      assert titles(section(results, :movie)) == ["AC\\DC Live"]
    end
  end

  describe "search/3 ranking" do
    test "orders exact above prefix above word boundary above mid-word", %{user: user} do
      media_item_fixture(%{type: "movie", title: "zzz Preback"})
      media_item_fixture(%{type: "movie", title: "yyy The Back Room"})
      media_item_fixture(%{type: "movie", title: "Backrooms"})
      media_item_fixture(%{type: "movie", title: "back"})

      {:ok, results} = LibrarySearch.search(user, "back")

      movies = section(results, :movie)
      assert titles(movies) == ["back", "Backrooms", "yyy The Back Room", "zzz Preback"]
      assert Enum.map(movies.results, & &1.score) == [100.0, 75.0, 50.0, 25.0]
    end

    test "breaks rank ties by title ascending", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Backdraft"})
      media_item_fixture(%{type: "movie", title: "Backrooms"})

      {:ok, results} = LibrarySearch.search(user, "back")

      assert titles(section(results, :movie)) == ["Backdraft", "Backrooms"]
    end
  end

  describe "search/3 limits and totals" do
    test "caps results at the limit but reports the true total", %{user: user} do
      for n <- 1..25 do
        media_item_fixture(%{
          type: "movie",
          title: "Alien Part #{String.pad_leading("#{n}", 2, "0")}"
        })
      end

      {:ok, results} = LibrarySearch.search(user, "alien", limit: 5)

      movies = section(results, :movie)
      assert length(movies.results) == 5
      assert movies.total_count == 25
      assert results.total_count == 25
    end

    test "defaults the limit to 20", %{user: user} do
      for n <- 1..25 do
        media_item_fixture(%{
          type: "movie",
          title: "Alien Part #{String.pad_leading("#{n}", 2, "0")}"
        })
      end

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert length(section(results, :movie).results) == 20
    end
  end

  describe "search/3 :types option" do
    test "restricts the search to the requested sections", %{user: user} do
      media_item_fixture(%{type: "movie", title: "Fargo"})
      media_item_fixture(%{type: "tv_show", title: "Fargo"})

      {:ok, results} = LibrarySearch.search(user, "fargo", types: [:tv_show])

      assert Enum.map(results.sections, & &1.type) == [:tv_show]
    end
  end

  describe "search/3 result payload" do
    test "carries year and poster/backdrop paths for a movie", %{user: user} do
      media_item_fixture(%{
        type: "movie",
        title: "Alien",
        year: 1979,
        metadata: %{poster_path: "/poster.jpg", backdrop_path: "/backdrop.jpg"}
      })

      {:ok, results} = LibrarySearch.search(user, "alien")

      assert [
               %Result{
                 type: :movie,
                 year: 1979,
                 poster_path: "/poster.jpg",
                 backdrop_path: "/backdrop.jpg",
                 still_path: nil,
                 subtitle: nil,
                 season_number: nil,
                 episode_number: nil,
                 parent_id: nil
               }
             ] = section(results, :movie).results
    end
  end
end
