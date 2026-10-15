defmodule Mydia.Indexers.Cardigann.SearchRequestTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.SearchRequest

  describe "after_throttle/2" do
    test "takes the time spent waiting off the receive timeout" do
      assert {:ok, %{receive_timeout: 700, method: :get}} =
               SearchRequest.after_throttle(%{receive_timeout: 1_000, method: :get}, 300)
    end

    test "reports the budget spent once the wait used all of it" do
      assert {:error, %Error{}} = SearchRequest.after_throttle(%{receive_timeout: 300}, 300)
      assert {:error, %Error{}} = SearchRequest.after_throttle(%{receive_timeout: 300}, 900)
    end

    test "leaves a request without a receive timeout untouched" do
      params = %{method: :get}
      assert {:ok, ^params} = SearchRequest.after_throttle(params, 5_000)
    end
  end

  describe "throttled/2" do
    test "charges the time the throttle took against the receive timeout" do
      assert {:ok, %{receive_timeout: left}} =
               SearchRequest.throttled(%{receive_timeout: 5_000}, fn ->
                 Process.sleep(60)
                 :ok
               end)

      assert left <= 4_940 and left > 0
    end

    test "passes a throttle error through and leaves a budgetless request alone" do
      assert {:error, :boom} =
               SearchRequest.throttled(%{receive_timeout: 5}, fn -> {:error, :boom} end)

      assert {:ok, %{method: :get}} = SearchRequest.throttled(%{method: :get}, fn -> :ok end)
    end
  end
end
