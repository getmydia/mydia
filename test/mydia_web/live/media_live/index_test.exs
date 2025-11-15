defmodule MydiaWeb.MediaLive.IndexTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  describe "Media Library Index" do
    setup %{conn: conn} do
      # Create and log in an admin user
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)
      # Create test media items
      movie1 =
        media_item_fixture(%{
          title: "The Matrix",
          original_title: nil,
          year: 1999,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A computer hacker learns about the true nature of reality"}
        })

      movie2 =
        media_item_fixture(%{
          title: "Inception",
          original_title: nil,
          year: 2010,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A thief who steals corporate secrets through dream-sharing"}
        })

      show1 =
        media_item_fixture(%{
          title: "Breaking Bad",
          original_title: nil,
          year: 2008,
          type: "tv_show",
          monitored: true,
          metadata: %{
            "overview" => "A chemistry teacher diagnosed with cancer turns to cooking meth"
          }
        })

      show2 =
        media_item_fixture(%{
          title: "Stranger Things",
          original_title: nil,
          year: 2016,
          type: "tv_show",
          monitored: false,
          metadata: %{"overview" => "A group of kids encounter supernatural forces"}
        })

      japanese_movie =
        media_item_fixture(%{
          title: "Spirited Away",
          original_title: "千と千尋の神隠し",
          year: 2001,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A young girl enters a world of spirits"}
        })

      %{
        conn: conn,
        movie1: movie1,
        movie2: movie2,
        show1: show1,
        show2: show2,
        japanese_movie: japanese_movie
      }
    end

    test "displays search input field", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/media")

      assert html =~ "Search media"
      assert has_element?(view, "input[name='search']")
    end

    test "search filters by title (case-insensitive)", %{
      conn: conn,
      movie1: _movie1,
      movie2: _movie2
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for "matrix" (lowercase)
      view
      |> element("form#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Verify the search query was set
      assert has_element?(view, "input[name='search'][value='matrix']")

      # Verify the stream was filtered correctly
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='matrix'][data-stream-count='1']"
             )
    end

    test "search filters by year", %{conn: conn, movie1: _movie1, movie2: _movie2} do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for "1999"
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "1999"})

      # Verify the stream was filtered correctly (should show only The Matrix)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='1999'][data-stream-count='1']"
             )
    end

    test "search filters by original title", %{
      conn: conn,
      japanese_movie: _japanese_movie,
      movie1: _movie1
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search by original Japanese title (partial match)
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "千と"})

      # Verify the stream was filtered correctly (should show only Spirited Away)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(view, "#test-debug-info[data-search-query='千と'][data-stream-count='1']")
    end

    test "search filters by overview/description", %{conn: conn, show1: _show1, movie2: _movie2} do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for "chemistry"
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "chemistry"})

      # Verify the stream was filtered correctly (should show only Breaking Bad)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='chemistry'][data-stream-count='1']"
             )
    end

    test "clearing search shows all items", %{
      conn: conn,
      movie1: movie1,
      movie2: movie2,
      show1: show1
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # First, apply a search
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Only The Matrix should be visible
      assert has_element?(view, "#media-items-grid", movie1.title)

      # Clear the search
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => ""})

      # All items should be visible again
      assert has_element?(view, "#media-items-grid", movie1.title)
      assert has_element?(view, "#media-items-grid", movie2.title)
      assert has_element?(view, "#media-items-grid", show1.title)
    end

    test "search works for both movies and TV shows", %{
      conn: conn,
      movie1: _movie1,
      show1: _show1
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for "Bad" - should match Breaking Bad
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Bad"})

      # Verify the stream was filtered correctly (should show only Breaking Bad)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Bad'][data-stream-count='1']"
             )

      # Search for "Matrix" - should match The Matrix
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Matrix"})

      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Matrix'][data-stream-count='1']"
             )
    end

    test "search shows empty state when no results found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for something that doesn't exist
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "NonexistentMovie12345"})

      # Should show empty state with helpful message
      assert has_element?(view, ".flex.flex-col.items-center", "No media found")
      assert has_element?(view, ".text-base-content\\/50", "Try adjusting your search or filters")
    end

    test "search is debounced to avoid excessive filtering", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/media")

      # The search input should have phx-debounce attribute
      assert has_element?(view, "input[name='search'][phx-debounce='300']")
    end

    test "search works in list view mode", %{conn: conn, movie1: _movie1, movie2: _movie2} do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Switch to list view
      view
      |> element("button[phx-value-mode='list']")
      |> render_click()

      # Search for "matrix"
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Verify the stream was filtered correctly (should show only The Matrix)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='matrix'][data-stream-count='1']"
             )
    end

    test "search persists when switching between grid and list view", %{
      conn: conn,
      movie1: movie1
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Apply search in grid view
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Switch to list view
      view
      |> element("button[phx-value-mode='list']")
      |> render_click()

      # Search should still be applied
      assert has_element?(view, "#media-items-list", movie1.title)

      # Switch back to grid view
      view
      |> element("button[phx-value-mode='grid']")
      |> render_click()

      # Search should still be applied
      assert has_element?(view, "#media-items-grid", movie1.title)
    end

    test "search can be combined with monitoring filter", %{
      conn: conn,
      show1: show1,
      show2: show2
    } do
      {:ok, view, _html} = live(conn, ~p"/media")

      # Search for "Things"
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Things"})

      # Should show Stranger Things
      assert has_element?(view, "#media-items-grid", show2.title)

      # Apply monitored filter
      view
      |> element("form#library-filter-form")
      |> render_change(%{"monitored" => "true"})

      # Should not show Stranger Things (it's unmonitored)
      refute has_element?(view, "#media-items-grid", show2.title)
      # But Breaking Bad should not show either (doesn't match search)
      refute has_element?(view, "#media-items-grid", show1.title)
    end
  end
end
