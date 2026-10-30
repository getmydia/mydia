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
    assert elapsed_us < 250_000
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

  test "a failed fetch caches an empty map" do
    key = key()
    {fetch, calls} = counting_fetch(:error)

    assert ProwlarrPrivacy.lookup(key, fetch) == %{}
    assert ProwlarrPrivacy.lookup(key, fetch) == %{}
    assert calls.() == 1
  end
end
