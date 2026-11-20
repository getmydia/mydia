defmodule Mydia.Indexers.RateLimiterCooldownTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.RateLimiter

  defp unique_id, do: "cooldown-#{System.unique_integer([:positive])}"

  defp ms_from_now(%DateTime{} = until),
    do: DateTime.diff(until, DateTime.utc_now(), :millisecond)

  describe "record_rate_limited/2" do
    test "a first 429 cools down for one ladder step" do
      id = unique_id()
      until = RateLimiter.record_rate_limited(id, nil)
      assert_in_delta ms_from_now(until), 60_000, 1_000
      assert RateLimiter.cooldown_until(id) == until
    end

    test "Retry-After of 0 still waits one ladder step" do
      id = unique_id()
      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, 0)), 60_000, 1_000
    end

    test "a 429 during an active cooldown does not step" do
      id = unique_id()
      first = RateLimiter.record_rate_limited(id, nil)
      second = RateLimiter.record_rate_limited(id, nil)

      assert_in_delta DateTime.diff(second, first, :millisecond), 0, 1_000
      assert_in_delta ms_from_now(second), 60_000, 1_000
    end

    test "a 429 after expiry steps to 5 minutes" do
      id = unique_id()
      RateLimiter.record_rate_limited(id, nil)
      RateLimiter.expire_cooldown(id)
      assert RateLimiter.cooldown_until(id) == nil

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 300_000, 1_000
    end

    test "the ladder stops at 6 hours" do
      id = unique_id()

      last =
        Enum.reduce(1..8, nil, fn _, _ ->
          until = RateLimiter.record_rate_limited(id, nil)
          RateLimiter.expire_cooldown(id)
          until
        end)

      assert_in_delta ms_from_now(last), 21_600_000, 1_000
    end

    test "Retry-After longer than the step wins" do
      id = unique_id()
      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, 120_000)), 120_000, 1_000
    end

    test "Retry-After is capped at 24 hours" do
      id = unique_id()

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, 200_000_000)),
                      86_400_000,
                      1_000
    end

    test "a noted hint is used when the error has none, once" do
      id = unique_id()
      :ok = RateLimiter.note_retry_after(id, 600_000)
      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 600_000, 1_000

      RateLimiter.expire_cooldown(id)
      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 300_000, 1_000
    end

    test "a shorter hint does not replace a longer fresh one" do
      id = unique_id()
      :ok = RateLimiter.note_retry_after(id, :timer.hours(1))
      :ok = RateLimiter.note_retry_after(id, 60_000)

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)),
                      :timer.hours(1),
                      1_000
    end

    test "a longer hint replaces a shorter one" do
      id = unique_id()
      :ok = RateLimiter.note_retry_after(id, 120_000)
      :ok = RateLimiter.note_retry_after(id, 600_000)

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 600_000, 1_000
    end

    test "a stale hint is replaced even by a shorter one" do
      id = unique_id()
      six_minutes_ago = System.monotonic_time(:millisecond) - :timer.minutes(6)
      :ok = RateLimiter.put_retry_hint(id, :timer.hours(1), six_minutes_ago)
      :ok = RateLimiter.note_retry_after(id, 600_000)

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 600_000, 1_000
    end

    test "a kept long hint stays fresh as of the newest note" do
      id = unique_id()
      now = System.monotonic_time(:millisecond)
      # Noted 301 s ago, so it would read stale by its own timestamp, but a
      # newer, shorter hint 2 s ago keeps its deadline and refreshes it.
      :ok = RateLimiter.put_retry_hint(id, :timer.hours(1), now - 301_000)
      :ok = RateLimiter.put_retry_hint(id, 600_000, now - 2_000)

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)),
                      :timer.hours(1) - 301_000,
                      1_000
    end

    test "a hint older than 5 minutes is ignored" do
      id = unique_id()
      six_minutes_ago = System.monotonic_time(:millisecond) - :timer.minutes(6)
      :ok = RateLimiter.put_retry_hint(id, 600_000, six_minutes_ago)

      assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 60_000, 1_000
    end
  end

  test "success clears the cooldown and resets the ladder" do
    id = unique_id()
    assert RateLimiter.last_success_at(id) == nil
    RateLimiter.record_rate_limited(id, nil)

    assert RateLimiter.record_success(id) == :ok
    assert RateLimiter.cooldown_until(id) == nil
    assert_in_delta DateTime.diff(RateLimiter.last_success_at(id), DateTime.utc_now()), 0, 1

    assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 60_000, 1_000
  end

  describe "take_search_slot/2" do
    test "no limit always allows" do
      id = unique_id()
      assert RateLimiter.take_search_slot(id, nil) == :ok
      assert RateLimiter.take_search_slot(id, 0) == :ok
      assert RateLimiter.take_search_slot(id, -1) == :ok
    end

    test "take_search_slot allows the limit then refuses" do
      id = unique_id()
      assert RateLimiter.take_search_slot(id, 2) == :ok
      assert RateLimiter.take_search_slot(id, 2) == :ok
      assert RateLimiter.take_search_slot(id, 2) == {:error, :limited, 2}
      assert RateLimiter.get_stats(id).requests_last_minute == 2
    end

    test "take_search_slot under concurrency never exceeds the limit" do
      id = unique_id()

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> RateLimiter.take_search_slot(id, 3) end) end)
        |> Task.await_many()

      oks = Enum.count(results, &(&1 == :ok))

      # reserve_window/3 lets racing callers both back off, so fewer than the
      # limit may pass, but never more, and refused callers leave no slot.
      assert oks <= 3
      assert RateLimiter.get_stats(id).requests_last_minute == oks
    end
  end

  test "clear_indexer drops cooldown, success and slots" do
    id = unique_id()
    :ok = RateLimiter.take_search_slot(id, 5)
    RateLimiter.record_success(id)
    RateLimiter.record_rate_limited(id, nil)
    RateLimiter.note_retry_after(id, 600_000)

    assert RateLimiter.clear_indexer(id) == :ok

    assert RateLimiter.cooldown_until(id) == nil
    assert RateLimiter.last_success_at(id) == nil
    assert RateLimiter.get_stats(id).requests_last_minute == 0
    # The hint went too: a fresh 429 waits one plain ladder step.
    assert_in_delta ms_from_now(RateLimiter.record_rate_limited(id, nil)), 60_000, 1_000
  end

  test "a success that clears a cooldown notifies subscribers, one with none does not" do
    id = unique_id()
    :ok = RateLimiter.subscribe_cooldowns()

    RateLimiter.record_rate_limited(id, nil)
    assert_receive {:indexer_cooldown, ^id}

    RateLimiter.record_success(id)
    assert_receive {:indexer_cooldown, ^id}

    RateLimiter.record_success(id)
    refute_receive {:indexer_cooldown, ^id}, 100
  end
end
