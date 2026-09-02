defmodule MydiaWeb.DiscoverLive.SearchTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530).
    warm_genre_cache(:movie, [])

    user = create_admin_user()
    %{conn: log_in_user(conn, user)}
  end

  test "renders a search form", %{conn: conn} do
    warm_trending_cache(:movie, [])

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-search-form")
    assert has_element?(view, "#discover-search-input")
  end

  test "submitting a query patches the url with q", %{conn: conn} do
    warm_trending_cache(:movie, [])
    warm_movie_search_cache("quiet harbour", [], [])

    {:ok, view, _html} = live(conn, ~p"/discover")

    view
    |> form("#discover-search-form", %{"q" => "quiet harbour"})
    |> render_submit()

    assert_patched(view, ~p"/discover?q=quiet+harbour&type=movie")
  end

  test "search mode shows a results chip instead of the category tabs", %{conn: conn} do
    warm_movie_search_cache("quiet harbour", [], [])

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    assert has_element?(view, "#discover-search-chip")
    assert has_element?(view, "#discover-search-clear")
    refute has_element?(view, "[role=tablist]")
  end

  test "clearing the search returns to browse mode", %{conn: conn} do
    warm_movie_search_cache("quiet harbour", [], [])
    warm_trending_cache(:movie, [])

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

    view |> element("#discover-search-clear") |> render_click()

    assert_patched(view, ~p"/discover?type=movie")
    refute has_element?(view, "#discover-search-chip")
  end
end
