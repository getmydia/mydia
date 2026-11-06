defmodule MydiaWeb.Schema.TrendingInLibraryTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers, only: [stub_curated_lists: 2]

  alias Mydia.Accounts.Scope
  alias Mydia.AccountsFixtures

  @query """
  query Trending($type: MediaType!, $first: Int) {
    trendingInLibrary(type: $type, first: $first) {
      id
      title
      trendingRank
    }
  }
  """

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  defp owned_movie(title, tmdb_id) do
    item = media_item_fixture(%{title: title, type: "movie", tmdb_id: tmdb_id})
    media_file_fixture(%{media_item_id: item.id})
    item
  end

  defp tmdb(id), do: %{"id" => id, "title" => "Catalog #{id}", "media_type" => "movie"}

  test "returns owned trending items with trendingRank", %{user: user} do
    first = owned_movie("Zorblax Quarterly", 910_001)
    second = owned_movie("Wumbleton Sprockets", 910_003)
    _unowned = tmdb(910_002)

    stub_curated_lists(:movie, %{
      trending: [tmdb(910_001), tmdb(910_002), tmdb(910_003)],
      popular: []
    })

    data = run_query(@query, %{"type" => "MOVIE", "first" => 5}, user)

    assert [
             %{"id" => id1, "title" => "Zorblax Quarterly", "trendingRank" => 1},
             %{"id" => id2, "title" => "Wumbleton Sprockets", "trendingRank" => 3}
           ] = data["trendingInLibrary"]

    assert id1 == first.id
    assert id2 == second.id
  end

  test "an explicit null first falls back to the default", %{user: user} do
    owned_movie("Zorblax Quarterly", 910_001)
    stub_curated_lists(:movie, %{trending: [tmdb(910_001)], popular: []})

    data = run_query(@query, %{"type" => "MOVIE", "first" => nil}, user)

    assert [%{"title" => "Zorblax Quarterly"}] = data["trendingInLibrary"]
  end

  test "anonymous context answers []" do
    # The schema's auth middleware rejects anonymous callers before the
    # resolver runs, so the resolver's own guard is exercised directly.
    assert {:ok, []} =
             MydiaWeb.Schema.Resolvers.DiscoveryResolver.trending_in_library(
               %{},
               %{type: :movie, first: 5},
               %{context: %{}}
             )
  end

  test "episode type answers []", %{user: user} do
    assert run_query(@query, %{"type" => "EPISODE"}, user)["trendingInLibrary"] == []
  end

  test "relay failure is a field error", %{user: user} do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end

      Mydia.Metadata.Cache.delete("curated:trending:movie:1")
    end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/trending", fn conn ->
      Plug.Conn.resp(conn, 404, "boom")
    end)

    assert {:ok, %{data: data, errors: [_ | _]}} =
             Absinthe.run(@query, MydiaWeb.Schema,
               variables: %{"type" => "MOVIE"},
               context: %{current_user: user, current_scope: Scope.for_user(user)}
             )

    assert data["trendingInLibrary"] == nil
  end

  test "other queries return null trendingRank", %{user: user} do
    owned_movie("The Gilded Teapot Affair", 910_010)

    data =
      run_query(
        "{ recentlyAdded(first: 5) { title trendingRank } }",
        %{},
        user
      )

    assert [%{"title" => "The Gilded Teapot Affair", "trendingRank" => nil}] =
             data["recentlyAdded"]
  end

  defp run_query(query, variables, user) do
    assert {:ok, %{data: data} = result} =
             Absinthe.run(query, MydiaWeb.Schema,
               variables: variables,
               context: %{current_user: user, current_scope: Scope.for_user(user)}
             )

    refute Map.has_key?(result, :errors)
    data
  end
end
