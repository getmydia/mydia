defmodule MydiaWeb.MediaLive.Show.RecommendationsRailTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a movie with recommendations renders the rail", %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()

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

    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail")
    assert render(view) =~ "The Eternal Daughter"
  end

  test "a movie with no recommendations renders no rail", %{conn: conn} do
    source_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Obscure",
        year: 2019,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [])
    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    refute has_element?(view, "#recommendations-rail")
  end

  test "an owned recommendation links to its page instead of offering an add",
       %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    owned_tmdb_id = unique_provider_id()

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

    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, ~s(#recommendations-rail a[href="/media/#{owned.id}"]))
  end

  test "a tv show starts collapsed and the header toggles it", %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Detectorists",
        year: 2014,
        tmdb_id: source_tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    warm_recommendations_cache(source_tmdb_id, :tv_show, [
      %{
        "id" => recommended_tmdb_id,
        "name" => "Rev.",
        "first_air_date" => "2010-06-28",
        "poster_path" => "/p.jpg"
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail-toggle")
    refute has_element?(view, "#recommendations-rail-items")

    html = view |> element("#recommendations-rail-toggle") |> render_click()
    assert html =~ "Rev."
    assert has_element?(view, "#recommendations-rail-items")

    view |> element("#recommendations-rail-toggle") |> render_click()
    refute has_element?(view, "#recommendations-rail-items")
  end

  test "a movie rail is not collapsible", %{conn: conn} do
    source_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Aftersun",
        year: 2022,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => unique_provider_id(), "title" => "The Eternal Daughter"}
    ])

    warm_movie_details_cache(source_tmdb_id)

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail")
    refute has_element?(view, "#recommendations-rail-toggle")
  end
end
