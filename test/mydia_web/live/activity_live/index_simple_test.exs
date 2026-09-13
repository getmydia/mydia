defmodule MydiaWeb.ActivityLive.IndexSimpleTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  test "admin can access activity page", %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user_session(conn, admin)

    {:ok, _view, html} = live(conn, ~p"/activity")
    assert html =~ "Activity Feed"
  end
end
