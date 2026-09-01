defmodule MydiaWeb.DiscoverLive.AuthorizationTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import MydiaWeb.AuthHelpers
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  setup do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530), for every role and both browse and search mode.
    warm_genre_cache(:movie, [])
    :ok
  end

  describe "DiscoverLive - Authorization" do
    test "guest users can access the discover page", %{conn: conn} do
      guest = user_fixture(%{role: "guest"})
      conn = log_in_user(conn, guest)
      warm_trending_cache(:movie, [])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie")

      assert view
    end

    test "guest users cannot trigger add_to_library event", %{conn: conn} do
      guest = user_fixture(%{role: "guest"})
      conn = log_in_user(conn, guest)
      warm_movie_search_cache("quiet harbour", [], [])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      # A guest is never offered the Add to Library button, but the event
      # handler itself must reject the event too: nothing stops a guest from
      # pushing the raw event over the socket.
      result =
        render_click(view, "add_to_library", %{"tmdb_id" => "693134", "media_type" => "movie"})

      assert result =~ "You do not have permission to add media items"
    end

    test "user role can access discover", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      conn = log_in_user(conn, user)
      warm_trending_cache(:movie, [])

      {:ok, _view, html} = live(conn, ~p"/discover?type=movie")

      assert html =~ "Discover"
    end

    test "admin role can access discover", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_user(conn, admin)
      warm_trending_cache(:movie, [])

      {:ok, _view, html} = live(conn, ~p"/discover?type=movie")

      assert html =~ "Discover"
    end

    test "a guest sees Request and not Add", %{conn: conn} do
      user = user_fixture(%{role: "guest"})
      conn = log_in_user(conn, user)

      warm_movie_search_cache("quiet harbour", [], [
        %{
          "id" => unique_provider_id(),
          "title" => "Quiet Harbour",
          "release_date" => "2020-01-01"
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=quiet+harbour")

      assert has_element?(view, "button", "Request")
      refute has_element?(view, "button", "Add to Library")
    end
  end
end
