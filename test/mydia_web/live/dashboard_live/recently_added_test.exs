defmodule MydiaWeb.DashboardLive.RecentlyAddedTest do
  @moduledoc """
  The ordering assertion is the requirement from issue #466: the dashboard
  should lead with library content rather than with external trending content.
  """

  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "omits the rail entirely on an empty library", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#recently-added-rail")
  end

  test "shows a movie whose file just arrived", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Arrival"})
    media_file_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#recently-added-rail")
    assert has_element?(view, "#recently-added-rail-item-#{movie.id}")
  end

  test "shows a TV show whose file hangs off an episode", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Severance"})
    episode = episode_fixture(%{media_item_id: show.id})
    media_file_fixture(%{episode_id: episode.id})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#recently-added-rail-item-#{show.id}")
  end

  test "omits a title whose only file arrived outside the 30 day window", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Stale"})

    %{media_item_id: movie.id}
    |> media_file_fixture()
    |> backdate_media_file(~U[2024-01-01 00:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#recently-added-rail-item-#{movie.id}")
  end

  test "places the rail above the trending sections", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Arrival"})
    media_file_fixture(%{media_item_id: movie.id})

    {:ok, _view, html} = live(conn, ~p"/")

    rail_at = :binary.match(html, "recently-added-rail") |> elem(0)
    trending_at = :binary.match(html, "Trending Movies") |> elem(0)

    assert rail_at < trending_at
  end
end
