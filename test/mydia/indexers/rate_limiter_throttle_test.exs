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
end
