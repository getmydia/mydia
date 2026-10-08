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

  test "the page passes a user count and uses the shared table", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/users")
    assert has_element?(view, "#admin-page-count")
    assert has_element?(view, "#users table.table-zebra")
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

      assert has_element?(view, "#edit-role-modal", "Robin Vega")
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

  describe "create local user form" do
    defp open_create(view) do
      view |> element(~s{button[phx-click="open_create_modal"]}) |> render_click()
      view
    end

    defp switch_create_mode(view, mode) do
      view
      |> element(~s{#create-password-mode button[phx-value-mode="#{mode}"]})
      |> render_click()

      view
    end

    test "a short manual password marks the password field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      view |> open_create() |> switch_create_mode("manual")

      view
      |> form("#create-user-form",
        create: %{
          username: "casey",
          email: "casey@example.com",
          role: "guest",
          password: "abcd",
          password_confirmation: "abcd"
        }
      )
      |> render_submit()

      assert has_element?(
               view,
               ~s{#create-user-form input[name="create[password]"].input-error}
             )

      assert has_element?(view, "#create-user-form", "must be at least 8 characters")
      refute Mydia.Accounts.get_user_by_username("casey")
    end

    test "switching to manual keeps what was typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      open_create(view)

      view
      |> form("#create-user-form",
        create: %{username: "casey", email: "casey@example.com", role: "user"}
      )
      |> render_change()

      switch_create_mode(view, "manual")

      assert has_element?(
               view,
               ~s{#create-user-form input[name="create[username]"][value="casey"]}
             )

      assert has_element?(
               view,
               ~s{#create-user-form input[name="create[email]"][value="casey@example.com"]}
             )

      assert has_element?(
               view,
               ~s{#create-user-form select[name="create[role]"] option[value="user"][selected]}
             )
    end
  end

  describe "reset password modal" do
    setup do
      %{target: user_fixture(%{username: "morgan"})}
    end

    defp open_reset(view, user) do
      view
      |> element(~s{button[phx-click="open_reset_password_modal"][phx-value-id="#{user.id}"]})
      |> render_click()

      view
    end

    test "auto-generate actually resets the password", %{conn: conn, target: target} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      open_reset(view, target)

      view
      |> element(~s{button[phx-click="submit_reset_password"]})
      |> render_click()

      refute Mydia.Accounts.verify_password(
               Mydia.Accounts.get_user!(target.id),
               "securepassword123"
             )
    end

    test "a short manual password marks the password field", %{conn: conn, target: target} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")
      open_reset(view, target)

      view
      |> element(~s{#reset-password-mode button[phx-value-mode="manual"]})
      |> render_click()

      view
      |> form("#reset-password-form",
        reset_password: %{password: "abcd", password_confirmation: "abcd"}
      )
      |> render_submit()

      assert has_element?(
               view,
               ~s{#reset-password-form input[name="reset_password[password]"].input-error}
             )

      assert has_element?(view, "#reset-password-form", "must be at least 8 characters")
    end
  end
end
