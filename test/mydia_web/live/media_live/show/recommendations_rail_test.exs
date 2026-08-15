defmodule MydiaWeb.MediaLive.Show.RecommendationsRailTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a movie with recommendations renders the rail", %{conn: conn} do
    source_tmdb_id = System.unique_integer([:positive])
    recommended_tmdb_id = System.unique_integer([:positive])

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Aftersun",
        year: 2022,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => recommended_tmdb_id,
        "title" => "The Eternal Daughter",
        "release_date" => "2022-12-02",
        "poster_path" => "/p.jpg"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail")
    assert render(view) =~ "The Eternal Daughter"
  end

  test "a movie with no recommendations renders no rail", %{conn: conn} do
    source_tmdb_id = System.unique_integer([:positive])

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Obscure",
        year: 2019,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    refute has_element?(view, "#recommendations-rail")
  end

  test "an owned recommendation links to its page instead of offering an add",
       %{conn: conn} do
    source_tmdb_id = System.unique_integer([:positive])
    owned_tmdb_id = System.unique_integer([:positive])

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Aftersun",
        year: 2022,
        tmdb_id: source_tmdb_id
      })

    owned =
      media_item_fixture(%{
        type: "movie",
        title: "Already Here",
        year: 2013,
        tmdb_id: owned_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => owned_tmdb_id, "title" => "Already Here", "release_date" => "2013-01-01"}
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, ~s(#recommendations-rail a[href="/media/#{owned.id}"]))
  end

  # Populates the shared metadata cache through the real fetch path, with the
  # relay response coming from Bypass. `fetch_recommendations_cached/3` keys on
  # the provider type, id, media type and language but NOT the base URL, so the
  # LiveView's own default config reads this entry back without any outbound
  # request.
  defp warm_recommendations_cache(tmdb_id, media_type, results) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete(
        "recommendations:#{relay.type}:#{tmdb_id}:#{media_type}:#{relay.options.language}"
      )
    end)

    path =
      if media_type == :tv_show, do: "/tmdb/tv/shows/#{tmdb_id}", else: "/tmdb/movies/#{tmdb_id}"

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => "Source",
        "recommendations" => %{
          "page" => 1,
          "results" => results,
          "total_pages" => 1,
          "total_results" => length(results)
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _results} =
      Metadata.fetch_recommendations_cached(config, to_string(tmdb_id), media_type: media_type)

    :ok
  end
end
