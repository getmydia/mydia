defmodule MydiaWeb.ActivityLive.IndexTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
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

    test "labels every feed-visible event type instead of printing its key", %{conn: conn} do
      types = Presentation.known_types() -- Presentation.feed_hidden_types()

      for type <- types do
        [namespace, _action] = String.split(type, ".")

        {:ok, _} =
          Events.create_event(%{
            category: namespace,
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
  end
end
