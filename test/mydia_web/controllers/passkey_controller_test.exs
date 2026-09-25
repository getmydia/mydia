defmodule MydiaWeb.PasskeyControllerTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts
  alias Mydia.SoftAuthenticator

  @base "https://mydia.test"

  setup do
    user = user_fixture()
    fixture = passkey_fixture(user)
    Accounts.reset_login_rate_limit("127.0.0.1", "passkey:" <> fixture.passkey.credential_id)
    Map.put(fixture, :user, user)
  end

  defp options(conn), do: post(conn, @base <> "/auth/passkey/options", %{})

  defp sign_in(conn, authn, opts \\ []) do
    conn = options(conn)
    ceremony = SoftAuthenticator.ceremony(json_response(conn, 200)["publicKey"], @base)
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony, opts)
    post(recycle(conn), @base <> "/auth/passkey/login", %{"credential" => payload})
  end

  defp signed_in?(conn), do: get_session(conn, :guardian_default_token) != nil

  test "options ask for any discoverable passkey with user verification", %{conn: conn} do
    body = conn |> options() |> json_response(200)

    assert body["publicKey"]["rpId"] == "mydia.test"
    assert body["publicKey"]["userVerification"] == "required"
    assert body["publicKey"]["allowCredentials"] == []
  end

  test "a valid passkey signs in", %{conn: conn, authenticator: authn} do
    conn = sign_in(conn, authn)

    assert json_response(conn, 200) == %{"redirect" => "/"}
    assert signed_in?(conn)
  end

  test "a passkey sign-in does not ask for TOTP", %{conn: conn} do
    %{user: user} = totp_user_fixture()
    %{authenticator: authn} = passkey_fixture(user)

    conn = sign_in(conn, authn)
    assert json_response(conn, 200) == %{"redirect" => "/"}
  end

  test "a challenge cannot be used twice", %{conn: conn, authenticator: authn} do
    conn = options(conn)
    ceremony = SoftAuthenticator.ceremony(json_response(conn, 200)["publicKey"], @base)
    {_authn, payload} = SoftAuthenticator.assert(authn, ceremony)

    first = post(recycle(conn), @base <> "/auth/passkey/login", %{"credential" => payload})
    assert json_response(first, 200)

    second = post(recycle(first), @base <> "/auth/passkey/login", %{"credential" => payload})
    assert json_response(second, 400)["error"] == "Sign-in expired, please try again"
  end

  test "login without options is refused", %{conn: conn} do
    conn = post(conn, @base <> "/auth/passkey/login", %{"credential" => %{}})
    assert json_response(conn, 400)
    refute signed_in?(conn)
  end

  test "an unknown passkey is rejected", %{conn: conn} do
    conn = sign_in(conn, SoftAuthenticator.new())

    assert json_response(conn, 401)["error"] == "Passkey not recognised"
    refute signed_in?(conn)
  end

  test "repeated failures are rate limited", %{conn: conn} do
    stranger = SoftAuthenticator.new()

    Accounts.reset_login_rate_limit(
      "127.0.0.1",
      "passkey:" <> SoftAuthenticator.credential_id(stranger)
    )

    statuses =
      for _ <- 1..30 do
        conn |> recycle() |> sign_in(stranger) |> Map.fetch!(:status)
      end

    assert 429 in statuses
  end

  test "plain http on a LAN host has no passkeys", %{conn: conn} do
    conn = post(conn, "http://mydia.lan/auth/passkey/options", %{})
    assert json_response(conn, 404)
  end

  # Mutates Application config, which is only safe because this module is
  # async: false (see test/README.md, "Tests must not mutate global env").
  test "disabled local auth turns passkeys off", %{conn: conn} do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    config = Mydia.Config.get()

    Application.put_env(:mydia, :runtime_config, %{
      config
      | auth: %{config.auth | local_enabled: false}
    })

    conn = options(conn)
    assert json_response(conn, 404)
  end

  describe "login page" do
    test "shows the passkey button on a secure host", %{conn: conn} do
      html = conn |> get(@base <> "/auth/login") |> html_response(200)

      assert html =~ ~s(id="passkey-login-section")
      assert html =~ ~s(autocomplete="username webauthn")
    end

    test "hides it on plain http", %{conn: conn} do
      html = conn |> get("http://mydia.lan/auth/login") |> html_response(200)
      refute html =~ ~s(id="passkey-login-section")
    end
  end
end
