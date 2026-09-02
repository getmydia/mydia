defmodule MydiaWeb.DiscoverLive.LoadingSkeletonTest do
  @moduledoc """
  Discover sets @loading true in mount/3 outside any connected?/1 check, so the
  disconnected render always shows the loading branch. That is the one fully
  deterministic place to assert the skeleton, and it is why the first test here
  uses get/2 rather than live/2.

  Asserting via has_element?/2 would not work: it re-renders, which drains the
  LiveView mailbox and returns the post-load state.
  """

  # async: false - the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list and its
    # default (trending) category on connected mount (#530).
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "the disconnected render shows the skeleton, not a spinner", %{conn: conn} do
    doc =
      conn
      |> get(~p"/discover")
      |> html_response(200)
      |> LazyHTML.from_document()

    refute doc |> LazyHTML.query("#discover-grid-skeleton") |> Enum.empty?()
    assert doc |> LazyHTML.query("#discover-grid") |> Enum.empty?()
  end

  test "the skeleton grid follows the stored density preference", %{conn: conn} do
    doc =
      conn
      |> get(~p"/discover")
      |> html_response(200)
      |> LazyHTML.from_document()

    [class] = doc |> LazyHTML.query("#discover-grid-skeleton") |> LazyHTML.attribute("class")

    # The comfortable default, identical to the real results grid's own
    # grid_columns_class(@grid_density) output.
    assert class =~ "xl:grid-cols-6"
  end

  test "the first connected render still shows the skeleton", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/discover")

    doc = LazyHTML.from_document(html)

    refute doc |> LazyHTML.query("#discover-grid-skeleton") |> Enum.empty?()
  end

  test "the skeleton is gone once results land", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    # has_element?/2 re-renders, which processes the queued load message first,
    # so this observes the settled state rather than the mount render.
    refute has_element?(view, "#discover-grid-skeleton")
  end
end
