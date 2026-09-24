defmodule MydiaWeb.SessionControllerTotpTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  @password "correct-horse-battery-staple"

  setup do
    fixture = totp_user_fixture(%{password: @password})

    # Recycled test conns always come from 127.0.0.1, and the limiter is
    # process-global, so clear both buckets this file leans on.
    Mydia.Accounts.reset_login_rate_limit("127.0.0.1", fixture.user.username)

    fixture
  end

  defp submit_password(conn, user) do
    post(conn, ~p"/auth/local/login", %{
      "user" => %{"username" => user.username, "password" => @password}
    })
  end

  defp signed_in?(conn), do: get_session(conn, :guardian_default_token) != nil

  test "password-only accounts still sign in directly", %{conn: conn} do
    plain = user_fixture(%{password: @password})

    conn = submit_password(conn, plain)

    assert redirected_to(conn) == "/"
    assert signed_in?(conn)
  end

  test "a TOTP account is sent to the challenge without a session", %{conn: conn, user: user} do
    conn = submit_password(conn, user)

    assert redirected_to(conn) == "/auth/login/totp"
    refute signed_in?(conn)
    assert %{"user_id" => user_id} = get_session(conn, :pending_totp)
    assert user_id == user.id
  end

  test "the challenge page renders while pending", %{conn: conn, user: user} do
    conn = conn |> submit_password(user) |> get(~p"/auth/login/totp")

    assert html_response(conn, 200) =~ ~s(id="totp-form")
  end

  test "a correct code signs in", %{conn: conn, user: user, secret: secret} do
    conn =
      conn
      |> submit_password(user)
      |> post(~p"/auth/login/totp", %{"totp" => %{"code" => NimbleTOTP.verification_code(secret)}})

    assert redirected_to(conn) == "/"
    assert signed_in?(conn)
    assert get_session(conn, :pending_totp) == nil
  end

  test "a recovery code signs in", %{conn: conn, user: user, recovery_codes: [code | _]} do
    conn =
      conn
      |> submit_password(user)
      |> post(~p"/auth/login/totp", %{"totp" => %{"code" => code}})

    assert redirected_to(conn) == "/"
    assert signed_in?(conn)
  end

  test "a wrong code re-renders with an error", %{conn: conn, user: user} do
    conn =
      conn
      |> submit_password(user)
      |> post(~p"/auth/login/totp", %{"totp" => %{"code" => "abc"}})

    html = html_response(conn, 200)
    assert html =~ "Invalid code"
    refute signed_in?(conn)
  end

  test "an expired challenge returns to the login page", %{conn: conn, user: user} do
    conn =
      conn
      |> init_test_session(%{
        pending_totp: %{"user_id" => user.id, "issued_at" => System.system_time(:second) - 301}
      })
      |> get(~p"/auth/login/totp")

    assert redirected_to(conn) == "/auth/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign-in expired, please try again"
  end

  test "the challenge page without a pending sign-in redirects", %{conn: conn} do
    conn = get(conn, ~p"/auth/login/totp")

    assert redirected_to(conn) == "/auth/login"
  end

  test "wrong codes count toward the login rate limit", %{conn: conn, user: user, secret: secret} do
    conn = submit_password(conn, user)

    conn =
      Enum.reduce(1..10, conn, fn _, conn ->
        post(conn, ~p"/auth/login/totp", %{"totp" => %{"code" => "abc"}})
      end)

    conn =
      post(conn, ~p"/auth/login/totp", %{
        "totp" => %{"code" => NimbleTOTP.verification_code(secret)}
      })

    assert html_response(conn, 200) =~ "Too many login attempts"
    refute signed_in?(conn)
  end
end
