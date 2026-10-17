defmodule MydiaWeb.AdminSettingsLiveUpdateCheckTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.{Accounts, Settings}

  @toggle "input[type='checkbox'][phx-value-key='update_check.enabled']"

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, admin} =
      Accounts.create_user(%{
        email: "update_check_admin_#{unique_id}@example.com",
        username: "update_check_admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(admin)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  test "the update check toggle is on by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#setting-update_check-enabled", "Check for updates")
    assert has_element?(view, @toggle <> "[checked]")
  end

  test "turning it off persists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    view |> element(@toggle) |> render_click()

    assert %{value: "false", category: :general} =
             Settings.get_config_setting_by_key("update_check.enabled")

    refute Mydia.UpdateCheck.enabled?(fn _ -> nil end)
  end
end
