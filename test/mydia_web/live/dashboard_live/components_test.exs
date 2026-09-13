defmodule MydiaWeb.DashboardLive.ComponentsTest do
  use MydiaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias MydiaWeb.DashboardLive.Components
  alias MydiaWeb.DashboardLive.HealthComponents
  alias MydiaWeb.DashboardLive.EditHomeComponents
  alias Mydia.Health.Rollup
  alias Mydia.Accounts.HomeLayout.Widget

  test "quick_action_card renders link with title and description" do
    html =
      render_component(&Components.quick_action_card/1,
        id: "qa-add-movie",
        navigate: "/discover?type=movie",
        icon: "hero-film",
        title: "Add Movie",
        description: "Search and add movies",
        color: "primary"
      )

    assert html =~ "Add Movie"
    assert html =~ "Search and add movies"
    assert html =~ ~s(href="/discover?type=movie")
    assert html =~ "hero-film"
  end

  test "quick_action_card renders badge and border class when provided" do
    html =
      render_component(&Components.quick_action_card/1,
        id: "qa-badge-test",
        navigate: "/test",
        icon: "hero-star",
        title: "Starred",
        description: "Starred items",
        color: "warning",
        badge: "3 pending",
        border_class: "border-warning"
      )

    assert html =~ "3 pending"
    assert html =~ "border-warning"
  end

  test "health_tile renders with AdminNav metadata and rollup label" do
    rollup = %Rollup{healthy: 2, unhealthy: 0, unknown: 0, total: 2, state: :ok}

    html =
      render_component(&HealthComponents.health_tile/1,
        nav_key: :clients,
        rollup: rollup
      )

    assert html =~ "Clients"
    assert html =~ "2/2 healthy"
    assert html =~ ~s(href="/admin/clients")
  end

  test "health_tile renders FlareSolverr subline when enabled" do
    rollup = %Rollup{healthy: 3, unhealthy: 0, unknown: 0, total: 3, state: :ok}

    html =
      render_component(&HealthComponents.health_tile/1,
        nav_key: :indexers,
        rollup: rollup,
        flaresolverr_enabled: true,
        flaresolverr_status: :healthy
      )

    assert html =~ "Indexers"
    assert html =~ "FlareSolverr: ok"
  end

  test "system_health_widget renders service tiles, duplicates, and trash" do
    clients_rollup = %Rollup{healthy: 2, unhealthy: 0, unknown: 0, total: 2, state: :ok}
    indexers_rollup = %Rollup{healthy: 1, unhealthy: 1, unknown: 0, total: 2, state: :degraded}
    media_servers_rollup = %Rollup{healthy: 0, unhealthy: 1, unknown: 0, total: 1, state: :down}
    trash_summary = %{count: 4, bytes: 2_147_483_648}

    html =
      render_component(&HealthComponents.system_health_widget/1,
        clients_rollup: clients_rollup,
        indexers_rollup: indexers_rollup,
        media_servers_rollup: media_servers_rollup,
        duplicates_state: :review,
        duplicates_count: 5,
        trash_summary: trash_summary,
        flaresolverr_enabled: true,
        flaresolverr_status: :unhealthy
      )

    assert html =~ "System Health"
    assert html =~ "Clients"
    assert html =~ "Indexers"
    assert html =~ "Media Servers"
    assert html =~ "5 to review"
    assert html =~ "4 files · 2.0 GB"
    assert html =~ "FlareSolverr: down"
  end

  test "system_health_widget hides tiles with :none state and handles empty trash" do
    empty_rollup = %Rollup{healthy: 0, unhealthy: 0, unknown: 0, total: 0, state: :none}
    trash_summary = %{count: 0, bytes: 0}

    html =
      render_component(&HealthComponents.system_health_widget/1,
        clients_rollup: empty_rollup,
        indexers_rollup: empty_rollup,
        media_servers_rollup: empty_rollup,
        duplicates_state: :none,
        duplicates_count: 0,
        trash_summary: trash_summary
      )

    refute html =~ "health-tile-clients"
    refute html =~ "health-tile-indexers"
    refute html =~ "health-tile-media-servers"
    assert html =~ "health-tile-duplicates"
    assert html =~ "None"
    assert html =~ "health-tile-trash"
    assert html =~ "Empty"
  end

  test "edit_home_modal renders visible widgets, hidden divider, and action buttons" do
    visible = [
      %Widget{
        key: :library_stats,
        label: "Library stats",
        description: "Stats description",
        roles: :all,
        default?: true
      },
      %Widget{
        key: :quick_actions,
        label: "Quick actions",
        description: "Shortcuts description",
        roles: :all,
        default?: true
      }
    ]

    hidden = [
      %Widget{
        key: :trending_tv,
        label: "Trending TV shows",
        description: "Trending TV description",
        roles: :all,
        default?: false
      }
    ]

    html =
      render_component(&EditHomeComponents.edit_home_modal/1,
        editing_home: true,
        visible_widgets: visible,
        hidden_widgets: hidden
      )

    assert html =~ "Customize Home"
    assert html =~ "Library stats"
    assert html =~ "Quick actions"
    assert html =~ "Hidden"
    assert html =~ "Trending TV shows"
    assert html =~ "Reset to default"
    assert html =~ "Done"
    assert html =~ ~s(aria-label="Move Library stats up")
    assert html =~ ~s(aria-label="Move Quick actions down")
  end
end
