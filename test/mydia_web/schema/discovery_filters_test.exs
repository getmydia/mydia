defmodule MydiaWeb.Schema.DiscoveryFiltersTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.AccountsFixtures
  alias Mydia.Media

  @query """
  query Unwatched($category: MediaCategory, $sort: SortInput) {
    unwatched(first: 50, category: $category, sort: $sort) {
      id
      title
    }
  }
  """

  @favorites_query """
  query Favorites($category: MediaCategory) {
    favorites(first: 50, category: $category) {
      id
      title
    }
  }
  """

  setup do
    user = AccountsFixtures.user_fixture()
    %{user: user}
  end

  test "unwatched filters by category", %{user: user} do
    plain = media_item_fixture(%{title: "Plain Film", type: "movie", category: "movie"})
    anime = media_item_fixture(%{title: "Anime Film", type: "movie", category: "anime_movie"})
    media_file_fixture(%{media_item_id: plain.id})
    media_file_fixture(%{media_item_id: anime.id})
    set_category!(plain, "movie")
    set_category!(anime, "anime_movie")

    result = run_query(@query, %{"category" => "ANIME_MOVIE"}, user)

    titles = Enum.map(result["unwatched"], & &1["title"])
    assert titles == ["Anime Film"]
  end

  test "unwatched honours sort", %{user: user} do
    zulu = media_item_fixture(%{title: "Zulu", type: "movie", category: "movie"})
    alpha = media_item_fixture(%{title: "Alpha", type: "movie", category: "movie"})
    media_file_fixture(%{media_item_id: zulu.id})
    media_file_fixture(%{media_item_id: alpha.id})

    result =
      run_query(@query, %{"sort" => %{"field" => "TITLE", "direction" => "ASC"}}, user)

    titles = Enum.map(result["unwatched"], & &1["title"])
    assert titles == ["Alpha", "Zulu"]
  end

  test "favorites filters by category", %{user: user} do
    plain = media_item_fixture(%{title: "Plain Film", type: "movie", category: "movie"})
    anime = media_item_fixture(%{title: "Anime Film", type: "movie", category: "anime_movie"})
    set_category!(plain, "movie")
    set_category!(anime, "anime_movie")
    favorite!(user, plain)
    favorite!(user, anime)

    result = run_query(@favorites_query, %{"category" => "ANIME_MOVIE"}, user)

    titles = Enum.map(result["favorites"], & &1["title"])
    assert titles == ["Anime Film"]
  end

  test "unwatched with no sort returns a stable order across calls", %{user: user} do
    # `paginate_simple/3` pages by positional offset, so an omitted sort must
    # still produce a total order. `list_media_items/1` carries no ORDER BY,
    # and on Postgres an unordered scan can hand back a different order per
    # request, which surfaces as duplicated and skipped items mid-scroll.
    # Asserting stability rather than one specific sequence keeps this from
    # depending on timestamp granularity between fixtures.
    for title <- ["Zulu", "Alpha", "Mike"] do
      item = media_item_fixture(%{title: title, type: "movie", category: "movie"})
      # `unwatched` filters on has_files, so an item with no file is invisible.
      media_file_fixture(%{media_item_id: item.id})
    end

    first_call = Enum.map(run_query(@query, %{}, user)["unwatched"], & &1["title"])
    second_call = Enum.map(run_query(@query, %{}, user)["unwatched"], & &1["title"])

    assert length(first_call) == 3
    assert first_call == second_call
  end

  defp run_query(query, variables, user) do
    assert {:ok, %{data: data}} =
             Absinthe.run(query, MydiaWeb.Schema,
               variables: variables,
               context: %{current_user: user, current_scope: Scope.for_user(user)}
             )

    data
  end

  defp favorite!(user, media_item) do
    {:ok, _} = Media.toggle_favorite(user.id, media_item.id)
  end

  defp set_category!(media_item, category) do
    {:ok, updated} = Media.update_category(media_item, category, override: true)
    updated
  end
end
