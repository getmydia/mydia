defmodule Mydia.Indexers.SearchStats.NetworkTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchStats.Network

  test "accumulates across calls and is cleared by take_ms/0" do
    Network.reset()
    assert Network.take_ms() == nil

    Network.add(1_500_000)
    Network.add(700_000)
    assert Network.take_ms() == 2_200
    assert Network.take_ms() == nil
  end

  test "is per process" do
    Network.reset()
    Network.add(1_000_000)
    assert Task.async(fn -> Network.take_ms() end) |> Task.await() == nil
    assert Network.take_ms() == 1_000
  end

  test "counts requests until take_requests/0, and reset/0 clears both totals" do
    Network.reset()
    assert Network.take_requests() == nil

    Network.add_request()
    Network.add_request()
    Network.add_requests(3)
    Network.add_requests(0)
    assert Network.take_requests() == 5
    assert Network.take_requests() == nil

    Network.add(1_000_000)
    Network.add_request()
    Network.reset()
    assert Network.take_ms() == nil
    assert Network.take_requests() == nil
  end
end
