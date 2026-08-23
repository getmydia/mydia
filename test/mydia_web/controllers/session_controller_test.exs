defmodule MydiaWeb.SessionControllerTest do
  @moduledoc """
  Regression coverage for T-005 / T-011: the HTTP form login
  (`POST /auth/local/login`) reached `Accounts.verify_password/2` with no
  rate limiting at all -- the same unthrottled check the GraphQL `login`
  mutation used (see `MydiaWeb.Schema.AuthResolverTest` for that side). See
  `Mydia.Accounts.check_login_rate_limit/2` for the shared throttle both
  routes now go through.
  """

  use MydiaWeb.ConnCase

  describe "POST /auth/local/login" do
    test "succeeds with correct credentials", %{conn: conn} do
      user = create_test_user(%{password: "correct-horse-battery-staple"})

      conn =
        post(conn, ~p"/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "correct-horse-battery-staple"}
        })

      assert redirected_to(conn) == "/"
    end

    test "rate limits repeated failures against one account, even from different source IPs" do
      user = create_test_user(%{password: "correct-horse-battery-staple"})

      for i <- 1..10 do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:remote_ip, unique_ip(i))
          |> post(~p"/auth/local/login", %{
            "user" => %{"username" => user.username, "password" => "wrong"}
          })

        assert html_response(conn, 200) =~ "Invalid username or password"
      end

      # A never-before-seen source IP, with the *correct* password. Still
      # locked out, because the username bucket -- not just the IP bucket --
      # is exhausted.
      locked_conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, unique_ip(11))
        |> post(~p"/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "correct-horse-battery-staple"}
        })

      assert html_response(locked_conn, 200) =~ "Too many login attempts"
    end

    test "rate limits a single source guessing many usernames from one IP" do
      user = create_test_user(%{password: "correct-horse-battery-staple"})
      ip = unique_ip(System.unique_integer([:positive]))

      # 50, not 10: the IP bucket is deliberately looser than the username
      # bucket because behind a reverse proxy every user shares one IP, so a
      # tight IP limit would be a global login lockout. See the rationale on
      # @login_ip_rate_limit_max_attempts in Mydia.Accounts.
      for i <- 1..50 do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:remote_ip, ip)
          |> post(~p"/auth/local/login", %{
            "user" => %{"username" => "no-such-user-#{i}", "password" => "guess"}
          })

        assert html_response(conn, 200) =~ "Invalid username or password"
      end

      # Same IP, real account, correct password -- still blocked because the
      # IP bucket (not the per-username bucket) is exhausted.
      locked_conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, ip)
        |> post(~p"/auth/local/login", %{
          "user" => %{"username" => user.username, "password" => "correct-horse-battery-staple"}
        })

      assert html_response(locked_conn, 200) =~ "Too many login attempts"
    end

    test "does not rate limit an unrelated account from a different IP" do
      noisy_user = create_test_user(%{password: "correct-horse-battery-staple"})
      other_user = create_test_user(%{password: "another-password"})
      noisy_ip = unique_ip(System.unique_integer([:positive]))

      for _ <- 1..10 do
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, noisy_ip)
        |> post(~p"/auth/local/login", %{
          "user" => %{"username" => noisy_user.username, "password" => "wrong"}
        })
      end

      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, unique_ip(System.unique_integer([:positive])))
        |> post(~p"/auth/local/login", %{
          "user" => %{"username" => other_user.username, "password" => "another-password"}
        })

      assert redirected_to(conn) == "/"
    end
  end

  defp unique_ip(seed) do
    a = rem(div(seed, 256 * 256), 256)
    b = rem(div(seed, 256), 256)
    c = rem(seed, 254) + 1
    {203, a, b, c}
  end
end
