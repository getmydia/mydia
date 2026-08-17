defmodule MydiaWeb.GridDensityTest do
  @moduledoc """
  Density is one preference shared by two pages. The cross-page test is the
  point: it fails if either LiveView keeps density in socket state instead of
  reading the stored preference on mount.
  """

  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "libraries grid defaults to comfortable columns", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/movies")

    assert html =~ "xl:grid-cols-6"
  end

  test "choosing dense re-renders the libraries grid and persists", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/movies")

    html =
      view
      |> element("#library-density-toggle button[phx-value-density='dense']")
      |> render_click()

    assert html =~ "xl:grid-cols-12"

    assert user
           |> Accounts.get_user_preference!()
           |> UserPreference.grid_density() == "dense"
  end

  test "the density chosen on libraries applies on discover", %{conn: conn, user: user} do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{"grid_density" => "dense"})

    {:ok, view, _html} = live(conn, ~p"/discover")

    # Asserts on the toolbar toggle, not the grid. Discover's grid sits behind
    # an async metadata-relay fetch, so the first connected render is always
    # the loading spinner and no grid class exists yet; asserting there would
    # also make this test depend on a live external call, which
    # test_helper.exs excludes by tag elsewhere. The density toggle in
    # discover_live/index.html.heex renders from @grid_density on mount, so it
    # proves the stored preference was read without any network dependency.
    assert has_element?(
             view,
             "#discover-density-toggle button[phx-value-density='dense'].btn-primary"
           )
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
