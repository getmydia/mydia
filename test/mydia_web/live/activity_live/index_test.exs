defmodule MydiaWeb.ActivityLive.IndexTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.EventsFixtures
  alias Mydia.Events
  alias Mydia.Events.Presentation

  describe "Activity feed" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)
      %{conn: conn, admin: admin}
    end

    test "renders the activity page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Activity Feed"
      assert html =~ "Recent events and system activity"
    end

    test "shows empty state when no events exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "No events found"
      assert html =~ "Events will appear here as activity happens"
    end

    test "displays events in reverse chronological order", %{conn: conn} do
      # Create test events
      {:ok, _event1} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user",
          metadata: %{"title" => "Test Movie 1", "media_type" => "movie"}
        })

      {:ok, _event2} =
        Events.create_event(%{
          category: "downloads",
          type: "download.initiated",
          actor_type: :system,
          actor_id: "system",
          metadata: %{"title" => "Test Download"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      # Should show both events
      assert html =~ "Test Movie 1"
      assert html =~ "Test Download"
    end

    test "filters events by category", %{conn: conn} do
      # Create events in different categories
      {:ok, _media_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user",
          metadata: %{"title" => "Test Movie", "media_type" => "movie"}
        })

      {:ok, _download_event} =
        Events.create_event(%{
          category: "downloads",
          type: "download.initiated",
          actor_type: :system,
          actor_id: "system",
          metadata: %{"title" => "Test Download"}
        })

      {:ok, view, html} = live(conn, ~p"/activity")

      # Initially shows all events
      assert html =~ "Test Movie"
      assert html =~ "Test Download"

      # Filter by media category
      html =
        view
        |> element("button", "Media")
        |> render_click()

      assert html =~ "Test Movie"
      refute html =~ "Test Download"

      # Filter by downloads category
      html =
        view
        |> element("button", "Downloads")
        |> render_click()

      refute html =~ "Test Movie"
      assert html =~ "Test Download"
    end

    test "receives real-time event updates via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      # Create a new event (should be broadcast via PubSub)
      {:ok, _event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user",
          metadata: %{"title" => "New Movie", "media_type" => "movie"}
        })

      # Poll the view until the event appears (handles PubSub delivery timing)
      # Retry up to 10 times with 50ms between attempts (500ms total max wait)
      html =
        Enum.reduce_while(1..10, nil, fn _attempt, _acc ->
          html = render(view)

          if html =~ "New Movie" && html =~ "Added to library: New Movie (movie)" do
            {:halt, html}
          else
            Process.sleep(50)
            {:cont, html}
          end
        end)

      # The view should have received the update and re-rendered with the event
      assert html =~ "New Movie"
      assert html =~ "Added to library: New Movie (movie)"
    end

    test "formats event descriptions correctly", %{conn: conn} do
      # Test media_item.added
      {:ok, _} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user",
          metadata: %{"title" => "Inception", "media_type" => "movie"}
        })

      # Test download.completed
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "download_monitor",
          metadata: %{"title" => "Test.File.mkv"}
        })

      # Test download.failed
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.failed",
          actor_type: :system,
          actor_id: "download_monitor",
          severity: :error,
          metadata: %{"title" => "Failed.File.mkv", "error_message" => "Connection timeout"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      # Check formatted descriptions
      assert html =~ "Added to library: Inception (movie)"
      assert html =~ "Download completed: Test.File.mkv"
      assert html =~ "Download failed: Failed.File.mkv"
      assert html =~ "Connection timeout"
    end

    test "displays severity badges for warnings and errors", %{conn: conn} do
      # Create error event
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.failed",
          actor_type: :system,
          actor_id: "download_monitor",
          severity: :error,
          metadata: %{"title" => "Failed Download", "error_message" => "Error"}
        })

      # Create warning event
      {:ok, _} =
        Events.create_event(%{
          category: "system",
          type: "job.failed",
          actor_type: :job,
          actor_id: "test_job",
          severity: :warning,
          metadata: %{"job_name" => "test_job", "error_message" => "Warning"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      # Should show severity badges
      assert html =~ "error"
      assert html =~ "warning"
    end

    test "shows relative timestamps", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user",
          metadata: %{"title" => "Recent Movie", "media_type" => "movie"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      # Should show "just now" or similar relative time
      assert html =~ ~r/(just now|minutes ago|seconds ago)/
    end

    test "handles category filter tabs correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      # Check all category tabs exist
      assert has_element?(view, "button", "All")
      assert has_element?(view, "button", "Media")
      assert has_element?(view, "button", "Downloads")
      assert has_element?(view, "button", "Search")
      assert has_element?(view, "button", "System")
      assert has_element?(view, "button", "Errors")
    end

    test "an admin keeps every chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      for category <- ~w(all media downloads search system playback plugin errors) do
        assert has_element?(view, "button[phx-value-category='#{category}']"),
               "#{category} chip is missing for an admin"
      end
    end

    test "labels every feed-visible event type instead of printing its key", %{conn: conn} do
      types = Presentation.known_types() -- Presentation.feed_hidden_types()

      for type <- types do
        {:ok, _} =
          Events.create_event(%{
            category: category_for_type(type),
            type: type,
            actor_type: :system,
            actor_id: "test",
            metadata: %{"title" => "Fixture Title"}
          })
      end

      {:ok, _view, html} = live(conn, ~p"/activity")

      for type <- types do
        refute html =~ ">#{type}<", "#{type} rendered as a raw key"
      end
    end

    test "renders a stalled download with a human label", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.stalled",
          actor_type: :system,
          actor_id: "download_monitor",
          severity: :warning,
          metadata: %{"title" => "Arrival 2160p", "message" => "no progress for 2h"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Download stalled: Arrival 2160p (no progress for 2h)"
      refute html =~ "download.stalled"
    end

    test "excludes the plugin request audit trail from the feed", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.http_request",
          actor_type: :system,
          actor_id: "tmdb-art",
          metadata: %{
            "slug" => "tmdb-art",
            "method" => "GET",
            "host" => "api.themoviedb.org",
            "status" => 200
          }
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      refute html =~ "api.themoviedb.org"
      assert html =~ "No events found"
    end

    test "excludes the plugin request audit trail from live inserts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      {:ok, event} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.http_request",
          actor_type: :system,
          actor_id: "tmdb-art",
          metadata: %{
            "slug" => "tmdb-art",
            "method" => "GET",
            "host" => "api.themoviedb.org",
            "status" => 200
          }
        })

      send(view.pid, {:event_created, event})

      refute render(view) =~ "api.themoviedb.org"
    end

    test "offers a playback filter chip that filters to playback events", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "playback",
          type: "playback.finished",
          actor_type: :user,
          actor_id: "someone",
          metadata: %{"completion_percentage" => 98, "origin" => "player"}
        })

      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "system",
          metadata: %{"title" => "Arrival"}
        })

      {:ok, view, _html} = live(conn, ~p"/activity")

      html =
        view
        |> element("button[phx-value-category='playback']")
        |> render_click()

      assert html =~ "Playback finished"
      refute html =~ "Arrival"
    end

    test "offers a plugins filter chip", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.update_available",
          actor_type: :system,
          actor_id: "tmdb-art",
          metadata: %{
            "slug" => "tmdb-art",
            "current_version" => "1.0.0",
            "latest_version" => "1.2.0"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/activity")

      html =
        view
        |> element("button[phx-value-category='plugin']")
        |> render_click()

      assert html =~ "Plugin update available: tmdb-art 1.0.0 to 1.2.0"
    end
  end

  describe "Activity feed as a guest" do
    setup %{conn: conn} do
      guest = user_fixture(%{role: "guest"})
      other = user_fixture(%{role: "guest"})

      %{conn: log_in_user(conn, guest), guest: guest, other: other}
    end

    test "shows media additions and removals", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :system,
          actor_id: "media_context",
          metadata: %{"title" => "Paddington", "media_type" => "movie"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Added to library: Paddington (movie)"
    end

    test "shows the guest's own playback", %{conn: conn, guest: guest} do
      {:ok, _} =
        Events.create_event(%{
          category: "playback",
          type: "playback.started",
          actor_type: :user,
          actor_id: guest.id,
          metadata: %{"origin" => "this-guests-player"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "this-guests-player"
    end

    test "hides another user's playback", %{conn: conn, other: other} do
      {:ok, _} =
        Events.create_event(%{
          category: "playback",
          type: "playback.started",
          actor_type: :user,
          actor_id: other.id,
          metadata: %{"origin" => "someone-elses-player"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      refute html =~ "someone-elses-player"
      assert html =~ "No events found"
    end

    test "hides the guest's own progressed and paused events", %{conn: conn, guest: guest} do
      for {type, origin} <- [
            {"playback.progressed", "progress-noise"},
            {"playback.paused", "pause-noise"}
          ] do
        {:ok, _} =
          Events.create_event(%{
            category: "playback",
            type: type,
            actor_type: :user,
            actor_id: guest.id,
            metadata: %{"origin" => origin}
          })
      end

      {:ok, _view, html} = live(conn, ~p"/activity")

      refute html =~ "progress-noise"
      refute html =~ "pause-noise"
    end

    test "hides downloads, search, jobs and file operations", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "download_monitor",
          metadata: %{"title" => "Hidden.Download.mkv"}
        })

      {:ok, _} =
        Events.create_event(%{
          category: "search",
          type: "search.completed",
          actor_type: :system,
          actor_id: "search_service",
          metadata: %{"title" => "Hidden Search"}
        })

      {:ok, _} =
        Events.create_event(%{
          category: "system",
          type: "job.failed",
          actor_type: :job,
          actor_id: "hidden_job",
          severity: :error,
          metadata: %{"job_name" => "hidden_job", "error_message" => "Hidden Error"}
        })

      {:ok, _} =
        Events.create_event(%{
          category: "media",
          type: "media_file.imported",
          actor_type: :system,
          actor_id: "file_ingest",
          metadata: %{"title" => "Hidden.Import.mkv"}
        })

      {:ok, _view, html} = live(conn, ~p"/activity")

      refute html =~ "Hidden.Download.mkv"
      refute html =~ "Hidden Search"
      refute html =~ "Hidden Error"
      refute html =~ "Hidden.Import.mkv"
      assert html =~ "No events found"
    end

    test "a hidden event arriving over PubSub is not inserted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      {:ok, _hidden} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "download_monitor",
          metadata: %{"title" => "Hidden.Live.mkv"}
        })

      {:ok, _visible} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :system,
          actor_id: "media_context",
          metadata: %{"title" => "Visible Live Movie", "media_type" => "movie"}
        })

      # Both broadcasts reach this LiveView in order on the same topic, so once
      # the second has rendered the first has already been handled. That makes
      # the refute below a real assertion rather than a race against a sleep.
      html =
        Enum.reduce_while(1..20, nil, fn _attempt, _acc ->
          html = render(view)

          if html =~ "Visible Live Movie" do
            {:halt, html}
          else
            Process.sleep(50)
            {:cont, html}
          end
        end)

      assert html =~ "Visible Live Movie"
      refute html =~ "Hidden.Live.mkv"
    end

    test "an admin's feed is unchanged", %{conn: conn} do
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "download_monitor",
          metadata: %{"title" => "Admin.Visible.mkv"}
        })

      admin_conn = log_in_user(conn, admin_user_fixture())
      {:ok, _view, html} = live(admin_conn, ~p"/activity")

      assert html =~ "Admin.Visible.mkv"
    end

    test "shows only the chips that can match", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/activity")

      for category <- ~w(all media playback) do
        assert has_element?(view, "button[phx-value-category='#{category}']"),
               "#{category} chip is missing"
      end

      for category <- ~w(downloads search system plugin errors) do
        refute has_element?(view, "button[phx-value-category='#{category}']"),
               "#{category} chip can never match but is still rendered"
      end
    end

    test "the media chip still filters", %{conn: conn, guest: guest} do
      {:ok, _} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :system,
          actor_id: "media_context",
          metadata: %{"title" => "Paddington", "media_type" => "movie"}
        })

      {:ok, _} =
        Events.create_event(%{
          category: "playback",
          type: "playback.started",
          actor_type: :user,
          actor_id: guest.id,
          metadata: %{"origin" => "this-guests-player"}
        })

      {:ok, view, _html} = live(conn, ~p"/activity")

      html =
        view
        |> element("button[phx-value-category='media']")
        |> render_click()

      assert html =~ "Paddington"
      refute html =~ "this-guests-player"
    end
  end
end
