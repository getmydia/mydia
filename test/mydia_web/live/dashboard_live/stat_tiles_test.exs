defmodule MydiaWeb.DashboardLive.StatTilesTest do
  @moduledoc """
  The Storage tile is the reason this file exists. Its destination is
  admin-only, and the stat row renders for every role, so a regression that
  links it unconditionally hands a guest a link into a 403.
  """

  # async: false - the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  setup do
    # Every test here mounts "/", and DashboardLive.Index unconditionally
    # loads both trending rails on connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  test "the library and downloads tiles link for a regular user", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(#stat-tile-movies[href="/movies"]))
    assert has_element?(view, ~s(#stat-tile-tv-shows[href="/tv"]))
    assert has_element?(view, ~s(#stat-tile-downloads[href="/downloads"]))
  end

  test "the storage tile links to library paths for an admin", %{conn: conn} do
    conn = log_in_user(conn, admin_user_fixture())

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s(#stat-tile-storage[href="/admin/config/library-paths"])
           )
  end

  test "the storage tile is not a link for a regular user", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#stat-tile-storage")
    refute has_element?(view, "#stat-tile-storage[href]")
  end

  test "the storage tile is not a link for a guest", %{conn: conn} do
    conn = log_in_user(conn, user_fixture(%{role: "guest"}))

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#stat-tile-storage")
    refute has_element?(view, "#stat-tile-storage[href]")
  end
end
