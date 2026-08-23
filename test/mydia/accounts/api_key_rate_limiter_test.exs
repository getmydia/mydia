defmodule Mydia.Accounts.ApiKeyRateLimiterTest do
  use ExUnit.Case, async: false

  alias Mydia.Accounts.ApiKeyRateLimiter

  setup do
    # Start the rate limiter if it's not already running
    case Process.whereis(ApiKeyRateLimiter) do
      nil -> start_supervised!(ApiKeyRateLimiter)
      _pid -> :ok
    end

    # Clean up any previous test data
    ApiKeyRateLimiter.reset_rate_limit("test-ip-1")
    ApiKeyRateLimiter.reset_rate_limit("test-ip-2")

    :ok
  end

  describe "check_rate_limit/1" do
    test "allows requests when no previous attempts" do
      assert :ok = ApiKeyRateLimiter.check_rate_limit("192.168.1.1")
    end

    test "allows requests under the limit" do
      ip = "192.168.1.2"

      # Make 9 failed attempts (limit is 10)
      for _i <- 1..9 do
        ApiKeyRateLimiter.record_failed_attempt(ip)
      end

      assert :ok = ApiKeyRateLimiter.check_rate_limit(ip)
    end

    test "blocks requests after exceeding limit" do
      ip = "192.168.1.3"

      # Make 10 failed attempts (max limit)
      for _i <- 1..10 do
        ApiKeyRateLimiter.record_failed_attempt(ip)
      end

      assert {:error, :rate_limited} = ApiKeyRateLimiter.check_rate_limit(ip)
    end

    test "different IPs are tracked independently" do
      # IP1 makes 10 attempts
      for _i <- 1..10 do
        ApiKeyRateLimiter.record_failed_attempt("192.168.1.4")
      end

      # IP1 should be blocked
      assert {:error, :rate_limited} = ApiKeyRateLimiter.check_rate_limit("192.168.1.4")

      # IP2 should still be allowed
      assert :ok = ApiKeyRateLimiter.check_rate_limit("192.168.1.5")
    end
  end

  describe "record_failed_attempt/1" do
    test "records failed attempts" do
      ip = "192.168.1.6"

      assert :ok = ApiKeyRateLimiter.check_rate_limit(ip)

      # Record one failed attempt
      ApiKeyRateLimiter.record_failed_attempt(ip)

      # Should still be allowed (under limit)
      assert :ok = ApiKeyRateLimiter.check_rate_limit(ip)
    end

    test "increments attempt counter" do
      ip = "192.168.1.7"

      # Record 10 attempts
      for _i <- 1..10 do
        ApiKeyRateLimiter.record_failed_attempt(ip)
      end

      # Should now be blocked
      assert {:error, :rate_limited} = ApiKeyRateLimiter.check_rate_limit(ip)
    end
  end

  describe "reset_rate_limit/1" do
    test "resets the rate limit for an IP" do
      ip = "192.168.1.8"

      # Make 10 failed attempts
      for _i <- 1..10 do
        ApiKeyRateLimiter.record_failed_attempt(ip)
      end

      # Should be blocked
      assert {:error, :rate_limited} = ApiKeyRateLimiter.check_rate_limit(ip)

      # Reset the limit
      ApiKeyRateLimiter.reset_rate_limit(ip)

      # Should now be allowed
      assert :ok = ApiKeyRateLimiter.check_rate_limit(ip)
    end
  end

  describe "cleanup_expired/0" do
    test "removes expired entries" do
      # This test would require mocking time or waiting for the window to expire
      # For now, just verify the function can be called without error
      assert :ok = ApiKeyRateLimiter.cleanup_expired()
    end

    test "does not clear a bucket before its own configured window elapses" do
      # cleanup_expired/0 used to always compare against the module's
      # hardcoded 3600s default, ignoring any custom `:window_seconds` a
      # caller passed to record_failed_attempt/2. A bucket configured with a
      # longer window (e.g. 7200s) would get swept away once it crossed the
      # 3600s mark, letting a still-supposed-to-be-locked-out caller back in
      # well before its actual window expired. The bucket must now persist
      # its own window alongside the attempt count so cleanup can honor it.
      ip = "192.168.1.42"
      window_seconds = 7200
      storage_key = "api_key_validation:#{ip}"

      for _i <- 1..10 do
        ApiKeyRateLimiter.record_failed_attempt(ip, window_seconds: window_seconds)
      end

      assert {:error, :rate_limited} =
               ApiKeyRateLimiter.check_rate_limit(ip, window_seconds: window_seconds)

      assert [{^storage_key, attempts, _first_attempt_at, stored_window}] =
               :ets.lookup(:api_key_rate_limiter, storage_key)

      assert stored_window == window_seconds

      # Back-date the bucket past the hardcoded 3600s default cleanup
      # window, but still inside the 7200s window it was actually
      # configured with.
      backdated_first_attempt_at = System.system_time(:second) - 4000

      :ets.insert(
        :api_key_rate_limiter,
        {storage_key, attempts, backdated_first_attempt_at, stored_window}
      )

      assert :ok = ApiKeyRateLimiter.cleanup_expired()

      # Still within the bucket's own 7200s window: cleanup must not have
      # cleared it early, so the lockout must still be in effect.
      assert {:error, :rate_limited} =
               ApiKeyRateLimiter.check_rate_limit(ip, window_seconds: window_seconds)
    end
  end
end
