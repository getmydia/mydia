defmodule Mydia.RemoteAccess.MediaTokenTest do
  use Mydia.DataCase

  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.RemoteAccess.RemoteDevice
  alias Mydia.Accounts

  describe "create_token/2" do
    setup do
      user = create_user()
      device = create_device(user)
      %{user: user, device: device}
    end

    test "creates a valid token for a device", %{device: device} do
      assert {:ok, token, claims} = MediaToken.create_token(device)

      assert is_binary(token)
      assert claims["sub"] == device.id
      assert claims["user_id"] == device.user_id
      assert claims["permissions"] == ["stream", "download", "thumbnails"]
      assert claims["typ"] == "media_access"
      assert claims["iss"] == "mydia"
    end

    test "creates token with custom TTL", %{device: device} do
      assert {:ok, token, claims} = MediaToken.create_token(device, ttl: {1, :hour})

      assert is_binary(token)
      # Verify expiration is roughly 1 hour from now
      {:ok, decoded_claims} = Guardian.decode_and_verify(MediaToken, token)
      exp = decoded_claims["exp"]
      iat = decoded_claims["iat"]
      # Allow some margin for test execution time
      assert exp - iat >= 3500 and exp - iat <= 3700
    end

    test "creates token with custom permissions", %{device: device} do
      assert {:ok, token, claims} = MediaToken.create_token(device, permissions: ["stream"])

      assert claims["permissions"] == ["stream"]
    end

    test "creates token with multiple custom permissions", %{device: device} do
      permissions = ["stream", "download"]
      assert {:ok, token, claims} = MediaToken.create_token(device, permissions: permissions)

      assert claims["permissions"] == permissions
    end
  end

  describe "verify_token/1" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)
      %{user: user, device: device, token: token}
    end

    test "verifies valid token and returns device with user preloaded", %{
      device: device,
      user: user,
      token: token
    } do
      assert {:ok, loaded_device, claims} = MediaToken.verify_token(token)

      assert loaded_device.id == device.id
      assert loaded_device.user_id == user.id
      assert loaded_device.user.id == user.id
      assert claims["typ"] == "media_access"
    end

    test "rejects token with invalid signature" do
      invalid_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.invalid.signature"

      assert {:error, _reason} = MediaToken.verify_token(invalid_token)
    end

    test "rejects expired token", %{device: device} do
      # Create token that expires in 1 second
      {:ok, token, claims} = MediaToken.create_token(device, ttl: {1, :second})

      # Verify the TTL was applied (exp should be about 1 second after iat)
      assert claims["exp"] - claims["iat"] <= 2

      # Wait for token to expire (allowed_drift is 0 in test config,
      # 2000ms for reliable expiry with second-precision JWT timestamps)
      Process.sleep(2000)

      assert {:error, :token_expired} = MediaToken.verify_token(token)
    end

    test "rejects token for revoked device", %{device: device, token: token} do
      # Revoke the device
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      assert {:error, :device_revoked} = MediaToken.verify_token(token)
    end

    test "rejects token for non-existent device" do
      # Create a device, get token, then delete the device
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      Repo.delete!(device)

      assert {:error, :device_not_found} = MediaToken.verify_token(token)
    end

    test "rejects token with wrong type claim", %{device: device, user: _user} do
      # Create a token with wrong type
      {:ok, token, _claims} =
        Guardian.encode_and_sign(
          MediaToken,
          device,
          %{"user_id" => device.user_id, "typ" => "wrong_type"}
        )

      assert {:error, _reason} = MediaToken.verify_token(token)
    end
  end

  describe "refresh_token/1" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream"])
      %{device: device, token: token}
    end

    test "refreshes token with same permissions", %{token: old_token} do
      assert {:ok, new_token, new_claims} = MediaToken.refresh_token(old_token)

      assert is_binary(new_token)
      assert new_token != old_token
      assert new_claims["permissions"] == ["stream"]
    end

    test "rejects refresh of expired token", %{device: device} do
      # Create token that expires in 1 second
      {:ok, expired_token, claims} = MediaToken.create_token(device, ttl: {1, :second})

      # Verify the TTL was applied (exp should be about 1 second after iat)
      assert claims["exp"] - claims["iat"] <= 2

      # Wait for token to expire (allowed_drift is 0 in test config,
      # 2000ms for reliable expiry with second-precision JWT timestamps)
      Process.sleep(2000)

      assert {:error, :token_expired} = MediaToken.refresh_token(expired_token)
    end

    test "rejects refresh of revoked device token", %{device: device, token: token} do
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      assert {:error, :device_revoked} = MediaToken.refresh_token(token)
    end
  end

  describe "has_permission?/2" do
    test "returns true when permission exists" do
      claims = %{"permissions" => ["stream", "download"]}

      assert MediaToken.has_permission?(claims, "stream")
      assert MediaToken.has_permission?(claims, "download")
    end

    test "returns false when permission does not exist" do
      claims = %{"permissions" => ["stream"]}

      refute MediaToken.has_permission?(claims, "download")
      refute MediaToken.has_permission?(claims, "admin")
    end

    test "returns false when permissions key is missing" do
      claims = %{}

      refute MediaToken.has_permission?(claims, "stream")
    end
  end

  describe "device_active?/1" do
    setup do
      user = create_user()
      device = create_device(user)
      %{device: device}
    end

    test "returns true for non-revoked device", %{device: device} do
      assert MediaToken.device_active?(device)
    end

    test "returns false for revoked device", %{device: device} do
      revoked_device =
        device
        |> RemoteDevice.revoke_changeset()
        |> Repo.update!()

      refute MediaToken.device_active?(revoked_device)
    end
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
