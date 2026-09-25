defmodule MydiaWeb.GridDensityTest do
  @moduledoc """
  Density is a per-browser setting carried by the `mydia_grid_density`
  cookie. These tests drive it the way a browser does: a cookie on the
  request, and a toggle click that must push the value back for the
  `GridDensity` hook to store.
  """

  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Accounts

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list and its
    # default (trending) category on connected mount (#530).
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "libraries grid defaults to comfortable columns", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/movies")

    assert html =~ "grid-cols-2 sm:grid-cols-3"
  end

  test "the browser's cookie picks the libraries columns, phone included", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> put_req_cookie("mydia_grid_density", "dense")
      |> live(~p"/movies")

    assert html =~ "grid-cols-4 sm:grid-cols-6"
  end

  test "the browser's cookie picks discover's density", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_req_cookie("mydia_grid_density", "dense")
      |> live(~p"/discover")

    # Asserts on the toolbar toggle, not the grid. Discover's grid sits behind
    # an async metadata-relay fetch, so the first connected render is always
    # the loading spinner and no grid class exists yet. The toggle renders
    # from @grid_density on mount, so it proves the session value was read.
    assert has_element?(
             view,
             "#discover-density-toggle button[phx-value-density='dense'].btn-primary"
           )
  end

  test "choosing a density re-renders and asks the browser to store it", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/movies")

    html =
      view
      |> element("#library-density-toggle button[phx-value-density='compact']")
      |> render_click()

    assert html =~ "grid-cols-3 sm:grid-cols-4"
    assert_push_event(view, "grid_density:saved", %{density: "compact"})

    # Per-browser, so nothing account-wide is written.
    refute Map.has_key?(Accounts.get_user_preference!(user).preferences, "grid_density")
  end

  test "an unknown density is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies")

    html = render_hook(view, "set_grid_density", %{"density" => "tiny"})

    assert html =~ "grid-cols-2 sm:grid-cols-3"
    refute_push_event(view, "grid_density:saved", %{})
  end

  test "discover groups the density toggle with the media-type join", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    # The row is sm:justify-between with three children. Once the density
    # toggle shrank to icons, an ungrouped middle child floats in dead centre.
    # Asserting the toggle is inside the cluster keeps that grouping from
    # being undone by a later edit to the toolbar.
    assert has_element?(view, "#discover-view-controls #discover-density-toggle")
  end
end
