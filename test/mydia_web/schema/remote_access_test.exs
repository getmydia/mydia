defmodule MydiaWeb.Schema.RemoteAccessTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.RemoteAccess.RemoteDevice
  alias Mydia.Repo

  @refresh_media_token_mutation """
  mutation RefreshMediaToken($token: String!) {
    refreshMediaToken(token: $token) {
      token
      expiresAt
      permissions
    }
  }
  """

  describe "refreshMediaToken mutation" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream", "download"])
      %{user: user, device: device, token: token}
    end

    test "refreshes a valid token", %{token: old_token} do
      variables = %{"token" => old_token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{data: %{"refreshMediaToken" => response}}} = result
      assert response["token"] != nil
      assert response["token"] != old_token
      assert response["expiresAt"] != nil
      assert response["permissions"] == ["stream", "download"]
    end

    test "returns error for invalid token" do
      variables = %{"token" => "invalid.jwt.token"}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Error could be "Invalid token", "Failed to refresh token", or similar
      assert message =~ "Invalid" or message =~ "invalid" or message =~ "Failed to refresh"
    end

    test "returns error for expired token", %{device: device} do
      # Create a short-lived token (1 second TTL)
      {:ok, expired_token, claims} = MediaToken.create_token(device, ttl: {1, :second})

      # Verify the TTL was applied (exp should be about 1 second after iat)
      assert claims["exp"] - claims["iat"] <= 2

      # Wait for token to expire (allowed_drift is 0 in test config,
      # 2000ms for reliable expiry with second-precision JWT timestamps)
      Process.sleep(2000)

      variables = %{"token" => expired_token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "expired"
    end

    test "returns error for revoked device token", %{device: device, token: token} do
      # Revoke the device
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      variables = %{"token" => token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "revoked"
    end

    test "preserves permissions when refreshing", %{device: device} do
      # Create token with limited permissions
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream"])

      variables = %{"token" => token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{data: %{"refreshMediaToken" => response}}} = result
      assert response["permissions"] == ["stream"]
    end
  end

  @refresh_access_token_mutation """
  mutation RefreshAccessToken($deviceToken: String!) {
    refreshAccessToken(deviceToken: $deviceToken) {
      token
      expiresAt
    }
  }
  """

  describe "refreshAccessToken mutation" do
    setup do
      user = create_user()
      device_token = "device-token-#{System.unique_integer([:positive])}"
      device = create_device(user, %{token: device_token})
      %{user: user, device: device, device_token: device_token}
    end

    test "exchanges a valid device token for a usable access token", %{
      user: user,
      device_token: device_token
    } do
      result = run_query(@refresh_access_token_mutation, %{"deviceToken" => device_token})

      assert {:ok, %{data: %{"refreshAccessToken" => response}}} = result
      assert is_binary(response["token"])
      assert response["expiresAt"] != nil

      # The whole point: the minted token must authenticate as the device's user,
      # which is what the P2P GraphQL context builder does with it.
      assert {:ok, verified} = Guardian.verify_token(response["token"])
      assert verified.id == user.id
    end

    test "returns error for an unknown device token" do
      result =
        run_query(@refresh_access_token_mutation, %{"deviceToken" => "no-such-device-token"})

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "Invalid"
    end

    test "returns error for a revoked device", %{device: device, device_token: device_token} do
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      result = run_query(@refresh_access_token_mutation, %{"deviceToken" => device_token})

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "Invalid"
    end

    test "rate limits a caller that keeps guessing device tokens" do
      caller = unique_caller()

      # Each miss costs one Argon2 pass per paired device, so the ceiling is what
      # stops this unauthenticated mutation being a CPU amplifier.
      for _ <- 1..10 do
        assert {:ok, %{errors: [%{message: message}]}} =
                 run_query(@refresh_access_token_mutation, %{"deviceToken" => "bad"}, caller)

        assert message =~ "Invalid"
      end

      assert {:ok, %{errors: [%{message: message}]}} =
               run_query(@refresh_access_token_mutation, %{"deviceToken" => "bad"}, caller)

      assert message =~ "Too many"
    end

    test "does not rate limit a different caller", %{device_token: device_token} do
      noisy = unique_caller()

      for _ <- 1..10 do
        run_query(@refresh_access_token_mutation, %{"deviceToken" => "bad"}, noisy)
      end

      assert {:ok, %{data: %{"refreshAccessToken" => response}}} =
               run_query(
                 @refresh_access_token_mutation,
                 %{"deviceToken" => device_token},
                 unique_caller()
               )

      assert is_binary(response["token"])
    end

    test "successful refreshes never consume the rate limit budget", %{
      device_token: device_token
    } do
      caller = unique_caller()

      for _ <- 1..12 do
        assert {:ok, %{data: %{"refreshAccessToken" => _}}} =
                 run_query(
                   @refresh_access_token_mutation,
                   %{"deviceToken" => device_token},
                   caller
                 )
      end
    end

    test "records that the device was seen", %{device: device, device_token: device_token} do
      assert is_nil(device.last_seen_at)

      assert {:ok, %{data: %{"refreshAccessToken" => _}}} =
               run_query(@refresh_access_token_mutation, %{"deviceToken" => device_token})

      assert Repo.reload!(device).last_seen_at != nil
    end
  end

  # Helper function to run GraphQL queries (no auth needed for token refresh)
  defp run_query(query, variables, context \\ %{}) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end

  # The rate limiter is backed by a process-wide ETS table rather than the Ecto
  # sandbox, so each test needs its own bucket to stay isolated.
  defp unique_caller do
    %{remote_ip: "203.0.113.#{System.unique_integer([:positive])}"}
  end

  # Test Helpers

  defp create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      username: "user#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Accounts.create_user()

    user
  end

  defp create_device(user, attrs \\ %{}) do
    default_attrs = %{
      device_name: "Test Device #{System.unique_integer([:positive])}",
      platform: "ios",
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    %RemoteDevice{}
    |> RemoteDevice.changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end
end
