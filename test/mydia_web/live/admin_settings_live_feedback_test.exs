defmodule MydiaWeb.AdminSettingsLiveFeedbackTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.{Accounts, Settings}

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, admin} =
      Accounts.create_user(%{
        email: "feedback_admin_#{unique_id}@example.com",
        username: "feedback_admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, user} =
      Accounts.create_user(%{
        email: "feedback_user_#{unique_id}@example.com",
        username: "feedback_user_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "user"
      })

    {:ok, admin_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(admin)
    {:ok, user_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    admin_conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, admin_token)
      |> put_req_header("authorization", "Bearer #{admin_token}")

    user_conn =
      build_conn()
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, user_token)
      |> put_req_header("authorization", "Bearer #{user_token}")

    %{admin_conn: admin_conn, user_conn: user_conn}
  end

  test "admin sees feedback toggle on by default", %{admin_conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/config/settings")

    assert html =~ "Feedback"
    assert html =~ "Show Send feedback button"

    assert has_element?(
             view,
             "input[type='checkbox'][phx-value-key='feedback.enabled'][checked]"
           )
  end

  test "admin can toggle feedback off and setting persists", %{admin_conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    html =
      view
      |> element("input[type='checkbox'][phx-value-key='feedback.enabled']")
      |> render_click()

    assert html =~ "Setting updated successfully"

    setting = Settings.get_config_setting_by_key("feedback.enabled")
    assert setting.value == "false"
    assert setting.category == :feedback
  end

  test "remount shows feedback toggle off after it is disabled", %{admin_conn: conn} do
    {:ok, _setting} =
      Settings.create_config_setting(%{
        key: "feedback.enabled",
        value: "false",
        category: :feedback
      })

    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    refute has_element?(
             view,
             "input[type='checkbox'][phx-value-key='feedback.enabled'][checked]"
           )
  end

  test "non-admin users are redirected away from admin settings", %{user_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/config/settings")
  end

  test "toggle off propagates to other authenticated LiveViews", %{admin_conn: conn} do
    {:ok, _setting} =
      Settings.create_config_setting(%{
        key: "feedback.enabled",
        value: "false",
        category: :feedback
      })

    # DashboardLive.Index unconditionally loads both trending rails on
    # connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "phx-click=\"open_feedback_modal\""
  end
end
