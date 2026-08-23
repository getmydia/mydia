defmodule MydiaWeb.Schema.AuthResolverTest do
  @moduledoc """
  Regression coverage for T-005 / T-011: the GraphQL `login` mutation reached
  `Accounts.verify_password/2` with no rate limiting at all, the same
  unthrottled check the HTTP form login used (see
  `MydiaWeb.SessionControllerTest` for that side). See
  `Mydia.Accounts.check_login_rate_limit/2` for the shared throttle both
  routes now go through.
  """

  use MydiaWeb.ConnCase

  @login_mutation """
  mutation Login($input: LoginInput!) {
    login(input: $input) {
      token
      user {
        id
      }
    }
  }
  """

  setup do
    user = create_test_user(%{password: "correct-horse-battery-staple"})
    %{user: user}
  end

  describe "login mutation" do
    test "succeeds with correct credentials", %{user: user} do
      result =
        run_query(%{"username" => user.username, "password" => "correct-horse-battery-staple"})

      assert {:ok, %{data: %{"login" => %{"token" => token}}}} = result
      assert is_binary(token)
    end

    test "fails with wrong password", %{user: user} do
      result = run_query(%{"username" => user.username, "password" => "wrong"}, unique_caller())

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "Invalid"
    end

    test "rate limits repeated failures against one account regardless of source IP", %{
      user: user
    } do
      # Each request uses a fresh IP, simulating a distributed / credential-
      # stuffing attempt against a single known username. The per-IP bucket
      # alone would never catch this; the per-username bucket must.
      for _ <- 1..10 do
        assert {:ok, %{errors: [%{message: message}]}} =
                 run_query(%{"username" => user.username, "password" => "wrong"}, unique_caller())

        assert message =~ "Invalid"
      end

      assert {:ok, %{errors: [%{message: message}]}} =
               run_query(%{"username" => user.username, "password" => "wrong"}, unique_caller())

      assert message =~ "Too many"

      # The lockout blocks even the correct password now.
      assert {:ok, %{errors: [%{message: message}]}} =
               run_query(
                 %{"username" => user.username, "password" => "correct-horse-battery-staple"},
                 unique_caller()
               )

      assert message =~ "Too many"
    end

    test "rate limits a single source guessing many usernames", %{user: user} do
      caller = unique_caller()

      # 50, not 10: the IP bucket is deliberately looser than the username
      # bucket because behind a reverse proxy every user shares one IP, so a
      # tight IP limit would be a global login lockout. See the rationale on
      # @login_ip_rate_limit_max_attempts in Mydia.Accounts.
      for i <- 1..50 do
        assert {:ok, %{errors: [%{message: message}]}} =
                 run_query(%{"username" => "no-such-user-#{i}", "password" => "guess"}, caller)

        assert message =~ "Invalid"
      end

      # The IP bucket is now exhausted, even against the real account.
      assert {:ok, %{errors: [%{message: message}]}} =
               run_query(
                 %{"username" => user.username, "password" => "correct-horse-battery-staple"},
                 caller
               )

      assert message =~ "Too many"
    end

    test "does not rate limit a different, unrelated caller and account", %{user: user} do
      noisy = unique_caller()

      for _ <- 1..10 do
        run_query(%{"username" => user.username, "password" => "wrong"}, noisy)
      end

      other_user = create_test_user(%{password: "another-password"})

      assert {:ok, %{data: %{"login" => %{"token" => token}}}} =
               run_query(
                 %{"username" => other_user.username, "password" => "another-password"},
                 unique_caller()
               )

      assert is_binary(token)
    end

    test "a successful login resets the rate limit for that account and IP", %{user: user} do
      caller = unique_caller()

      for _ <- 1..5 do
        run_query(%{"username" => user.username, "password" => "wrong"}, caller)
      end

      assert {:ok, %{data: %{"login" => %{"token" => _token}}}} =
               run_query(
                 %{"username" => user.username, "password" => "correct-horse-battery-staple"},
                 caller
               )

      # Same caller/account, well within the limit again post-reset.
      for _ <- 1..5 do
        assert {:ok, %{errors: [%{message: message}]}} =
                 run_query(%{"username" => user.username, "password" => "wrong"}, caller)

        assert message =~ "Invalid"
      end
    end
  end

  defp run_query(input, context \\ %{}) do
    full_input =
      Map.merge(
        %{
          "deviceId" => "test-device-#{System.unique_integer([:positive])}",
          "deviceName" => "Test Device",
          "platform" => "web"
        },
        input
      )

    Absinthe.run(@login_mutation, MydiaWeb.Schema,
      variables: %{"input" => full_input},
      context: context
    )
  end

  # The rate limiter is backed by a process-wide ETS table rather than the
  # Ecto sandbox, so each test needs its own bucket to stay isolated.
  defp unique_caller do
    %{remote_ip: "203.0.113.#{System.unique_integer([:positive])}"}
  end
end
