defmodule Mydia.Indexers.NewznabEndpointTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.NewznabEndpoint

  test "defaults a missing or blank API path to /api" do
    assert {:ok, "/api"} = NewznabEndpoint.normalize_api_path(nil)
    assert {:ok, "/api"} = NewznabEndpoint.normalize_api_path("")
    assert {:ok, "/api"} = NewznabEndpoint.normalize_api_path("  ")
  end

  test "normalizes a configured API path to one leading slash" do
    assert {:ok, "/newznab/api"} =
             NewznabEndpoint.normalize_api_path("  //newznab/api  ")
  end

  test "rejects URL components Mydia must own" do
    assert {:error, _} = NewznabEndpoint.normalize_api_path("https://indexer.test/api")
    assert {:error, _} = NewznabEndpoint.normalize_api_path("/api?t=search")
    assert {:error, _} = NewznabEndpoint.normalize_api_path("/api#fragment")
  end

  test "joins deployment prefixes and API paths exactly once" do
    assert {:ok, "/api"} = NewznabEndpoint.join(nil, "/api")
    assert {:ok, "/proxy/api"} = NewznabEndpoint.join("/proxy/", "api")

    assert {:ok, "/proxy/newznab/api"} =
             NewznabEndpoint.join("/proxy", "/newznab/api")
  end
end
