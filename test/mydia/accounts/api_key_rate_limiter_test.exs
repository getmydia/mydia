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

  describe "reserve_attempt/2" do
    test "admits attempts up to max_attempts and rejects after" do
      ip = "192.168.1.50"

      for _i <- 1..10 do
        assert :ok = ApiKeyRateLimiter.reserve_attempt(ip)
      end

      assert {:error, :rate_limited} = ApiKeyRateLimiter.reserve_attempt(ip)
    end

    test "counts against the same bucket record_failed_attempt/2 and check_rate_limit/2 use" do
      ip = "192.168.1.51"

      for _i <- 1..5 do
        assert :ok = ApiKeyRateLimiter.reserve_attempt(ip)
      end

      for _i <- 1..5 do
        ApiKeyRateLimiter.record_failed_attempt(ip)
      end

      assert {:error, :rate_limited} = ApiKeyRateLimiter.check_rate_limit(ip)
    end

    test "respects a custom max_attempts and window_seconds" do
      ip = "192.168.1.52"
      opts = [max_attempts: 2, window_seconds: 60]

      assert :ok = ApiKeyRateLimiter.reserve_attempt(ip, opts)
      assert :ok = ApiKeyRateLimiter.reserve_attempt(ip, opts)
      assert {:error, :rate_limited} = ApiKeyRateLimiter.reserve_attempt(ip, opts)
    end

    test "still admits and counts the attempt against a bucket that was just reset" do
      # reserve_attempt/2's window-expiry fallback used to call
      # :ets.update_counter/3 with no default tuple when it lost the
      # select_replace race, which raises ArgumentError against a bucket
      # that no longer exists (e.g. a concurrent reset_rate_limit/1 or
      # cleanup_expired/0 deleted it between reserve_attempt/2's own read
      # and its replace attempt). That exact interleaving cannot be forced
      # deterministically from a test -- it depends on two processes
      # racing inside a few consecutive ETS calls -- so this instead proves
      # the documented, reachable case: reserve_attempt/2 must not crash
      # and must still count the attempt when called against an absent
      # bucket.
      ip = "192.168.1.55"
      storage_key = "api_key_validation:#{ip}"

      ApiKeyRateLimiter.reset_rate_limit(ip)
      refute :ets.member(:api_key_rate_limiter, storage_key)

      assert :ok = ApiKeyRateLimiter.reserve_attempt(ip)

      assert [{^storage_key, 1, _first_attempt_at, _window_seconds}] =
               :ets.lookup(:api_key_rate_limiter, storage_key)
    end
  end

  describe "reserve_attempt/2 under concurrency" do
    # The whole point of reserve_attempt/2: check-then-record lets N parallel
    # callers all read "under the limit" before any of them has written
    # anything, so all N get admitted no matter how far past max_attempts N
    # is. Incrementing first and admitting only if the post-increment count is
    # still within the limit closes that window.
    test "admits exactly max_attempts callers out of many concurrent reservations" do
      ip = "192.168.1.53"
      max_attempts = 10

      ApiKeyRateLimiter.reset_rate_limit(ip)

      results =
        1..50
        |> Task.async_stream(
          fn _ -> ApiKeyRateLimiter.reserve_attempt(ip, max_attempts: max_attempts) end,
          max_concurrency: 50,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      admitted = Enum.count(results, &(&1 == :ok))
      rejected = Enum.count(results, &(&1 == {:error, :rate_limited}))

      assert admitted == max_attempts
      assert rejected == 50 - max_attempts

      ApiKeyRateLimiter.reset_rate_limit(ip)
    end
  end

  describe "record_failed_attempt/2 under concurrency" do
    # A brute-force limit that loses increments when guesses arrive in parallel
    # is a limit an attacker gets to raise by simply opening more connections.
    # record_failed_attempt/2 used to read the counter and write it back as two
    # separate ETS operations, so simultaneous attempts on the same bucket all
    # read the same value and all stored that value plus one -- N guesses
    # counted as one. Every attempt must land exactly once.
    test "counts every concurrent attempt exactly once" do
      ip = "192.168.1.99"
      storage_key = "api_key_validation:#{ip}"
      attempts = 200

      ApiKeyRateLimiter.reset_rate_limit(ip)

      1..attempts
      |> Task.async_stream(fn _ -> ApiKeyRateLimiter.record_failed_attempt(ip) end,
        max_concurrency: 50,
        timeout: :infinity
      )
      |> Stream.run()

      assert [{^storage_key, recorded, _first_attempt_at, _window}] =
               :ets.lookup(:api_key_rate_limiter, storage_key)

      assert recorded == attempts

      ApiKeyRateLimiter.reset_rate_limit(ip)
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
