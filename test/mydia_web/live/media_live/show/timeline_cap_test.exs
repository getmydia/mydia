defmodule MydiaWeb.MediaLive.Show.TimelineCapTest do
  @moduledoc """
  The rail renders at most five events collapsed. That cap is not cosmetic:
  it is what keeps the rail shorter than the viewport, which is the only
  condition under which its `sticky` pins instead of sliding off the top.
  """

  # Connected LiveView tests cannot be async under the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Events
  alias MydiaWeb.MediaLive.Show.Components

  defp fake_events(n) do
    for i <- 1..n do
      %{
        icon: "hero-arrow-down-tray",
        color: "text-success",
        title: "Fixture Event #{i}",
        description: "Fixture Description #{i}",
        timestamp: DateTime.add(DateTime.utc_now(), -i * 3600, :second),
        metadata: nil
      }
    end
  end

  describe "timeline_section/1" do
    test "renders at most five events when collapsed" do
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: fake_events(9),
          expanded: false
        )

      assert html =~ "Fixture Event 5"
      refute html =~ "Fixture Event 6"
    end

    test "renders every event it was given when expanded" do
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: fake_events(9),
          expanded: true
        )

      assert html =~ "Fixture Event 9"
    end

    test "the control counts what is hidden, not the total" do
      # load_timeline_events/2 caps its query at 50, so "Show all" would be a
      # lie on an item with more history than that.
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: fake_events(9),
          expanded: false
        )

      assert html =~ "Show 4 more"
    end

    test "the control reads Show less when expanded" do
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: fake_events(9),
          expanded: true
        )

      assert html =~ "Show less"
    end

    test "there is no control at all when nothing is hidden" do
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: fake_events(5),
          expanded: false
        )

      refute html =~ ~s(id="timeline-toggle")
    end

    test "renders nothing for an item with no events" do
      html =
        render_component(&Components.timeline_section/1,
          timeline_events: [],
          expanded: false
        )

      refute html =~ ~s(id="timeline-section")
    end
  end

  describe "toggling from the page" do
    setup do
      # The app disables Oban in test (engine: false), so Oban.insert cannot
      # run from the LiveView process. Start an isolated, manual-mode instance
      # so the recommendations load can enqueue without a live queue.
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

      :ok
    end

    test "the toggle reveals the rest and collapses again", %{conn: conn} do
      show = seed_show()

      # media_item_fixture goes through Media.create_media_item/2, which records
      # one media_item.added event, so eight more makes nine.
      for i <- 1..8, do: completed_download(show, "Fixture Release #{i}")

      conn = log_in_user(conn, admin_user_fixture())

      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
      render_async(view, 5000)

      assert render(view) =~ "Show 4 more"

      expanded = view |> element("#timeline-toggle") |> render_click()
      assert expanded =~ "Show less"

      collapsed = view |> element("#timeline-toggle") |> render_click()
      assert collapsed =~ "Show 4 more"
    end
  end

  defp seed_show do
    tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Fixture Rail Show",
        year: 2014,
        tmdb_id: tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    # Unwarmed, the recommendations load leaves the VM for the production
    # metadata relay during tests.
    warm_recommendations_cache(tmdb_id, :tv_show, [])

    show
  end

  defp completed_download(show, title) do
    {:ok, event} =
      Events.create_event(%{
        category: "downloads",
        type: "download.completed",
        actor_type: :system,
        actor_id: "test",
        resource_type: "media_item",
        resource_id: show.id,
        metadata: %{"title" => title}
      })

    event
  end
end
