defmodule MydiaWeb.MediaLive.IndexTest do
  use MydiaWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
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
      {:ok, view, html} = live(conn, ~p"/movies")

      assert html =~ "Search media"
      assert has_element?(view, "input[name='search']")
    end

    test "search filters by title (case-insensitive)", %{
      conn: conn,
      movie1: _movie1,
      movie2: _movie2
    } do
      {:ok, view, _html} = live(conn, ~p"/movies")

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
      {:ok, view, _html} = live(conn, ~p"/movies")

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
      {:ok, view, _html} = live(conn, ~p"/movies")

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

    test "search filters by overview/description", %{conn: conn, movie1: _movie1, movie2: _movie2} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      # Search for "dream-sharing" which matches Inception's overview
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "dream-sharing"})

      # Verify the stream was filtered correctly (should show only Inception)
      # Note: Due to LiveView testing limitations with phx-update="stream",
      # we can't reliably test the rendered HTML. Instead, we verify the stream state
      # via data attributes.
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='dream-sharing'][data-stream-count='1']"
             )
    end

    test "clearing search shows all items", %{
      conn: conn,
      movie1: movie1,
      movie2: movie2
    } do
      {:ok, view, _html} = live(conn, ~p"/movies")

      # First, apply a search
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Only The Matrix should be visible
      assert has_element?(view, "#media-items", movie1.title)

      # Clear the search
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => ""})

      # All movie items should be visible again
      assert has_element?(view, "#media-items", movie1.title)
      assert has_element?(view, "#media-items", movie2.title)
    end

    test "search works for different movies", %{
      conn: conn,
      movie1: _movie1,
      movie2: _movie2
    } do
      {:ok, view, _html} = live(conn, ~p"/movies")

      # Search for "Inception" - should match Inception
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Inception"})

      # Verify the stream was filtered correctly (should show only Inception)
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Inception'][data-stream-count='1']"
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
      {:ok, view, _html} = live(conn, ~p"/movies")

      # Search for something that doesn't exist
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "NonexistentMovie12345"})

      # Should show empty state with helpful message
      assert has_element?(view, ".flex.flex-col.items-center", "No media found")
      assert has_element?(view, ".text-base-content\\/50", "No results for")
    end

    test "search is debounced to avoid excessive filtering", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/movies")

      # The search input should have phx-debounce attribute
      assert has_element?(view, "input[name='search'][phx-debounce='300']")
    end

    test "search works in list view mode", %{conn: conn, movie1: _movie1, movie2: _movie2} do
      {:ok, view, _html} = live(conn, ~p"/movies")

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
      {:ok, view, _html} = live(conn, ~p"/movies")

      # Apply search in grid view
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "matrix"})

      # Switch to list view
      view
      |> element("button[phx-value-mode='list']")
      |> render_click()

      # Search should still be applied
      assert has_element?(view, "#media-items", movie1.title)

      # Switch back to grid view
      view
      |> element("button[phx-value-mode='grid']")
      |> render_click()

      # Search should still be applied
      assert has_element?(view, "#media-items", movie1.title)
    end

    test "search can be combined with monitoring filter", %{conn: conn} do
      # Create an unmonitored movie for this test
      _unmonitored_movie =
        media_item_fixture(%{
          title: "Unmonitored Film",
          original_title: nil,
          year: 2020,
          type: "movie",
          monitored: false,
          metadata: %{"overview" => "A test film that is not monitored"}
        })

      {:ok, view, _html} = live(conn, ~p"/movies")

      # Search for "Unmonitored"
      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Unmonitored"})

      # Verify the stream was filtered correctly (should show only Unmonitored Film)
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Unmonitored'][data-stream-count='1']"
             )

      # Apply monitored filter
      view
      |> element("form#library-filter-form")
      |> render_change(%{"monitored" => "true"})

      # Should show 0 items (Unmonitored Film is not monitored)
      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Unmonitored'][data-stream-count='0']"
             )
    end

    test "progress filter narrows movies by downloaded and missing files", %{conn: conn} do
      downloaded_movie =
        media_item_fixture(%{
          title: "Progress Movie Downloaded",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A movie with a local file"}
        })

      media_file_fixture(%{media_item_id: downloaded_movie.id})

      _missing_movie =
        media_item_fixture(%{
          title: "Progress Movie Missing",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A movie without a local file"}
        })

      {:ok, view, _html} = live(conn, ~p"/movies")

      assert has_element?(view, "select[name='progress']")

      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Progress Movie"})

      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Progress Movie'][data-stream-count='2']"
             )

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "downloaded"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='downloaded'][data-stream-count='1']"
             )

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "missing"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='missing'][data-stream-count='1']"
             )
    end

    test "progress filter narrows series by released episode coverage", %{conn: conn} do
      missing_show =
        media_item_fixture(%{
          title: "Progress Show Missing",
          original_title: nil,
          year: 2024,
          type: "tv_show",
          monitored: true,
          metadata: %{"overview" => "A show with no local episodes"}
        })

      episode_fixture(%{
        media_item_id: missing_show.id,
        season_number: 1,
        episode_number: 1,
        air_date: ~D[2024-01-01]
      })

      partial_show =
        media_item_fixture(%{
          title: "Progress Show Partial",
          original_title: nil,
          year: 2024,
          type: "tv_show",
          monitored: true,
          metadata: %{"overview" => "A show with some local episodes"}
        })

      partial_downloaded_episode =
        episode_fixture(%{
          media_item_id: partial_show.id,
          season_number: 1,
          episode_number: 1,
          air_date: ~D[2024-01-01]
        })

      episode_fixture(%{
        media_item_id: partial_show.id,
        season_number: 1,
        episode_number: 2,
        air_date: ~D[2024-01-02]
      })

      media_file_fixture(%{episode_id: partial_downloaded_episode.id})

      downloaded_show =
        media_item_fixture(%{
          title: "Progress Show Downloaded",
          original_title: nil,
          year: 2024,
          type: "tv_show",
          monitored: true,
          metadata: %{"overview" => "A show with every released episode local"}
        })

      downloaded_episode =
        episode_fixture(%{
          media_item_id: downloaded_show.id,
          season_number: 1,
          episode_number: 1,
          air_date: ~D[2024-01-01]
        })

      media_file_fixture(%{episode_id: downloaded_episode.id})

      {:ok, view, _html} = live(conn, ~p"/tv")

      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Progress Show"})

      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Progress Show'][data-stream-count='3']"
             )

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "partial"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='partial'][data-stream-count='1']"
             )

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "downloaded"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='downloaded'][data-stream-count='1']"
             )

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "missing"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='missing'][data-stream-count='1']"
             )
    end

    test "progress filter excludes movies with an active download from missing", %{conn: conn} do
      _missing_movie =
        media_item_fixture(%{
          title: "Progress Grabbing Missing",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A movie with neither file nor download"}
        })

      downloading_movie =
        media_item_fixture(%{
          title: "Progress Grabbing Active",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A movie already being downloaded"}
        })

      download_fixture(%{media_item_id: downloading_movie.id})

      {:ok, view, _html} = live(conn, ~p"/movies")

      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Progress Grabbing"})

      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Progress Grabbing'][data-stream-count='2']"
             )

      # The in-flight movie is :downloading, matching its status badge, so it
      # must not be offered up as something still to grab.
      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "missing"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='missing'][data-stream-count='1']"
             )
    end

    test "progress filter includes unmonitored items on their real availability", %{conn: conn} do
      monitored_movie =
        media_item_fixture(%{
          title: "Progress Monitoring On",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: true,
          metadata: %{"overview" => "A monitored movie with a local file"}
        })

      media_file_fixture(%{media_item_id: monitored_movie.id})

      unmonitored_movie =
        media_item_fixture(%{
          title: "Progress Monitoring Off",
          original_title: nil,
          year: 2024,
          type: "movie",
          monitored: false,
          metadata: %{"overview" => "An unmonitored movie with a local file"}
        })

      media_file_fixture(%{media_item_id: unmonitored_movie.id})

      {:ok, view, _html} = live(conn, ~p"/movies")

      view
      |> element("#library-search-form")
      |> render_change(%{"search" => "Progress Monitoring"})

      assert has_element?(
               view,
               "#test-debug-info[data-search-query='Progress Monitoring'][data-stream-count='2']"
             )

      # Availability and monitoring are separate axes, so a downloaded movie matches the
      # downloaded filter whether or not it is monitored.
      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "downloaded"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='downloaded'][data-stream-count='2']"
             )
    end
  end

  describe "date sorting" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "Added (Newest) puts the most recently added item first across a month boundary", %{
      conn: conn
    } do
      june = media_item_fixture(%{title: "Added June 30", type: "movie"})
      july = media_item_fixture(%{title: "Added July 1", type: "movie"})

      set_inserted_at(june, ~U[2026-06-30 12:00:00Z])
      set_inserted_at(july, ~U[2026-07-01 09:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/movies")

      assert sorted_item_ids(view, "added_desc") == [july.id, june.id]
    end

    test "Added (Oldest) puts the earliest added item first across a month boundary", %{
      conn: conn
    } do
      june = media_item_fixture(%{title: "Added June 30", type: "movie"})
      july = media_item_fixture(%{title: "Added July 1", type: "movie"})

      set_inserted_at(june, ~U[2026-06-30 12:00:00Z])
      set_inserted_at(july, ~U[2026-07-01 09:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/movies")

      assert sorted_item_ids(view, "added_asc") == [june.id, july.id]
    end

    test "Last Aired (Recent) orders shows by their most recent episode air date", %{conn: conn} do
      older = media_item_fixture(%{title: "Aired Long Ago", type: "tv_show"})
      recent = media_item_fixture(%{title: "Aired Recently", type: "tv_show"})

      episode_fixture(%{media_item_id: older.id, air_date: ~D[2020-01-15]})
      episode_fixture(%{media_item_id: recent.id, air_date: ~D[2026-01-15]})

      {:ok, view, _html} = live(conn, ~p"/tv")

      assert sorted_item_ids(view, "last_aired_desc") == [recent.id, older.id]
    end

    test "Next Airing (Soon) orders shows by their next upcoming episode", %{conn: conn} do
      soon = media_item_fixture(%{title: "Airing Soon", type: "tv_show"})
      later = media_item_fixture(%{title: "Airing Later", type: "tv_show"})

      episode_fixture(%{media_item_id: soon.id, air_date: Date.add(Date.utc_today(), 7)})
      episode_fixture(%{media_item_id: later.id, air_date: Date.add(Date.utc_today(), 30)})

      {:ok, view, _html} = live(conn, ~p"/tv")

      assert sorted_item_ids(view, "next_aired_asc") == [soon.id, later.id]
    end

    defp set_inserted_at(media_item, %DateTime{} = at) do
      Mydia.Repo.update_all(
        from(m in Mydia.Media.MediaItem, where: m.id == ^media_item.id),
        set: [inserted_at: at]
      )
    end

    # Picks `sort_by` in the library toolbar and returns the resulting grid item
    # ids in DOM order, stripped back to the bare media item id.
    defp sorted_item_ids(view, sort_by) do
      view
      |> element("form#library-filter-form")
      |> render_change(%{"sort_by" => sort_by})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#media-items > div")
      |> LazyHTML.attribute("id")
      |> Enum.map(&String.replace_prefix(&1, "media_items-", ""))
    end
  end

  describe "batch delete defaults" do
    defp stub_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}},
        private: %{live_temp: %{}}
      }
    end

    test "show_delete_confirmation opens the modal defaulting to deleting files" do
      {:noreply, socket} =
        MydiaWeb.MediaLive.Index.handle_event("show_delete_confirmation", %{}, stub_socket())

      assert socket.assigns.show_delete_modal == true
      assert socket.assigns.delete_files == true
    end
  end

  describe "bulk auto search" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "renders the auto search button disabled until something is selected", %{conn: conn} do
      movie = insert(:media_item, type: "movie")

      {:ok, view, _html} = live(conn, ~p"/movies")

      refute has_element?(view, "#batch-auto-search-btn")

      render_click(view, "toggle_selection_mode", %{})

      assert has_element?(view, "#batch-auto-search-btn")
      assert has_element?(view, "#batch-auto-search-btn[disabled]")

      render_click(view, "toggle_select", %{"id" => movie.id})

      refute has_element?(view, "#batch-auto-search-btn[disabled]")
    end

    test "queues searches for selected items and reports skipped ones", %{conn: conn} do
      needs_search = insert(:media_item, type: "movie", title: "Needs A Search")
      already_have = insert(:media_item, type: "movie", title: "Already Downloaded")
      insert(:media_file, media_item: already_have, episode: nil)

      {:ok, view, _html} = live(conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => needs_search.id})
      render_click(view, "toggle_select", %{"id" => already_have.id})

      view |> element("#batch-auto-search-btn") |> render_click()

      assert view |> element("#flash-info") |> render() =~
               "Queued 1 search, skipped 1 that does not need one"

      assert [job] = Mydia.Repo.all(Oban.Job)
      assert job.worker == "Mydia.Jobs.MovieSearch"
      assert job.args["mode"] == "specific"
      assert job.args["media_item_id"] == needs_search.id
    end

    test "reports when nothing in the selection needs a search", %{conn: conn} do
      already_have = insert(:media_item, type: "movie", title: "Already Downloaded")
      insert(:media_file, media_item: already_have, episode: nil)

      {:ok, view, _html} = live(conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => already_have.id})

      view |> element("#batch-auto-search-btn") |> render_click()

      assert view |> element("#flash-info") |> render() =~ "Nothing to search"
      assert Mydia.Repo.all(Oban.Job) == []
    end

    test "selecting more than the threshold shows a confirmation modal and queues nothing until confirmed",
         %{conn: conn} do
      needs_search = insert(:media_item, type: "movie", title: "Needs A Search")

      {:ok, view, _html} = live(conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => needs_search.id})

      # Real UUIDs for rows that do not exist: `binary_id` is a plain string on
      # SQLite but a genuine uuid column on Postgres, so a synthetic id like
      # "fake-id-1" casts fine on one adapter and raises Ecto.Query.CastError on
      # the other. partition_for_auto_search/1 counts absent ids in neither
      # number, which is what keeps the assertions below stable.
      for _ <- 1..50 do
        render_click(view, "toggle_select", %{"id" => Ecto.UUID.generate()})
      end

      refute has_element?(view, "#auto-search-confirm-modal[open]")

      view |> element("#batch-auto-search-btn") |> render_click()

      assert has_element?(view, "#auto-search-confirm-modal[open]")
      assert Mydia.Repo.all(Oban.Job) == []

      view |> element("#confirm-batch-auto-search-btn") |> render_click()

      refute has_element?(view, "#auto-search-confirm-modal[open]")

      assert view |> element("#flash-info") |> render() =~ "Queued 1 search"
      assert [job] = Mydia.Repo.all(Oban.Job)
      assert job.args["media_item_id"] == needs_search.id
    end

    test "cancelling the confirmation modal queues nothing and keeps the selection", %{
      conn: conn
    } do
      needs_search = insert(:media_item, type: "movie", title: "Needs A Search")

      {:ok, view, _html} = live(conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => needs_search.id})

      # Real UUIDs for rows that do not exist: `binary_id` is a plain string on
      # SQLite but a genuine uuid column on Postgres, so a synthetic id like
      # "fake-id-1" casts fine on one adapter and raises Ecto.Query.CastError on
      # the other. partition_for_auto_search/1 counts absent ids in neither
      # number, which is what keeps the assertions below stable.
      for _ <- 1..50 do
        render_click(view, "toggle_select", %{"id" => Ecto.UUID.generate()})
      end

      view |> element("#batch-auto-search-btn") |> render_click()
      assert has_element?(view, "#auto-search-confirm-modal[open]")

      render_click(view, "cancel_batch_auto_search", %{})

      refute has_element?(view, "#auto-search-confirm-modal[open]")
      assert Mydia.Repo.all(Oban.Job) == []

      # Selection survives the cancel: the toolbar is still in selection mode
      # with the same count shown.
      assert has_element?(view, "#batch-auto-search-btn")
      assert has_element?(view, ".tabular-nums", "51")
    end

    test "denies a user without download permission", %{conn: conn} do
      readonly = user_fixture(%{role: "readonly"})
      conn = log_in_user(conn, readonly)
      movie = insert(:media_item, type: "movie")

      {:ok, view, _html} = live(conn, ~p"/movies")

      render_click(view, "toggle_selection_mode", %{})
      render_click(view, "toggle_select", %{"id" => movie.id})

      view |> element("#batch-auto-search-btn") |> render_click()

      assert view |> element("#flash-error") |> render() =~
               "You do not have permission to manage downloads"

      assert Mydia.Repo.all(Oban.Job) == []
    end
  end
end
