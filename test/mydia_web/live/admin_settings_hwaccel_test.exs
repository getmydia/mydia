defmodule MydiaWeb.AdminSettingsHwaccelTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  test "the streaming section reports the hardware status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    assert has_element?(view, "#hwaccel-status")
  end

  test "explains why acceleration is unavailable rather than only that it is", %{conn: conn} do
    # With no probe running in test, capabilities/0 reports software with a
    # reason. An operator must be able to tell "no GPU" from "driver missing"
    # from "you turned it off" without reading logs.
    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    assert render(view) =~ "not running"
  end
end
