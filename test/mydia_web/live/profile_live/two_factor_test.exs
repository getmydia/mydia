defmodule MydiaWeb.ProfileLive.TwoFactorTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp secret_from(view) do
    view
    |> element("#totp-secret")
    |> render()
    |> then(&Regex.run(~r/>\s*([A-Z2-7]+)\s*</, &1, capture: :all_but_first))
    |> hd()
    |> Base.decode32!(padding: false)
  end

  test "enrolls with a correct code and shows recovery codes once", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#two-factor-card")
    view |> element("#totp-enable-btn") |> render_click()
    assert has_element?(view, "#totp-enroll-modal")
    assert has_element?(view, "#totp-qr svg")

    secret = secret_from(view)

    view
    |> form("#totp-confirm-form", totp: %{code: NimbleTOTP.verification_code(secret)})
    |> render_submit()

    assert has_element?(view, "#recovery-codes li", ~r/[a-z2-7]{5}-[a-z2-7]{5}/)
    assert Accounts.totp_enabled?(Accounts.get_user!(user.id))

    view |> element("#totp-done-btn") |> render_click()
    refute has_element?(view, "#recovery-codes")
    assert has_element?(view, "#totp-status")
  end

  test "a wrong enrollment code shows an error and enables nothing", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")
    view |> element("#totp-enable-btn") |> render_click()

    view |> form("#totp-confirm-form", totp: %{code: "abc"}) |> render_submit()

    assert has_element?(view, "#totp-modal-error")
    refute Accounts.totp_enabled?(Accounts.get_user!(user.id))
  end

  describe "with TOTP enabled" do
    setup %{user: user} do
      %{secret: secret} = Accounts.begin_totp_enrollment(user)

      {:ok, user, codes} =
        Accounts.confirm_totp_enrollment(user, secret, NimbleTOTP.verification_code(secret))

      user =
        user |> Accounts.User.totp_changeset(%{totp_last_used_at: nil}) |> Mydia.Repo.update!()

      %{user: user, secret: secret, recovery_codes: codes}
    end

    test "regenerates recovery codes", %{conn: conn, secret: secret} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      view |> element("#totp-regenerate-btn") |> render_click()

      view
      |> form("#totp-regenerate-form", totp: %{code: NimbleTOTP.verification_code(secret)})
      |> render_submit()

      assert has_element?(view, "#recovery-codes li")
    end

    test "disables with password and a recovery code", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _]
    } do
      {:ok, view, _html} = live(conn, ~p"/profile")

      view |> element("#totp-disable-btn") |> render_click()

      view
      |> form("#totp-disable-form", disable_totp: %{password: "wrong", code: code})
      |> render_submit()

      assert has_element?(view, "#totp-modal-error")

      # register_and_log_in_user/1 creates the user through
      # MydiaWeb.AuthHelpers.create_test_user/1, whose default password is this.
      view
      |> form("#totp-disable-form", disable_totp: %{password: "password123", code: code})
      |> render_submit()

      refute Accounts.totp_enabled?(Accounts.get_user!(user.id))
      assert has_element?(view, "#totp-enable-btn")
    end
  end
end
