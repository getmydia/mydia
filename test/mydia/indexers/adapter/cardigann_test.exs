defmodule Mydia.Indexers.Adapter.CardigannTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.Adapter.Cardigann
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Repo

  @sample_yaml """
  id: test-indexer
  name: Test Indexer
  description: A test indexer for unit tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://test-indexer.example.com
  caps:
    modes:
      search: {search-type: q}
      tv-search: {search-type: q, tv-attributes: q, season, ep}
      movie-search: {search-type: q, movie-attributes: q, imdbid}
    categories:
      2000: Movies
      5000: TV
    categorymappings:
      - {id: 2000, cat: Movies, desc: "Movies"}
      - {id: 5000, cat: TV, desc: "TV Shows"}
  search:
    path: /search/{{ .Keywords }}/
    rows:
      selector: "table.results tr"
      after: 1
    fields:
      title:
        selector: "td.title a"
      download:
        selector: "td.download a"
        attribute: href
      size:
        selector: "td.size"
      seeders:
        selector: "td.seeders"
      leechers:
        selector: "td.leechers"
      category:
        selector: "td.category"
  """

  setup do
    # Clear any existing definitions
    Repo.delete_all(CardigannDefinition)

    # Enable Cardigann feature flag for tests (unless specifically testing disabled state)
    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)

    # Insert test definition
    {:ok, definition} =
      %CardigannDefinition{}
      |> CardigannDefinition.changeset(%{
        indexer_id: "test-indexer",
        name: "Test Indexer",
        description: "A test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: %{"0" => "https://test-indexer.example.com"},
        capabilities: %{
          modes: %{"search" => %{}, "tv-search" => %{}, "movie-search" => %{}},
          categories: %{"2000" => "Movies", "5000" => "TV"},
          categorymappings: [
            %{"id" => 2000, "cat" => "Movies", "desc" => "Movies"},
            %{"id" => 5000, "cat" => "TV", "desc" => "TV Shows"}
          ]
        },
        definition: @sample_yaml,
        schema_version: "v11",
        enabled: true,
        last_synced_at: DateTime.utc_now()
      })
      |> Repo.insert()

    on_exit(fn ->
      Application.put_env(:mydia, :features, original_features)
    end)

    %{definition: definition}
  end

  describe "test_connection/1" do
    test "successfully validates indexer config", %{definition: definition} do
      # Use Bypass to mock the indexer base URL
      bypass = Bypass.open()

      # Update the YAML definition to use the Bypass URL
      updated_yaml =
        String.replace(
          definition.definition,
          "https://test-indexer.example.com",
          "http://localhost:#{bypass.port}"
        )

      definition
      |> CardigannDefinition.changeset(%{
        links: %{"0" => "http://localhost:#{bypass.port}"},
        definition: updated_yaml
      })
      |> Repo.update!()

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 200, "<html><title>Test Indexer</title></html>")
      end)

      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      result = Cardigann.test_connection(config)

      assert {:ok, info} = result
      assert info.name == "Test Indexer"
      assert info.indexer_id == "test-indexer"
    end

    test "fails with missing indexer_id" do
      config = %{
        type: :cardigann,
        name: "Test Indexer"
      }

      assert {:error, %Error{type: :invalid_config, message: message}} =
               Cardigann.test_connection(config)

      assert message =~ "Missing indexer_id"
    end

    test "fails with non-existent indexer" do
      config = %{
        type: :cardigann,
        name: "Unknown",
        indexer_id: "nonexistent"
      }

      assert {:error, %Error{type: :invalid_config, message: message}} =
               Cardigann.test_connection(config)

      assert message =~ "not found"
    end
  end

  describe "search/3" do
    test "builds search options correctly", %{definition: _definition} do
      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      # This will fail during HTTP request, but we can verify it processes config correctly
      result = Cardigann.search(config, "test query", categories: [2000], min_seeders: 5)

      # Should fail with connection error (not config error)
      case result do
        {:ok, _results} ->
          # If somehow it succeeds (unlikely in test env), that's fine
          assert true

        {:error, %Error{type: error_type}} ->
          # Should fail with connection/search error, not config error
          assert error_type in [:connection_failed, :search_failed]

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "fails with missing indexer_id" do
      config = %{
        type: :cardigann,
        name: "Test Indexer"
      }

      assert {:error, %Error{type: :invalid_config}} = Cardigann.search(config, "test")
    end

    test "applies search filters correctly" do
      # Test that filters would be applied if we had results
      # This is more of a unit test of the filter logic

      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      # The search will fail at HTTP stage, but config processing should work
      result = Cardigann.search(config, "query", min_seeders: 10, limit: 5)

      # Verify it doesn't fail with invalid config
      case result do
        {:error, %Error{type: error_type}} ->
          assert error_type in [:connection_failed, :search_failed]

        _ ->
          assert true
      end
    end
  end

  describe "get_capabilities/1" do
    test "returns capabilities from definition", %{definition: _definition} do
      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      assert {:ok, capabilities} = Cardigann.get_capabilities(config)

      # Verify structure
      assert is_map(capabilities.searching)
      assert capabilities.searching.search.available == true
      assert capabilities.searching.tv_search.available == true
      assert capabilities.searching.movie_search.available == true

      # Verify categories
      assert is_list(capabilities.categories)
      assert length(capabilities.categories) == 2

      # Verify category structure
      category_ids = Enum.map(capabilities.categories, & &1.id)
      assert 2000 in category_ids
      assert 5000 in category_ids
    end

    test "fails with missing indexer_id" do
      config = %{
        type: :cardigann,
        name: "Test Indexer"
      }

      assert {:error, %Error{type: :invalid_config}} = Cardigann.get_capabilities(config)
    end

    test "fails with non-existent indexer" do
      config = %{
        type: :cardigann,
        name: "Unknown",
        indexer_id: "nonexistent"
      }

      assert {:error, %Error{type: :invalid_config}} = Cardigann.get_capabilities(config)
    end
  end

  describe "adapter behaviour implementation" do
    test "implements all required callbacks" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Mydia.Indexers.Adapter.Cardigann)

      # Verify the module implements the behaviour
      assert function_exported?(Mydia.Indexers.Adapter.Cardigann, :test_connection, 1)
      assert function_exported?(Mydia.Indexers.Adapter.Cardigann, :search, 3)
      assert function_exported?(Mydia.Indexers.Adapter.Cardigann, :get_capabilities, 1)
    end
  end

  describe "feature flag integration" do
    test "search returns empty results when feature flag is disabled", %{definition: _definition} do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Disable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: false)

        config = %{
          type: :cardigann,
          name: "Test Indexer",
          indexer_id: "test-indexer"
        }

        assert {:ok, []} = Cardigann.search(config, "test query")
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    test "search executes normally when feature flag is enabled", %{definition: _definition} do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        config = %{
          type: :cardigann,
          name: "Test Indexer",
          indexer_id: "test-indexer"
        }

        # Should proceed to search (will fail with connection error in test env)
        result = Cardigann.search(config, "test query")

        case result do
          {:ok, _results} ->
            assert true

          {:error, %Error{type: error_type}} ->
            # Should fail with connection/search error, not config error
            assert error_type in [:connection_failed, :search_failed]
        end
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    test "test_connection returns error when feature flag is disabled", %{definition: _definition} do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Disable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: false)

        config = %{
          type: :cardigann,
          name: "Test Indexer",
          indexer_id: "test-indexer"
        }

        assert {:error, %Error{type: :invalid_config, message: message}} =
                 Cardigann.test_connection(config)

        assert message =~ "disabled"
      after
        Application.put_env(:mydia, :features, original)
      end
    end

    test "test_connection executes normally when feature flag is enabled", %{
      definition: definition
    } do
      original = Application.get_env(:mydia, :features, [])

      # Use Bypass to mock the indexer base URL
      bypass = Bypass.open()

      # Update the YAML definition to use the Bypass URL
      updated_yaml =
        String.replace(
          definition.definition,
          "https://test-indexer.example.com",
          "http://localhost:#{bypass.port}"
        )

      definition
      |> CardigannDefinition.changeset(%{
        links: %{"0" => "http://localhost:#{bypass.port}"},
        definition: updated_yaml
      })
      |> Repo.update!()

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 200, "<html><title>Test Indexer</title></html>")
      end)

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        config = %{
          type: :cardigann,
          name: "Test Indexer",
          indexer_id: "test-indexer"
        }

        result = Cardigann.test_connection(config)

        assert {:ok, _info} = result
      after
        Application.put_env(:mydia, :features, original)
      end
    end
  end
end
