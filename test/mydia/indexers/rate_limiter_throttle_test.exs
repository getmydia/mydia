defmodule Mydia.Indexers.RateLimiterThrottleTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.RateLimiter

  defp unique_id, do: "throttle-#{System.unique_integer([:positive])}"

  test "the first call and a zero delay return immediately" do
    id = unique_id()
    {us, :ok} = :timer.tc(fn -> RateLimiter.throttle(id, 500) end)
    assert us < 100_000
    {us, :ok} = :timer.tc(fn -> RateLimiter.throttle(unique_id(), 0) end)
    assert us < 100_000
  end

  test "a second call waits out the delay" do
    id = unique_id()
    RateLimiter.throttle(id, 200)
    {us, :ok} = :timer.tc(fn -> RateLimiter.throttle(id, 200) end)
    assert us >= 180_000
  end

  test "concurrent callers queue up one delay apart" do
    id = unique_id()

    {us, _} =
      :timer.tc(fn ->
        1..3
        |> Enum.map(fn _ -> Task.async(fn -> RateLimiter.throttle(id, 150) end) end)
        |> Task.await_many()
      end)

    # Slots at 0, 150 and 300 ms.
    assert us >= 270_000
  end

  test "throttle state does not disturb the sliding-window counters" do
    id = unique_id()
    RateLimiter.throttle(id, 10)
    assert RateLimiter.check_rate_limit(id, 1) == :ok
    assert RateLimiter.get_stats(id).requests_last_minute == 0
  end

  describe "throttle/3" do
    test "refuses a slot beyond max_wait and leaves the slot unconsumed" do
      id = unique_id()
      :ok = RateLimiter.throttle(id, 400)

      assert {:error, :over_budget} = RateLimiter.throttle(id, 400, 50)
      assert {:error, :over_budget} = RateLimiter.throttle(id, 400, 50)

      # The refused calls took nothing: the next real caller still gets the
      # slot one delay after the first call, not two.
      {us, :ok} = :timer.tc(fn -> RateLimiter.throttle(id, 400) end)
      assert us >= 300_000
      assert us < 600_000
    end

    test "sleeps and returns :ok when the slot is within max_wait" do
      id = unique_id()
      :ok = RateLimiter.throttle(id, 200)
      {us, result} = :timer.tc(fn -> RateLimiter.throttle(id, 200, 1_000) end)
      assert result == :ok
      assert us >= 150_000
    end

    test "the first call and a zero delay return immediately" do
      assert :ok = RateLimiter.throttle(unique_id(), 500, 0)
      assert :ok = RateLimiter.throttle(unique_id(), 0, 0)
    end
  end
end
