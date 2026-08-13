defmodule MydiaWeb.MediaLive.Show.MonitoringControlsTest do
  @moduledoc """
  Tests the split monitoring controls: a show-level monitored toggle, a
  one-shot episode monitoring menu, and the new-seasons rule.
  """
  # async: false — connected LiveView tests hit the Postgres non-shared sandbox,
  # which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  test "a tv show exposes both a monitored toggle and an episode monitoring menu", %{conn: conn} do
    media_item = media_item_fixture(%{type: "tv_show", monitored: true})

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      monitored: true
    )

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#show-monitored-toggle")
    assert has_element?(view, "#episode-monitoring-menu")
    assert has_element?(view, "#monitor-new-seasons-all")
  end

  test "applying a preset rewrites episode monitoring", %{conn: conn} do
    media_item = media_item_fixture(%{type: "tv_show", monitored: true})

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      monitored: true
    )

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    view
    |> element("#episode-monitoring-menu-preset-none")
    |> render_click()

    refute Mydia.Media.get_episode_by_number(media_item.id, 1, 1).monitored
  end

  test "the new seasons toggle persists", %{conn: conn} do
    media_item = media_item_fixture(%{type: "tv_show", monitored: true})

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      monitored: true
    )

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    view |> element("#monitor-new-seasons-none") |> render_click()

    assert Mydia.Media.get_media_item!(media_item.id).monitor_new_seasons == :none
  end

  test "a fully monitored season offers to unmonitor, a partial one offers to monitor", %{
    conn: conn
  } do
    media_item = media_item_fixture(%{type: "tv_show", monitored: true})

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      monitored: true
    )

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 2,
      episode_number: 1,
      monitored: true
    )

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 2,
      episode_number: 2,
      monitored: false
    )

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#season-1-monitor-toggle[phx-click='unmonitor_season']")
    assert has_element?(view, "#season-2-monitor-toggle[phx-click='monitor_season']")
  end

  test "a fully unmonitored season is de-emphasised and offers to monitor", %{conn: conn} do
    # The :none branch of season_monitoring_state/1 and monitoring_icon/1. It is
    # the state a user lands in right after unmonitoring a whole season, which
    # is the case this whole change exists to fix, so it should not be the one
    # state nothing renders in a test.
    media_item = media_item_fixture(%{type: "tv_show", monitored: true})

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 3,
      episode_number: 1,
      monitored: false
    )

    episode_fixture(
      media_item_id: media_item.id,
      season_number: 3,
      episode_number: 2,
      monitored: false
    )

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    assert has_element?(view, "#season-3-monitor-toggle[phx-click='monitor_season']")
    assert has_element?(view, "#season-3-monitor-toggle.opacity-60")
  end
end
