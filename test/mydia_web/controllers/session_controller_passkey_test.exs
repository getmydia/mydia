defmodule MydiaWeb.SessionControllerPasskeyTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.SoftAuthenticator

  @base "https://mydia.test"
  @password "correct-horse-battery-staple"

  setup do
    user = user_fixture(%{password: @password})
    fixture = passkey_fixture(user, password: @password)
    Accounts.reset_login_rate_limit("127.0.0.1", user.username)
    Map.put(fixture, :user, user)
  end

  defp submit_password(conn, user, base \\ @base) do
    post(conn, base <> "/auth/local/login", %{
      "user" => %{"username" => user.username, "password" => @password}
    })
  end

  defp second_factor(conn, authn, opts \\ []) do
    conn = post(recycle(conn), @base <> "/auth/login/totp/passkey-options", %{})
    ceremony = SoftAuthenticator.ceremony(json_response(conn, 200)["publicKey"], @base)
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, opts)
    post(recycle(conn), @base <> "/auth/login/totp/passkey", %{"credential" => payload})
  end

  defp signed_in?(conn), do: get_session(conn, :guardian_default_token) != nil

  test "a password sign-in for an account with a passkey asks for a second factor", %{
    conn: conn,
    user: user
  } do
    conn = submit_password(conn, user)

    assert redirected_to(conn) == "/auth/login/totp"
    refute signed_in?(conn)
  end

  test "the challenge page offers the passkey but not a code form", %{conn: conn, user: user} do
    html =
      conn
      |> submit_password(user)
      |> recycle()
      |> get(@base <> "/auth/login/totp")
      |> html_response(200)

    assert html =~ ~s(id="passkey-second-factor-section")
    refute html =~ ~s(id="totp-form")
    refute html =~ ~s(id="second-factor-unavailable")
  end

  test "the passkey completes the sign-in", %{conn: conn, user: user, authenticator: authn} do
    conn = conn |> submit_password(user) |> second_factor(authn, user_verified: false)

    assert json_response(conn, 200) == %{"redirect" => "/"}
    assert signed_in?(conn)
    assert get_session(conn, :pending_totp) == nil
  end

  test "another user's passkey is refused", %{conn: conn, user: user} do
    stranger = user_fixture()
    %{authenticator: authn} = passkey_fixture(stranger)

    conn = conn |> submit_password(user) |> second_factor(authn)

    assert json_response(conn, 401)["error"] == "Passkey not recognised"
    refute signed_in?(conn)
  end

  test "options need a pending password sign-in", %{conn: conn} do
    conn = post(conn, @base <> "/auth/login/totp/passkey-options", %{})
    assert json_response(conn, 404)
  end

  test "a TOTP account with a passkey sees both", %{conn: conn} do
    %{user: user} = totp_user_fixture(%{password: @password})
    passkey_fixture(user, password: @password)

    html =
      conn
      |> submit_password(user)
      |> recycle()
      |> get(@base <> "/auth/login/totp")
      |> html_response(200)

    assert html =~ ~s(id="totp-form")
    assert html =~ ~s(id="passkey-second-factor-section")
  end

  test "a passkey-only account on an insecure host is told where to sign in", %{
    conn: conn,
    user: user
  } do
    html =
      conn
      |> submit_password(user, "http://mydia.lan")
      |> recycle()
      |> get("http://mydia.lan/auth/login/totp")
      |> html_response(200)

    assert html =~ ~s(id="second-factor-unavailable")
    refute html =~ ~s(id="totp-form")
  end
end
