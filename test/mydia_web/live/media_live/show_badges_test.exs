defmodule MydiaWeb.MediaLive.ShowBadgesTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "tv show shows rating, status, provider links and a full-date tooltip", %{conn: conn} do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "The Wandering Signal",
        year: 2019,
        tmdb_id: 900_101,
        tvdb_id: 900_202,
        imdb_id: "tt0900303",
        metadata: %{
          "provider_id" => "900101",
          "provider" => "tmdb",
          "media_type" => "tv_show",
          "status" => "Continuing",
          "content_rating" => "TV-MA",
          "first_air_date" => "2019-03-04"
        }
      })

    warm_recommendations_cache(900_101, :tv_show, [])

    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")

    assert has_element?(view, "#media-content-rating", "TV-MA")
    assert has_element?(view, "#media-show-status", "Continuing")
    assert has_element?(view, "#media-release-date[title='Mar 4, 2019']")

    assert has_element?(
             view,
             "#media-link-tmdb[href='https://www.themoviedb.org/tv/900101']"
           )

    assert has_element?(
             view,
             "#media-link-tvdb[href='https://thetvdb.com/?tab=series&id=900202']"
           )

    assert has_element?(
             view,
             "#media-link-imdb[href='https://www.imdb.com/title/tt0900303/']"
           )
  end

  test "movie with no rating and no provider ids shows neither badges nor links", %{conn: conn} do
    item =
      media_item_fixture(%{
        type: "movie",
        title: "Silent Orbit",
        year: 2021
      })

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    refute has_element?(view, "#media-content-rating")
    refute has_element?(view, "#media-show-status")
    refute has_element?(view, "#media-external-links")
  end

  test "movie with a tmdb id links to the movie page and never shows a tvdb link", %{
    conn: conn
  } do
    item =
      media_item_fixture(%{
        type: "movie",
        title: "Glass Harbor",
        year: 2022,
        tmdb_id: 900_404
      })

    warm_recommendations_cache(900_404, :movie, [])
    warm_movie_details_cache(900_404)

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    assert has_element?(
             view,
             "#media-link-tmdb[href='https://www.themoviedb.org/movie/900404']"
           )

    refute has_element?(view, "#media-link-tvdb")
  end
end
