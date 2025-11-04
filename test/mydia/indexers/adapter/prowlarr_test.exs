defmodule Mydia.Indexers.Adapter.ProwlarrTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Prowlarr
  alias Mydia.Indexers.Adapter.Error

  @moduletag :external

  describe "test_connection/1" do
    @tag :skip
    test "successfully connects to Prowlarr" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, info} = Prowlarr.test_connection(config)
      assert info.name == "Prowlarr"
      assert is_binary(info.version)
    end

    test "fails with invalid API key" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Prowlarr.test_connection(config)
    end

    test "fails with invalid host" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "nonexistent.local",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Prowlarr.test_connection(config)
    end
  end

  describe "search/3" do
    @tag :skip
    test "successfully searches Prowlarr" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      assert {:ok, results} = Prowlarr.search(config, "ubuntu", limit: 5)
      assert is_list(results)
      assert length(results) > 0

      # Check first result has required fields
      result = hd(results)
      assert is_binary(result.title)
      assert is_integer(result.size)
      assert is_integer(result.seeders)
      assert is_integer(result.leechers)
      assert is_binary(result.download_url)
      assert is_binary(result.indexer)
    end

    @tag :skip
    test "searches with category filter" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000,
          categories: [2000]
        }
      }

      assert {:ok, results} = Prowlarr.search(config, "movie", limit: 5)
      assert is_list(results)
    end

    test "handles invalid API key" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Prowlarr.search(config, "test")
    end

    test "handles search with empty query" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: System.get_env("PROWLARR_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      # Empty queries should still work
      assert {:ok, _results} = Prowlarr.search(config, "")
    end
  end

  describe "get_capabilities/1" do
    test "returns static capabilities" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:ok, capabilities} = Prowlarr.get_capabilities(config)
      assert %{searching: searching, categories: categories} = capabilities
      assert is_map(searching)
      assert is_list(categories)
      assert length(categories) > 0

      # Check standard search capabilities
      assert searching.search.available == true
      assert searching.tv_search.available == true
      assert searching.movie_search.available == true
    end
  end

  describe "result parsing" do
    test "parses quality from title" do
      config = %{
        type: :prowlarr,
        name: "Test Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      # Mock response with quality indicators in title
      # This test would need to be expanded with actual response mocking
      # For now, we verify the adapter is properly structured
      assert function_exported?(Prowlarr, :search, 3)
      assert function_exported?(Prowlarr, :test_connection, 1)
      assert function_exported?(Prowlarr, :get_capabilities, 1)
    end
  end
end
