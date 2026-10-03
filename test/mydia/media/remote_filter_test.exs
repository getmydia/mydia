defmodule Mydia.Media.RemoteFilterTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts.Scope
  alias Mydia.Media.RemoteFilter
  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Structs.SearchResult

  @dead_config %{
    type: :metadata_relay,
    base_url: "http://localhost:1",
    options: %{language: "en-US", timeout: 200, connect_timeout: 100}
  }

  describe "unrestricted" do
    test "returns the list untouched without any lookup" do
      results = [movie(unique_provider_id())]
      assert RemoteFilter.filter(results, Scope.unrestricted(), config: @dead_config) == results
    end
  end

  describe "age limit" do
    setup do
      %{scope: Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))}
    end

    test "keeps a title at or under the limit and fills its rating", %{scope: scope} do
      id = unique_provider_id()

      warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
        content_rating: "PG",
        age: 8,
        category: "movie"
      })

      assert [%SearchResult{content_rating: "PG"}] = RemoteFilter.filter([movie(id)], scope)
    end

    test "drops a title over the limit", %{scope: scope} do
      id = unique_provider_id()

      warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
        content_rating: "R",
        age: 17,
        category: "movie"
      })

      assert RemoteFilter.filter([movie(id)], scope) == []
    end

    test "drops an unrated title", %{scope: scope} do
      id = unique_provider_id()

      warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
        content_rating: nil,
        age: nil,
        category: "movie"
      })

      assert RemoteFilter.filter([movie(id)], scope) == []
    end

    test "drops a title whose lookup raises, without crashing the caller", %{scope: scope} do
      broken_config = %{type: :metadata_relay, base_url: nil, options: nil}

      assert RemoteFilter.filter([movie(unique_provider_id())], scope, config: broken_config) ==
               []
    end

    test "drops a title whose provider id is not a number", %{scope: scope} do
      hit = %SearchResult{provider_id: "not-a-number", provider: :tmdb, media_type: :movie}
      assert RemoteFilter.filter([hit], scope, config: @dead_config) == []

      nil_hit = %SearchResult{provider_id: nil, provider: :tmdb, media_type: :movie}
      assert RemoteFilter.filter([nil_hit], scope, config: @dead_config) == []
    end

    test "drops a title whose lookup fails", %{scope: scope} do
      assert RemoteFilter.filter([movie(unique_provider_id())], scope, config: @dead_config) ==
               []
    end
  end

  describe "category limit" do
    setup do
      %{scope: Scope.for_user(restricted_user_fixture(%{allowed_categories: ["anime_series"]}))}
    end

    test "a TVDB hit with no signals is classified from its lookup", %{scope: scope} do
      id = unique_provider_id()
      warm_remote_signals({:tvdb, id}, :tv_show, %RemoteSignals{category: "anime_series"})

      tvdb_hit = %SearchResult{provider_id: to_string(id), provider: :tvdb, media_type: :tv_show}
      assert [_] = RemoteFilter.filter([tvdb_hit], scope)
    end

    test "a hit with no signals is dropped when its lookup fails" do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["tv_show"]}))

      tvdb_hit = %SearchResult{
        provider_id: to_string(unique_provider_id()),
        provider: :tvdb,
        media_type: :tv_show
      }

      assert RemoteFilter.filter([tvdb_hit], scope, config: @dead_config) == []
    end

    test "a TVDB live action hit is dropped", %{scope: scope} do
      id = unique_provider_id()
      warm_remote_signals({:tvdb, id}, :tv_show, %RemoteSignals{category: "tv_show"})

      tvdb_hit = %SearchResult{provider_id: to_string(id), provider: :tvdb, media_type: :tv_show}
      assert RemoteFilter.filter([tvdb_hit], scope) == []
    end

    test "a TMDB hit with genre signals needs no lookup", %{scope: scope} do
      Mydia.Metadata.Cache.put("genres:tv_show", [%{id: 16, name: "Animation"}])
      on_exit(fn -> Mydia.Metadata.Cache.delete("genres:tv_show") end)

      hit = %SearchResult{
        provider_id: "7",
        provider: :tmdb,
        media_type: :tv_show,
        genre_ids: [16],
        origin_country: ["JP"],
        original_language: "ja"
      }

      assert [_] = RemoteFilter.filter([hit], scope, config: @dead_config)
    end
  end

  test "both dimensions must pass" do
    scope =
      Scope.for_user(
        restricted_user_fixture(%{allowed_categories: ["cartoon_movie"], max_content_age: 7})
      )

    ok = unique_provider_id()
    too_old = unique_provider_id()
    wrong_kind = unique_provider_id()

    warm_remote_signals({:tmdb, ok}, :movie, %RemoteSignals{
      content_rating: "G",
      age: 0,
      category: "cartoon_movie"
    })

    warm_remote_signals({:tmdb, too_old}, :movie, %RemoteSignals{
      content_rating: "PG",
      age: 8,
      category: "cartoon_movie"
    })

    warm_remote_signals({:tmdb, wrong_kind}, :movie, %RemoteSignals{
      content_rating: "G",
      age: 0,
      category: "movie"
    })

    assert [%{provider_id: kept}] =
             RemoteFilter.filter(Enum.map([ok, too_old, wrong_kind], &movie/1), scope)

    assert kept == to_string(ok)
  end

  describe "discover_params/2 category hints" do
    defp hints(categories, type) do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: categories}))
      RemoteFilter.discover_params(scope, type)
    end

    test "cartoon only asks for Animation" do
      assert hints(["cartoon_movie"], :movie)[:required_genres] == ["16"]
      refute Keyword.has_key?(hints(["cartoon_movie"], :movie), :original_language)
    end

    test "anime only asks for Animation in Japanese" do
      params = hints(["anime_series"], :tv_show)
      assert params[:required_genres] == ["16"]
      assert params[:original_language] == "ja"
    end

    test "anime and cartoon ask for Animation only" do
      params = hints(["anime_movie", "cartoon_movie"], :movie)
      assert params[:required_genres] == ["16"]
      refute Keyword.has_key?(params, :original_language)
    end

    test "live action only excludes Animation" do
      assert hints(["movie"], :movie)[:without_genres] == "16"
    end

    test "a mix of live action and animation sends no genre hint" do
      params = hints(["movie", "cartoon_movie"], :movie)
      refute Keyword.has_key?(params, :required_genres)
      refute Keyword.has_key?(params, :without_genres)
    end

    test "categories of the other media type do not leak into hints" do
      assert hints(["cartoon_movie", "tv_show"], :tv_show)[:without_genres] == "16"
    end

    test "any_category? is false when nothing of the type is allowed" do
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
      refute RemoteFilter.any_category?(scope, :tv_show)
      assert RemoteFilter.any_category?(scope, :movie)
    end

    test "unrestricted sends nothing" do
      assert RemoteFilter.discover_params(Scope.unrestricted(), :movie) == []
    end
  end

  defp movie(id),
    do: %SearchResult{
      provider_id: to_string(id),
      provider: :tmdb,
      media_type: :movie,
      id: id
    }
end
