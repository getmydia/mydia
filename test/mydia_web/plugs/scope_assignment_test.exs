defmodule MydiaWeb.Plugs.ScopeAssignmentTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope

  test "an authenticated browser request carries a Scope struct", %{conn: conn} do
    user = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/movies")

    assert %Scope{} = conn.assigns.current_scope
    assert conn.assigns.current_scope.allowed_categories == ["cartoon_movie"]
  end

  test "an authenticated API request carries a Scope struct", %{conn: conn} do
    user = restricted_user_fixture(%{max_content_age: 7})

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/api/v1/indexers")

    assert %Scope{max_content_age: 7} = conn.assigns.current_scope
  end

  test "an admin request carries an unrestricted scope", %{conn: conn} do
    conn =
      conn
      |> log_in_user(admin_user_fixture())
      |> get(~p"/movies")

    refute Scope.restricted?(conn.assigns.current_scope)
  end
end
