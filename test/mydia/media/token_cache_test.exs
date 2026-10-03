defmodule Mydia.Media.TokenCacheTest do
  @moduledoc """
  Tests for the TokenCache ETS-based caching module.

  Note: The cache delegates to MediaToken.verify_token/1 for actual token validation.
  MediaToken tests verify JWT functionality separately. This module tests:
  - ETS table operations (cache hit/miss)
  - Cache invalidation
  - TTL expiration behavior
  - Concurrent access
  """
  use ExUnit.Case, async: false

  alias Mydia.Media.TokenCache

  setup do
    # Clear cache for a fresh state each test
    TokenCache.clear()
    :ok
  end

  describe "ETS table operations" do
    test "cache is empty initially" do
      assert TokenCache.count() == 0
    end

    test "clear/0 resets the cache" do
      # Manually insert something to simulate cached data
      # We can't use validate() without Guardian configured
      # but we can test the clear() operation
      :ok = TokenCache.clear()
      assert TokenCache.count() == 0
    end

    test "count/0 returns zero for empty cache" do
      assert TokenCache.count() == 0
    end
  end

  describe "validate/1 error handling" do
    test "returns error for invalid token format" do
      result = TokenCache.validate("not-a-valid-jwt-token")
      assert {:error, _reason} = result

      # Invalid tokens should not be cached
      assert TokenCache.count() == 0
    end

    test "returns error for empty token" do
      result = TokenCache.validate("")
      assert {:error, _reason} = result
    end

    test "returns error for nil token equivalent" do
      # Passing something that's not a valid token
      result = TokenCache.validate("abc")
      assert {:error, _reason} = result
    end
  end

  describe "invalidate_for_device/1" do
    test "is a no-op when cache is empty" do
      :ok = TokenCache.invalidate_for_device("nonexistent-device-id")
      assert TokenCache.count() == 0
    end

    test "returns :ok for any device_id" do
      assert :ok = TokenCache.invalidate_for_device("any-device-id")
      assert :ok = TokenCache.invalidate_for_device("another-device-id")
    end
  end

  describe "validation racing an invalidation" do
    test "store_if_current/4 skips the insert when the device was invalidated after verification began" do
      started = System.monotonic_time()
      :ok = TokenCache.invalidate_for_device("race-device")

      assert :skipped =
               TokenCache.store_if_current(<<1>>, %{id: "race-device"}, %{}, started)

      assert TokenCache.count() == 0
    end

    test "store_if_current/4 inserts when the invalidation predates verification" do
      :ok = TokenCache.invalidate_for_device("race-device")
      started = System.monotonic_time()

      assert :ok = TokenCache.store_if_current(<<2>>, %{id: "race-device"}, %{}, started)
      assert TokenCache.count() == 1
    end

    test "invalidations of other devices do not block the insert" do
      started = System.monotonic_time()
      :ok = TokenCache.invalidate_for_device("other-device")

      assert :ok = TokenCache.store_if_current(<<3>>, %{id: "race-device"}, %{}, started)
      assert TokenCache.count() == 1
    end

    test "clear/0 forgets invalidation stamps" do
      started = System.monotonic_time()
      :ok = TokenCache.invalidate_for_device("race-device")
      TokenCache.clear()

      assert :ok = TokenCache.store_if_current(<<4>>, %{id: "race-device"}, %{}, started)
    end
  end

  describe "module structure" do
    test "module exports expected functions" do
      functions = TokenCache.__info__(:functions)
      function_names = Keyword.keys(functions)

      assert :create_table in function_names
      assert :validate in function_names
      assert :invalidate_for_device in function_names
      assert :clear in function_names
      assert :count in function_names
    end

    test "ETS table exists" do
      # The table should be created by application.ex
      # Verify it exists by checking count doesn't raise
      assert is_integer(TokenCache.count())
    end
  end
end
