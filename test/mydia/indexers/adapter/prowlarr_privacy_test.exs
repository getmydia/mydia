defmodule Mydia.Indexers.Adapter.ProwlarrPrivacyTest do
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Adapter.ProwlarrPrivacy

  @table :prowlarr_indexer_privacy

  defp key, do: {:test, System.unique_integer([:positive])}

  defp counting_fetch(result, sleep_ms \\ 0) do
    counter = :counters.new(1, [])

    fetch = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(sleep_ms)
      result
    end

    {fetch, fn -> :counters.get(counter, 1) end}
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> retry(fun, tries)
    end
  end

  defp retry(fun, tries) do
    Process.sleep(20)
    eventually(fun, tries - 1)
  end

  test "a cold miss fetches once and the result is cached" do
    key = key()
    {fetch, calls} = counting_fetch({:ok, %{7 => true}})

    assert ProwlarrPrivacy.lookup(key, fetch) == %{7 => true}
    assert ProwlarrPrivacy.lookup(key, fetch) == %{7 => true}
    assert calls.() == 1
  end

  test "concurrent cold misses share one fetch" do
    key = key()
    {fetch, calls} = counting_fetch({:ok, %{7 => true}}, 200)

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> ProwlarrPrivacy.lookup(key, fetch) end) end)
      |> Enum.map(&Task.await/1)

    assert calls.() == 1
    assert %{7 => true} in results
    eventually(fn -> ProwlarrPrivacy.lookup(key, fetch) == %{7 => true} end)
    assert calls.() == 1
  end

  test "a slow fetch does not hold the search past wait_ms and still fills the cache" do
    key = key()
    {fetch, calls} = counting_fetch({:ok, %{7 => false}}, 300)

    {elapsed_us, result} = :timer.tc(fn -> ProwlarrPrivacy.lookup(key, fetch, 50) end)

    assert result == %{}
    # wait_ms is 50 and the fetch takes 300; 150 leaves scheduler slack while
    # still proving the caller did not wait for the fetch.
    assert elapsed_us < 150_000
    eventually(fn -> ProwlarrPrivacy.lookup(key, fetch, 50) == %{7 => false} end)
    assert calls.() == 1
  end

  test "an expired entry is served while one background fetch replaces it" do
    key = key()
    :ets.insert(@table, {key, %{7 => true}, System.monotonic_time(:millisecond) - 1})
    {fetch, calls} = counting_fetch({:ok, %{7 => false}}, 100)

    assert ProwlarrPrivacy.lookup(key, fetch) == %{7 => true}
    assert ProwlarrPrivacy.lookup(key, fetch) == %{7 => true}
    eventually(fn -> ProwlarrPrivacy.lookup(key, fetch) == %{7 => false} end)
    assert calls.() == 1
  end

  test "a failed fetch caches an empty map for five minutes, then fetches again" do
    key = key()
    {fetch, calls} = counting_fetch(:error)

    assert ProwlarrPrivacy.lookup(key, fetch) == %{}
    assert ProwlarrPrivacy.lookup(key, fetch) == %{}
    assert calls.() == 1

    [{^key, %{}, expires_at}] = :ets.lookup(@table, key)
    ttl = expires_at - System.monotonic_time(:millisecond)
    assert ttl > :timer.minutes(5) - 5_000 and ttl <= :timer.minutes(5)

    # Once that entry expires, the next lookup asks Prowlarr again.
    :ets.insert(@table, {key, %{}, System.monotonic_time(:millisecond) - 1})
    assert ProwlarrPrivacy.lookup(key, fetch) == %{}
    eventually(fn -> calls.() == 2 end)
  end

  test "a successful fetch is cached for an hour" do
    key = key()
    {fetch, _calls} = counting_fetch({:ok, %{7 => true}})

    ProwlarrPrivacy.lookup(key, fetch)

    [{^key, _map, expires_at}] = :ets.lookup(@table, key)
    ttl = expires_at - System.monotonic_time(:millisecond)
    assert ttl > :timer.hours(1) - 5_000 and ttl <= :timer.hours(1)
  end

  describe "in-flight marker" do
    test "a marker left by a killed fetch is taken over once it is old" do
      key = key()
      old = System.monotonic_time(:millisecond) - :timer.minutes(1)
      :ets.insert(@table, {{:in_flight, key}, {old, make_ref()}})
      {fetch, calls} = counting_fetch({:ok, %{7 => true}})

      assert ProwlarrPrivacy.lookup(key, fetch) == %{7 => true}
      assert calls.() == 1
      eventually(fn -> :ets.lookup(@table, {:in_flight, key}) == [] end)
    end

    test "a recent marker means a fetch is running, so no second one starts" do
      key = key()
      :ets.insert(@table, {{:in_flight, key}, {System.monotonic_time(:millisecond), make_ref()}})
      {fetch, calls} = counting_fetch({:ok, %{7 => true}})

      assert ProwlarrPrivacy.lookup(key, fetch) == %{}
      assert calls.() == 0
      :ets.delete(@table, {:in_flight, key})
    end

    test "a stalled fetch finishing after a takeover leaves the new owner alone" do
      key = key()
      {stalled, calls} = counting_fetch({:ok, %{7 => :stale}}, 200)

      # The stalled fetch claims the key; the caller stops waiting at once.
      assert ProwlarrPrivacy.lookup(key, stalled, 0) == %{}

      # Another caller takes the marker over and caches a newer map.
      newer = {System.monotonic_time(:millisecond), make_ref()}
      :ets.insert(@table, {{:in_flight, key}, newer})
      fresh_until = System.monotonic_time(:millisecond) + :timer.hours(1)
      :ets.insert(@table, {key, %{7 => true}, fresh_until})

      eventually(fn -> calls.() == 1 end)
      # Let the stalled fetch run its store and cleanup.
      Process.sleep(300)

      assert :ets.lookup(@table, {:in_flight, key}) == [{{:in_flight, key}, newer}]
      assert :ets.lookup(@table, key) == [{key, %{7 => true}, fresh_until}]
      :ets.delete(@table, {:in_flight, key})
    end
  end
end
