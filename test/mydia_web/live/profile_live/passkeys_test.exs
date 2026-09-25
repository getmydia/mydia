defmodule MydiaWeb.ProfileLive.PasskeysTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.SoftAuthenticator

  @password "securepassword123"
  @url "https://mydia.test/profile"
  @origin "https://mydia.test"

  setup %{conn: conn} do
    user = user_fixture()
    Accounts.reset_login_rate_limit("profile:#{user.id}", user.username)
    %{conn: log_in_user(conn, user), user: user}
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, @url)
    view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => true})
    view
  end

  test "adds a passkey after the password", %{conn: conn, user: user} do
    view = open(conn)

    view |> element("#add-passkey") |> render_click()

    view
    |> form("#passkey-password-form", passkey: %{password: @password})
    |> render_submit()

    assert_push_event(view, "passkey:register", %{options: options})

    payload =
      SoftAuthenticator.attest(
        SoftAuthenticator.new(),
        SoftAuthenticator.ceremony(options, @origin)
      )

    view
    |> element("#passkeys")
    |> render_hook("passkey_registered", %{
      "credential" => payload,
      "name" => "Passkey on Firefox, Linux"
    })

    [passkey] = Accounts.list_passkeys(user)
    assert passkey.name == "Passkey on Firefox, Linux"
    assert has_element?(view, "#passkey-#{passkey.id}")
    refute has_element?(view, "#passkey-modal")
  end

  test "a wrong password never reaches the authenticator", %{conn: conn} do
    view = open(conn)
    view |> element("#add-passkey") |> render_click()

    view |> form("#passkey-password-form", passkey: %{password: "wrong"}) |> render_submit()

    assert has_element?(view, "#passkey-modal-error", "Current password is incorrect")
    refute_push_event(view, "passkey:register", %{})
  end

  test "a cancelled browser prompt shows a message", %{conn: conn} do
    view = open(conn)
    view |> element("#add-passkey") |> render_click()
    view |> form("#passkey-password-form", passkey: %{password: @password}) |> render_submit()

    view |> element("#passkeys") |> render_hook("passkey_failed", %{"reason" => "duplicate"})

    assert has_element?(
             view,
             "#passkey-modal-error",
             "This device already has a passkey for this account"
           )
  end

  test "renames and deletes", %{conn: conn, user: user} do
    %{passkey: passkey} = passkey_fixture(user)
    view = open(conn)

    view |> element("#passkey-rename-#{passkey.id}") |> render_click()
    view |> form("#passkey-rename-form", rename: %{name: "Phone"}) |> render_submit()
    assert has_element?(view, "#passkey-#{passkey.id}", "Phone")

    view |> element("#passkey-delete-#{passkey.id}") |> render_click()
    view |> form("#passkey-delete-form", passkey: %{password: "wrong"}) |> render_submit()
    assert has_element?(view, "#passkey-modal-error", "Current password is incorrect")

    view |> form("#passkey-delete-form", passkey: %{password: @password}) |> render_submit()
    refute has_element?(view, "#passkey-#{passkey.id}")
    refute Accounts.has_passkeys?(user)
  end

  test "explains the effect on password sign-in before the first passkey", %{conn: conn} do
    view = open(conn)
    assert has_element?(view, "#passkey-2fa-note")
  end

  test "an unsupported browser gets a note instead of the button", %{conn: conn} do
    {:ok, view, _html} = live(conn, @url)
    view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => false})

    assert has_element?(view, "#passkey-unsupported")
    refute has_element?(view, "#add-passkey")
  end

  test "plain http gets the note too", %{conn: conn} do
    {:ok, view, _html} = live(conn, "http://mydia.lan/profile")
    view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => true})

    assert has_element?(view, "#passkey-unsupported")
  end
end
