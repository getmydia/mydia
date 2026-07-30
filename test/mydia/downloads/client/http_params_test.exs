defmodule Mydia.Downloads.Client.HttpParamsTest do
  use ExUnit.Case, async: true

  describe "query param composition" do
    test "params set at merge time replace base params of the same key" do
      req =
        Req.new(base_url: "http://example.test", params: [page: 1])
        |> Req.merge(url: "/items", params: [page: 2])

      assert req.options.params == [page: 2]
    end

    test "params with distinct keys are both retained" do
      req =
        Req.new(base_url: "http://example.test", params: [page: 1])
        |> Req.merge(url: "/items", params: [limit: 50])

      assert Keyword.get(req.options.params, :limit) == 50
    end
  end
end
