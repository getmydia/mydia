defmodule Mydia.Indexers.Adapter.JackettTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Jackett
  alias Mydia.Indexers.Adapter.Error

  # Previously the whole module was tagged :external, which excluded every
  # test by default (including the Bypass-driven, fully offline ones). The
  # legitimately-network-dependent tests are already individually tagged
  # `:skip`, so no module-level gate is needed.

  describe "test_connection/1" do
    @tag :skip
    test "successfully connects to Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, info} = Jackett.test_connection(config)
      assert info.name == "Jackett"
      assert info.app_name == "Jackett"
    end

    test "fails with invalid API key" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end

    test "fails with invalid host" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "nonexistent.local",
        port: 9117,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end
  end

  describe "search/3" do
    @tag :skip
    test "successfully searches Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      assert {:ok, results} = Jackett.search(config, "ubuntu", limit: 5)
      assert is_list(results)
      assert results != []

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
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{
          timeout: 30_000,
          categories: [2000]
        }
      }

      assert {:ok, results} = Jackett.search(config, "movie", limit: 5)
      assert is_list(results)
    end

    test "handles invalid API key" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "invalid-key",
        use_ssl: false,
        options: %{}
      }

      assert {:error, %Error{type: error_type}} = Jackett.search(config, "test")
      assert error_type in [:connection_failed, :search_failed]
    end

    @tag :skip
    test "handles search with empty query" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      # Empty queries should still work
      assert {:ok, _results} = Jackett.search(config, "")
    end
  end

  describe "get_capabilities/1" do
    @tag :skip
    test "fetches capabilities from Jackett" do
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: System.get_env("JACKETT_API_KEY", "test-api-key"),
        use_ssl: false,
        options: %{}
      }

      assert {:ok, capabilities} = Jackett.get_capabilities(config)
      assert %{searching: searching, categories: categories} = capabilities
      assert is_map(searching)
      assert is_list(categories)

      # Check standard search capabilities
      assert searching.search.available == true
      assert searching.tv_search.available == true
      assert searching.movie_search.available == true
    end
  end

  describe "adapter structure" do
    test "implements required callbacks" do
      # Verify the adapter is properly structured
      #
      # function_exported?/3 answers false for a module that has not been
      # loaded yet, so without this the assertion races on whether some
      # earlier test in the run happened to reference Jackett first.
      Code.ensure_loaded!(Jackett)

      assert function_exported?(Jackett, :search, 3)
      assert function_exported?(Jackett, :test_connection, 1)
      assert function_exported?(Jackett, :get_capabilities, 1)
    end
  end

  describe "XML parsing" do
    test "handles empty search results" do
      # This would need mocking to test properly
      # For now, verify the module exists and has the expected structure
      assert Code.ensure_loaded?(Jackett)
    end
  end

  describe "use_ssl defaults (GitHub issue #28)" do
    test "test_connection works without use_ssl key - fails gracefully" do
      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "test-api-key",
        options: %{}
      }

      # This should not crash with KeyError but return a connection error
      # (since there's no Jackett server running)
      assert {:error, %Error{type: :connection_failed}} = Jackett.test_connection(config)
    end

    test "search works without use_ssl key - fails gracefully" do
      # Config WITHOUT use_ssl key - simulates web UI config
      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: 9117,
        api_key: "test-api-key",
        options: %{}
      }

      # This should not crash with KeyError but return a connection/search error
      # (since there's no Jackett server running)
      assert {:error, %Error{type: error_type}} = Jackett.search(config, "test")
      assert error_type in [:connection_failed, :search_failed]
    end
  end

  describe "search/3 retry behavior" do
    setup do
      {:ok, bypass: Bypass.open()}
    end

    test "a failing search is attempted exactly once", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(500, "<error/>")
      end)

      config = %{
        type: :jackett,
        name: "Test Jackett",
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        use_ssl: false,
        options: %{timeout: 5_000}
      }

      assert {:error, _} = Jackett.search(config, "Ubuntu")

      assert Agent.get(counter, & &1) == 1,
             "expected exactly one attempt, Req retried a transient failure"
    end
  end
end
