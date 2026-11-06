defmodule Mydia.Media.TrendingInLibraryTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media.TrendingInLibrary
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.Playback

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  # Builds a fetch stub from `%{{list, page} => ids}`. Each call is reported to
  # the test process; pages absent from the map come back empty.
  defp stub(pages, opts \\ []) do
    parent = self()
    total_pages = Keyword.get(opts, :total_pages, 1)

    fn list, fetch_opts ->
      page = Keyword.fetch!(fetch_opts, :page)
      send(parent, {:fetched, list, page, Keyword.get(fetch_opts, :media_type)})

      results =
        pages
        |> Map.get({list, page}, [])
        |> Enum.map(&%SearchResult{provider_id: &1, provider: :tmdb, media_type: :movie})

      {:ok, %{results: results, page: page, total_pages: total_pages}}
    end
  end

  defp owned_movie(tmdb_id, attrs \\ %{}) do
    movie = media_item_fixture(Map.merge(%{type: "movie", tmdb_id: tmdb_id}, attrs))
    media_file_fixture(%{media_item_id: movie.id})
    movie
  end

  defp owned_show(tmdb_id, episode_count) do
    show = media_item_fixture(%{type: "tv_show", tmdb_id: tmdb_id})

    episodes =
      for _ <- 1..episode_count do
        episode = episode_fixture(%{media_item_id: show.id})
        media_file_fixture(%{episode_id: episode.id})
        episode
      end

    {show, episodes}
  end

  defp watch(user, key, id, watched) do
    {:ok, _} =
      Playback.save_progress(user.id, [{key, id}], %{
        position_seconds: if(watched, do: 100, else: 40),
        duration_seconds: 100,
        watched: watched
      })
  end

  defp drain_fetches(acc \\ []) do
    receive do
      {:fetched, list, page, _type} -> drain_fetches([{list, page} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "list/4" do
    test "returns owned matches in TMDB order with ranks", %{user: user, scope: scope} do
      owned_movie(13)
      owned_movie(11)
      fetch = stub(%{{:trending, 1} => ["11", "12", "13"]})

      assert {:ok, [{%{tmdb_id: 11}, 1}, {%{tmdb_id: 13}, 3}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "rank counts every fetched id, deduped across lists", %{user: user, scope: scope} do
      owned_movie(3)
      fetch = stub(%{{:trending, 1} => ["1", "2"], {:popular, 1} => ["2", "3"]})

      assert {:ok, [{%{tmdb_id: 3}, 3}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "digs into popular when trending is short", %{user: user, scope: scope} do
      owned_movie(50)
      fetch = stub(%{{:trending, 1} => ["1", "2"], {:popular, 1} => ["50"]})

      assert {:ok, [{%{tmdb_id: 50}, 3}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "stops at limit and does not fetch further pages", %{user: user, scope: scope} do
      owned_movie(1)
      fetch = stub(%{{:trending, 1} => ["1"], {:popular, 1} => ["2"]})

      assert {:ok, [{%{tmdb_id: 1}, 1}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch, limit: 1)

      refute_received {:fetched, :popular, _, _}
    end

    test "respects page caps and total_pages", %{user: user, scope: scope} do
      fetch = stub(%{}, total_pages: 10)
      assert {:ok, []} = TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)

      assert drain_fetches() ==
               [trending: 1, trending: 2, trending: 3] ++
                 [popular: 1, popular: 2, popular: 3, popular: 4, popular: 5]

      fetch = stub(%{}, total_pages: 2)
      assert {:ok, []} = TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
      assert drain_fetches() == [trending: 1, trending: 2, popular: 1, popular: 2]
    end

    test "drops items without files and fully watched movies", %{user: user, scope: scope} do
      media_item_fixture(%{type: "movie", tmdb_id: 1})
      watched = owned_movie(2)
      in_progress = owned_movie(3)
      owned_movie(4)
      watch(user, :media_item_id, watched.id, true)
      watch(user, :media_item_id, in_progress.id, false)
      fetch = stub(%{{:trending, 1} => ["1", "2", "3", "4"]})

      assert {:ok, [{%{tmdb_id: 3}, 3}, {%{tmdb_id: 4}, 4}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "show watch rules", %{user: user, scope: scope} do
      {_, [watched_ep, _unwatched_ep]} = owned_show(1, 2)
      {_, [a, b]} = owned_show(2, 2)
      media_item_fixture(%{type: "tv_show", tmdb_id: 3})
      watch(user, :episode_id, watched_ep.id, true)
      watch(user, :episode_id, a.id, true)
      watch(user, :episode_id, b.id, true)
      fetch = stub(%{{:trending, 1} => ["1", "2", "3"]})

      assert {:ok, [{%{tmdb_id: 1}, 1}]} =
               TrendingInLibrary.list(scope, user.id, :tv_show, fetch: fetch)

      assert_received {:fetched, :trending, 1, :tv_show}
    end

    test "respects scope restrictions", %{user: user} do
      item =
        categorized_media_item_fixture(%{type: "movie", tmdb_id: 7}, "movie")

      media_file_fixture(%{media_item_id: item.id})
      fetch = stub(%{{:trending, 1} => ["7"]})

      restricted =
        Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert {:ok, []} = TrendingInLibrary.list(restricted, user.id, :movie, fetch: fetch)

      assert {:ok, [{%{tmdb_id: 7}, 1}]} =
               TrendingInLibrary.list(Scope.unrestricted(), user.id, :movie, fetch: fetch)
    end

    test "skips non-integer provider ids", %{user: user, scope: scope} do
      owned_movie(5)
      fetch = stub(%{{:trending, 1} => ["abc", nil, "5x", "5"]})

      assert {:ok, [{%{tmdb_id: 5}, 1}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "error before any page succeeds is an error", %{user: user, scope: scope} do
      fetch = fn _list, _opts -> {:error, :boom} end
      assert {:error, :boom} = TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "error on a later page returns the matches so far", %{user: user, scope: scope} do
      owned_movie(1)

      fetch = fn list, opts ->
        case {list, opts[:page]} do
          {:trending, 1} ->
            {:ok,
             %{
               results: [%SearchResult{provider_id: "1", provider: :tmdb, media_type: :movie}],
               page: 1,
               total_pages: 3
             }}

          _ ->
            {:error, :boom}
        end
      end

      assert {:ok, [{%{tmdb_id: 1}, 1}]} =
               TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)
    end

    test "filters by media_type", %{user: user, scope: scope} do
      owned_show(9, 1)
      fetch = stub(%{{:trending, 1} => ["9"]})

      assert {:ok, []} = TrendingInLibrary.list(scope, user.id, :movie, fetch: fetch)

      assert {:ok, [{%{tmdb_id: 9}, 1}]} =
               TrendingInLibrary.list(scope, user.id, :tv_show, fetch: fetch)
    end
  end
end
