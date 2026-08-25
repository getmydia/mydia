defmodule MydiaWeb.DiscoverLive.RestrictedDiscoverTest do
  # Connected LiveView tests cannot be async on the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.RemoteFilter

  # RemoteFilter.allow?/2 recovers a genre name from the genre id by reading
  # `Mydia.Metadata.genres/1`, which hits the relay on a cache miss. Warming
  # the cache directly avoids an unwarmed lookup escaping to the live relay
  # (see the franchise lookup issue this repo already hit once).
  setup do
    Cache.put("genres:movie", [%{id: 16, name: "Animation"}, %{id: 53, name: "Thriller"}])
    Cache.put("genres:tv_show", [%{id: 16, name: "Animation"}, %{id: 53, name: "Thriller"}])
    :ok
  end

  test "an animation-only scope keeps an animated result" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

    animated = %SearchResult{
      provider_id: "1",
      provider: :metadata_relay,
      media_type: :movie,
      genre_ids: [16]
    }

    assert RemoteFilter.allow?(animated, scope)
  end

  test "an animation-only scope drops a live action result" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

    thriller = %SearchResult{
      provider_id: "2",
      provider: :metadata_relay,
      media_type: :movie,
      genre_ids: [53]
    }

    refute RemoteFilter.allow?(thriller, scope)
  end

  test "an age limit becomes a TMDB certification ceiling" do
    scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))

    assert RemoteFilter.discover_params(scope) == [
             certification_country: "US",
             certification_lte: "PG"
           ]
  end

  test "no age limit adds no discover parameters" do
    assert RemoteFilter.discover_params(Scope.unrestricted()) == []
  end

  test "an anime-only scope keeps an animated result with Japanese origin signals" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["anime_series"]}))

    anime = %SearchResult{
      provider_id: "3",
      provider: :metadata_relay,
      media_type: :tv_show,
      genre_ids: [16],
      origin_country: ["JP"],
      original_language: "ja"
    }

    assert RemoteFilter.allow?(anime, scope)
  end

  test "an anime-only scope drops the same animated result without the Japanese origin signals" do
    scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["anime_series"]}))

    cartoon = %SearchResult{
      provider_id: "4",
      provider: :metadata_relay,
      media_type: :tv_show,
      genre_ids: [16],
      origin_country: [],
      original_language: nil
    }

    refute RemoteFilter.allow?(cartoon, scope)
  end

  test "the discover page renders for a restricted account", %{conn: conn} do
    conn = log_in_user(conn, restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-page")
  end
end
