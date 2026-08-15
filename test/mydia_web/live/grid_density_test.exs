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

    {:ok, _view, html} = live(conn, ~p"/discover")

    assert html =~ "xl:grid-cols-12"
  end
end
