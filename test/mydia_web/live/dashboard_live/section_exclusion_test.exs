defmodule MydiaWeb.DashboardLive.SectionExclusionTest do
  @moduledoc """
  The dashboard's Movies/TV Shows stat tiles and the sidebar count badges are
  both driven by the `:movie_count` / `:tv_show_count` assigns, which
  `Layouts.app` reads from whatever LiveView is currently mounted. An
  exclusive pinned section must produce the same reduced counts on "/" as it
  does on "/movies" and "/tv", or a user sees a different total depending on
  which page they happen to be on.
  """

  # async: false - the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Collections

  setup %{conn: conn} do
    # DashboardLive.Index unconditionally loads both trending rails on
    # connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = user_fixture(%{role: "admin"})

    for n <- 1..2 do
      categorized_media_item_fixture(
        %{title: "Nebula Frame #{n}", type: "movie"},
        :anime_movie
      )
    end

    for n <- 1..4 do
      categorized_media_item_fixture(
        %{title: "Harbor Reel #{n}", type: "movie"},
        :movie
      )
    end

    for n <- 1..3 do
      categorized_media_item_fixture(
        %{title: "Comet Circuit #{n}", type: "tv_show"},
        :anime_series
      )
    end

    for n <- 1..5 do
      categorized_media_item_fixture(
        %{title: "Harbor Lights #{n}", type: "tv_show"},
        :tv_show
      )
    end

    {:ok, _section} =
      Collections.create_collection(user, %{
        name: "Anime",
        type: "smart",
        visibility: "private",
        smart_rules:
          Jason.encode!(%{
            "conditions" => [
              %{
                "field" => "category",
                "operator" => "in",
                "value" => ["anime_movie", "anime_series"]
              }
            ]
          }),
        pinned_position: 0,
        sidebar_icon: "hero-sparkles",
        exclusive: true
      })

    %{conn: log_in_user(conn, user)}
  end

  test "the movies stat tile matches the exclusion-aware sidebar badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#nav-movie-count", "4")
    assert has_element?(view, "#stat-tile-movies", "4")
  end

  test "the TV shows stat tile matches the exclusion-aware sidebar badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#nav-tv-count", "5")
    assert has_element?(view, "#stat-tile-tv-shows", "5")
  end

  test "the counts agree with the Movies and TV pages themselves", %{conn: conn} do
    {:ok, dashboard, _html} = live(conn, ~p"/")
    {:ok, movies, _html} = live(conn, ~p"/movies")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    assert has_element?(dashboard, "#stat-tile-movies", "4")
    assert has_element?(movies, "#nav-movie-count", "4")

    assert has_element?(dashboard, "#stat-tile-tv-shows", "5")
    assert has_element?(tv, "#nav-tv-count", "5")
  end
end
