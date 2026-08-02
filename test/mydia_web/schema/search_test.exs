defmodule MydiaWeb.Schema.SearchTest do
  use MydiaWeb.ConnCase

  alias Mydia.AccountsFixtures
  alias Mydia.CollectionsFixtures
  alias Mydia.MediaFixtures

  @search_query """
  query Search($query: String!, $types: [SearchResultType], $first: Int) {
    search(query: $query, types: $types, first: $first) {
      totalCount
      sections {
        type
        totalCount
        results {
          id
          type
          title
          year
          subtitle
          seasonNumber
          episodeNumber
          parentId
          score
          artwork {
            posterUrl
            backdropUrl
            thumbnailUrl
          }
        }
      }
    }
  }
  """

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  defp run_query(query, variables, user \\ nil) do
    context = if user, do: %{current_user: user}, else: %{}
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end

  defp section(sections, type), do: Enum.find(sections, &(&1["type"] == type))

  test "returns grouped sections for all four types", %{user: user} do
    MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien"})
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Alien Nation"})

    MediaFixtures.episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 3,
      title: "Alien Encounter"
    })

    CollectionsFixtures.collection_fixture(%{user: user, name: "Alien Anthology"})

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien"}, user)

    types = Enum.map(search["sections"], & &1["type"])
    assert types == ["MOVIE", "TV_SHOW", "EPISODE", "COLLECTION"]
    assert search["totalCount"] == 4
  end

  test "serializes episode context fields", %{user: user} do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Alien Nation"})

    MediaFixtures.episode_fixture(%{
      media_item_id: show.id,
      season_number: 1,
      episode_number: 3,
      title: "Fountain of Youth"
    })

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "fountain"}, user)

    assert [result] = section(search["sections"], "EPISODE")["results"]
    assert result["title"] == "Fountain of Youth"
    assert result["subtitle"] == "Alien Nation"
    assert result["seasonNumber"] == 1
    assert result["episodeNumber"] == 3
    assert result["parentId"] == show.id
  end

  test "populates score as a float", %{user: user} do
    MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien"})

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien"}, user)

    assert [%{"score" => 100.0}] = section(search["sections"], "MOVIE")["results"]
  end

  test "builds artwork URLs from metadata paths", %{user: user} do
    MediaFixtures.media_item_fixture(%{
      type: "movie",
      title: "Alien",
      metadata: %{poster_path: "/poster.jpg"}
    })

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien"}, user)

    assert [%{"artwork" => %{"posterUrl" => url}}] =
             section(search["sections"], "MOVIE")["results"]

    assert url =~ "/poster.jpg"
  end

  test "accepts a COLLECTION type filter", %{user: user} do
    MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien"})
    CollectionsFixtures.collection_fixture(%{user: user, name: "Alien Anthology"})

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien", "types" => ["COLLECTION"]}, user)

    assert Enum.map(search["sections"], & &1["type"]) == ["COLLECTION"]
  end

  test "respects the first argument as the per-section limit", %{user: user} do
    for n <- 1..5 do
      MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien Part #{n}"})
    end

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien", "first" => 2}, user)

    movies = section(search["sections"], "MOVIE")
    assert length(movies["results"]) == 2
    assert movies["totalCount"] == 5
  end

  test "clamps a negative first to the floor instead of passing it through to LIMIT", %{
    user: user
  } do
    for n <- 1..3 do
      MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien Part #{n}"})
    end

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien", "first" => -1}, user)

    movies = section(search["sections"], "MOVIE")
    assert length(movies["results"]) == 1
    assert movies["totalCount"] == 3
  end

  test "clamps a zero first to the floor instead of rendering an empty page", %{user: user} do
    for n <- 1..3 do
      MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien Part #{n}"})
    end

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien", "first" => 0}, user)

    movies = section(search["sections"], "MOVIE")
    assert length(movies["results"]) == 1
    assert movies["totalCount"] == 3
  end

  test "clamps a first above the maximum instead of passing it through unbounded", %{
    user: user
  } do
    for n <- 1..105 do
      MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien Part #{n}"})
    end

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien", "first" => 1000}, user)

    movies = section(search["sections"], "MOVIE")
    assert length(movies["results"]) == 100
    assert movies["totalCount"] == 105
  end

  test "returns empty sections for a blank query", %{user: user} do
    MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien"})

    assert {:ok, %{data: %{"search" => %{"sections" => [], "totalCount" => 0}}}} =
             run_query(@search_query, %{"query" => "   "}, user)
  end

  test "errors instead of returning results when unauthenticated" do
    MediaFixtures.media_item_fixture(%{type: "movie", title: "Alien"})

    assert {:ok, %{errors: [%{message: message}]}} =
             run_query(@search_query, %{"query" => "alien"})

    # Root-field middleware rejects before the resolver runs, so the unified
    # "Authentication required" message is the expected one now.
    assert message =~ "Authentication required" or message =~ "unauthenticated"
  end

  test "another user's private collection is not reachable through the API", %{user: user} do
    other = AccountsFixtures.user_fixture()

    CollectionsFixtures.collection_fixture(%{
      user: other,
      name: "Alien Anthology",
      visibility: "private"
    })

    assert {:ok, %{data: %{"search" => search}}} =
             run_query(@search_query, %{"query" => "alien"}, user)

    assert section(search["sections"], "COLLECTION") == nil
  end
end
