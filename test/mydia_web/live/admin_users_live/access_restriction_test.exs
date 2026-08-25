defmodule MydiaWeb.AdminUsersLive.AccessRestrictionTest do
  # Connected LiveView tests cannot be async on the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Mydia.Accounts

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "opens the access modal for a non-admin user", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#open-access-#{user.id}") |> render_click()

    assert has_element?(view, "#access-modal")
  end

  test "offers no access action for an admin row", %{conn: conn} do
    admin = admin_user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    refute has_element?(view, "#open-access-#{admin.id}")
  end

  test "saves a category and rating restriction", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#open-access-#{user.id}") |> render_click()

    view
    |> element("#access-form")
    |> render_submit(%{
      "access" => %{"allowed_categories" => ["cartoon_movie"], "max_content_age" => "7"}
    })

    restriction = Accounts.get_access_restriction(user)

    assert restriction.allowed_categories == ["cartoon_movie"]
    assert restriction.max_content_age == 7
  end

  test "clearing the restriction removes the row", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#open-access-#{user.id}") |> render_click()
    view |> element("#clear-access") |> render_click()

    assert Accounts.get_access_restriction(user) == nil
  end

  test "shows how many items are unrated, since a limit hides them", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#open-access-#{user.id}") |> render_click()

    assert has_element?(view, "#unrated-count")
  end

  test "a non-numeric max_content_age does not crash the LiveView and sets no limit",
       %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#open-access-#{user.id}") |> render_click()

    view
    |> element("#access-form")
    |> render_submit(%{
      "access" => %{"allowed_categories" => [], "max_content_age" => "not-a-number"}
    })

    assert Process.alive?(view.pid)

    restriction = Accounts.get_access_restriction(user)

    assert is_nil(restriction) || is_nil(restriction.max_content_age)
  end
end
