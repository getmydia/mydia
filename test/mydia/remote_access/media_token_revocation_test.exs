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
  alias Mydia.Accounts.Scope
  alias Mydia.Media.TokenCache
  alias Mydia.MediaRequests
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

    test "does not invalidate the cache when the delete itself fails" do
      # Ordering regression: invalidation must happen *after* a successful
      # `Repo.delete/1`, not before it. `media_requests.requester_id` has
      # `on_delete: :restrict`, so deleting a user with a request on file
      # raises `Ecto.ConstraintError` instead of deleting anything.
      #
      # If invalidation ran before the delete (the bug this guards against),
      # the cache entry would already be gone by the time the raise happens,
      # even though the device row -- and the user -- were never actually
      # removed. Asserting the cache survives the failed call is the
      # deterministic half of the ordering fix: the true concurrent-request
      # race (a validate/1 call landing in the window between invalidation
      # and the delete) can't be reproduced without a race in the test
      # itself, so this instead pins down the observable, order-dependent
      # side effect.
      user = insert(:user)
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, _device, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      assert {:ok, _request} =
               MediaRequests.create_request(Scope.unrestricted(), %{
                 media_type: "movie",
                 title: "Blocking Request",
                 tmdb_id: System.unique_integer([:positive]),
                 requester_id: user.id
               })

      assert_raise Ecto.ConstraintError, fn ->
        Accounts.delete_user(user)
      end

      # Check the cache entry directly (not via validate/1, which would
      # transparently repopulate it on a miss and hide the bug): the delete
      # never committed, so under the fixed ordering nothing should have
      # invalidated it.
      assert TokenCache.count() == 1
    end
  end

  describe "Accounts.update_user_role/2" do
    test "a demoted admin's cached token resolves to their new role on the next request" do
      admin = insert(:user, role: "admin")
      device = create_device(admin)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, %{user: %{role: "admin"}}, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      {:ok, _} = Accounts.update_user_role(admin, %{role: "user"})

      assert TokenCache.count() == 0
      assert {:ok, %{user: %{role: "user"}}, _claims} = TokenCache.validate(token)
    end
  end

  describe "Accounts.update_user/2" do
    test "a role change empties the token cache" do
      admin = insert(:user, role: "admin")
      device = create_device(admin)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, _device, _claims} = TokenCache.validate(token)
      assert TokenCache.count() == 1

      {:ok, _} = Accounts.update_user(admin, %{role: "user"})

      assert TokenCache.count() == 0
    end

    test "an update that leaves the role alone keeps the cached token" do
      user = insert(:user, role: "user")
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device)

      assert {:ok, _device, _claims} = TokenCache.validate(token)

      {:ok, _} =
        Accounts.update_user(user, %{
          email: "renamed-#{System.unique_integer([:positive])}@example.com"
        })

      assert TokenCache.count() == 1
    end
  end

  describe "invalidation racing a cache insert" do
    test "a hit older than its device's invalidation stamp is re-verified" do
      admin = insert(:user, role: "admin")
      device = create_device(admin)
      {:ok, token, claims} = MediaToken.create_token(device)
      cache_key = :crypto.hash(:sha256, token)

      started = System.monotonic_time()
      {:ok, stale_device, _claims} = MediaToken.verify_token(token)
      assert :ok = TokenCache.store_if_current(cache_key, stale_device, claims, started)

      # The role changes and invalidation's stamp lands after the insert's
      # check, without its deletion scan reaching the entry.
      {:ok, _} = admin |> Ecto.Changeset.change(role: "user") |> Repo.update()
      :ets.insert(:media_token_cache_invalidations, {device.id, System.monotonic_time()})

      assert {:ok, %{user: %{role: "user"}}, _claims} = TokenCache.validate(token)
    end

    test "finish_validation re-verifies when a validation loses the race with an invalidation" do
      admin = insert(:user, role: "admin")
      device = create_device(admin)
      {:ok, token, claims} = MediaToken.create_token(device)
      cache_key = :crypto.hash(:sha256, token)

      started = System.monotonic_time()
      {:ok, stale_device, _stale_claims} = MediaToken.verify_token(token)

      # Role changes after verification but before the cache insert attempt
      {:ok, _} = admin |> Ecto.Changeset.change(role: "user") |> Repo.update()
      :ets.insert(:media_token_cache_invalidations, {device.id, System.monotonic_time()})

      # finish_validation should detect the race and re-verify, not cache the stale snapshot
      assert {:ok, %{user: %{role: "user"}}, _fresh_claims} =
               TokenCache.finish_validation(token, cache_key, stale_device, claims, started)

      # Nothing was cached because re-verification would re-run validate_and_cache
      assert TokenCache.count() == 0
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
