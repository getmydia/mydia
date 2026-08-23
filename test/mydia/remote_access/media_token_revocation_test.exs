defmodule Mydia.RemoteAccess.MediaTokenRevocationTest do
  @moduledoc """
  Regression coverage for T-107: `Mydia.Media.TokenCache` used to serve cache
  hits for up to 5 minutes after a device was revoked or deleted, because
  nothing called `TokenCache.invalidate_for_device/1` on any revocation path.

  These tests go through the real cache (populated exactly the way
  `MydiaWeb.Plugs.MediaAuth` populates it, via `TokenCache.validate/1`) rather
  than asserting against `invalidate_for_device/1` in isolation, so a
  regression that calls the wrong device id, or omits the call on one of the
  three revocation paths, actually fails a test here.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Accounts
  alias Mydia.Media.TokenCache
  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.{MediaToken, RemoteDevice}

  setup do
    TokenCache.clear()
    :ok
  end

  describe "revoke_device/1" do
    test "immediately invalidates a cached token for that device, no TTL wait" do
      user = insert(:user)
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      # Populate the cache the same way MediaAuth does on a real request.
      assert {:ok, _device, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      assert {:ok, _} = RemoteAccess.revoke_device(device)

      # No cache hit should survive: the next validate/1 call must miss the
      # (now-invalidated) cache, fall through to the DB, and see revoked_at.
      assert {:error, :device_revoked} = TokenCache.validate(token)
    end
  end

  describe "delete_device/1" do
    test "immediately invalidates a cached token for that device" do
      user = insert(:user)
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, _device, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      assert {:ok, _} = RemoteAccess.delete_device(device)

      assert {:error, :device_not_found} = TokenCache.validate(token)
    end
  end

  describe "Accounts.delete_user/1" do
    test "invalidates cached tokens for the deleted user's devices" do
      # remote_devices.user_id cascades at the DB level (on_delete: :delete_all),
      # so this path revokes access without ever calling revoke_device/1 or
      # delete_device/1 -- it needs its own invalidation call.
      user = insert(:user)
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, _device, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      assert {:ok, _} = Accounts.delete_user(user)

      assert {:error, _reason} = TokenCache.validate(token)
    end
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
