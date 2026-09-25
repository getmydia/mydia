defmodule MydiaWeb.AdminUsersLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    admin = admin_user_fixture(%{username: "installer"})
    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(admin)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, admin: admin}
  end

  describe "an account with no username" do
    setup do
      %{nameless: nameless_user_fixture(%{display_name: "Robin Vega"})}
    end

    test "the name cell falls back instead of rendering empty", %{
      conn: conn,
      nameless: nameless
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#user-name-#{nameless.id}", "Robin Vega")
    end

    test "a local account still shows its username in the name cell", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#user-name-#{admin.id}", "installer")
    end

    test "the edit-role modal names them", %{conn: conn, nameless: nameless} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view
      |> element(~s{button[phx-click="open_edit_role_modal"][phx-value-id="#{nameless.id}"]})
      |> render_click()

      assert has_element?(view, "#edit-role-modal-title", "Robin Vega")
    end

    test "the delete modal names them", %{conn: conn, nameless: nameless} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view
      |> element(~s{button[phx-click="open_delete_modal"][phx-value-id="#{nameless.id}"]})
      |> render_click()

      assert has_element?(view, "#delete-modal-prompt", "Robin Vega")
    end
  end

  describe "two-factor reset" do
    setup do
      totp_user_fixture()
    end

    test "shows a 2FA badge and resets it", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#totp-badge-#{user.id}")

      view |> element("#reset-2fa-#{user.id}") |> render_click()

      refute Mydia.Accounts.totp_enabled?(Mydia.Accounts.get_user!(user.id))
      refute has_element?(view, "#totp-badge-#{user.id}")
    end
  end

  test "resetting 2FA also removes passkeys", %{conn: conn} do
    user = user_fixture()
    passkey_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/admin/users")
    assert has_element?(view, "#passkey-badge-#{user.id}")
    assert has_element?(view, "#totp-badge-#{user.id}")

    view |> element("#reset-2fa-#{user.id}") |> render_click()

    refute Mydia.Accounts.has_passkeys?(user)
    refute has_element?(view, "#passkey-badge-#{user.id}")
  end
end
