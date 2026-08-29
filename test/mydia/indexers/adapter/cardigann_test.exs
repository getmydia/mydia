defmodule Mydia.Indexers.Adapter.CardigannTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.Adapter.Cardigann
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Repo

  defp sample_yaml(base_url) do
    """
    id: test-indexer
    name: Test Indexer
    description: A test indexer for unit tests
    language: en-US
    type: public
    encoding: UTF-8
    links:
      - #{base_url}
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
  end

  setup do
    # Clear any existing definitions
    Repo.delete_all(CardigannDefinition)

    # Enable Cardigann feature flag for tests (unless specifically testing disabled state)
    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)

    # Use Bypass to avoid real HTTP connections during test_connection/search
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    # Stub the root path for test_connection reachability check
    Bypass.stub(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "OK")
    end)

    # Stub search paths with empty HTML table (Cardigann parses HTML from search results).
    # "The%20Matrix" is the health check's own probe query (this definition declares
    # movie-search, so test_indexer_reachable/2 now runs a real search against it
    # instead of only fetching "/") rather than a query any of these tests submit.
    for query <- ["test+query", "test%20query", "query", "The%20Matrix"] do
      Bypass.stub(bypass, "GET", "/search/#{query}/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(
          200,
          "<html><body><table class=\"results\"><tr><th>Header</th></tr></table></body></html>"
        )
      end)
    end

    # Insert test definition with Bypass URL
    {:ok, definition} =
      %CardigannDefinition{}
      |> CardigannDefinition.changeset(%{
        indexer_id: "test-indexer",
        name: "Test Indexer",
        description: "A test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: %{"0" => base_url},
        capabilities: %{
          modes: %{"search" => %{}, "tv-search" => %{}, "movie-search" => %{}},
          categories: %{"2000" => "Movies", "5000" => "TV"},
          categorymappings: [
            %{"id" => 2000, "cat" => "Movies", "desc" => "Movies"},
            %{"id" => 5000, "cat" => "TV", "desc" => "TV Shows"}
          ]
        },
        definition: sample_yaml(base_url),
        schema_version: "v11",
        enabled: true,
        last_synced_at: DateTime.utc_now()
      })
      |> Repo.insert()

    on_exit(fn ->
      Application.put_env(:mydia, :features, original_features)
    end)

    %{definition: definition, bypass: bypass}
  end

  describe "test_connection/1" do
    test "successfully validates indexer config", %{definition: _definition} do
      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      assert {:ok, info} = Cardigann.test_connection(config)
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

    # Regression: test_indexer_reachable/3 used to probe with only
    # definition.config, never building the authenticated session
    # get_or_create_session/3 builds for a real search. A private indexer
    # with a stored session - established the same way a real search
    # establishes one - searched successfully because its cookies rode along
    # on every real search, while Test reported a connection failure because
    # the probe's HTTP request carried no Cookie header at all.
    test "carries a stored session's cookies into the probe search request", %{
      definition: definition,
      bypass: bypass
    } do
      Bypass.stub(bypass, "GET", "/search/The%20Matrix/", fn conn ->
        case Plug.Conn.get_req_header(conn, "cookie") do
          ["sessionid=letmein123"] ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.resp(
              200,
              "<html><body><table class=\"results\"><tr><th>Header</th></tr></table></body></html>"
            )

          _ ->
            Plug.Conn.resp(conn, 401, "Unauthorized")
        end
      end)

      {:ok, _session} =
        %CardigannSearchSession{}
        |> CardigannSearchSession.changeset(%{
          cardigann_definition_id: definition.id,
          cookies: ["sessionid=letmein123"],
          expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      assert {:ok, _info} = Cardigann.test_connection(config)
    end
  end

  describe "search/3" do
    test "builds search options correctly", %{definition: _definition} do
      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      # Bypass returns an empty HTML table, so search should succeed with no results
      assert {:ok, results} =
               Cardigann.search(config, "test query", categories: [2000], min_seeders: 5)

      assert is_list(results)
    end

    test "fails with missing indexer_id" do
      config = %{
        type: :cardigann,
        name: "Test Indexer"
      }

      assert {:error, %Error{type: :invalid_config}} = Cardigann.search(config, "test")
    end

    test "applies search filters correctly" do
      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      # Bypass returns empty results, verifying config processing doesn't error
      assert {:ok, results} = Cardigann.search(config, "query", min_seeders: 10, limit: 5)
      assert is_list(results)
    end

    # Regression for #192: an expired FlareSolverr session row used to make
    # get_flaresolverr_session/1 return {:error, :expired}, a value the cookie
    # store call site had no clause for (CaseClauseError). The session lookup now
    # collapses expired into :not_found, so an expired row is silently purged and
    # the search proceeds instead of crashing.
    test "search purges an expired FlareSolverr session and does not crash", %{
      definition: definition
    } do
      {:ok, expired_session} =
        %CardigannSearchSession{}
        |> CardigannSearchSession.changeset(%{
          cardigann_definition_id: definition.id,
          cookies: [%{"name" => "cf_clearance", "value" => "stale"}],
          expires_at:
            DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      config = %{
        type: :cardigann,
        name: "Test Indexer",
        indexer_id: "test-indexer"
      }

      assert {:ok, results} = Cardigann.search(config, "test query")
      assert is_list(results)

      # The expired row was deleted by the session lookup during the search.
      refute Repo.get(CardigannSearchSession, expired_session.id)
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

        # Should proceed to search (Bypass returns empty results)
        assert {:ok, results} = Cardigann.search(config, "test query")
        assert is_list(results)
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
      definition: _definition
    } do
      original = Application.get_env(:mydia, :features, [])

      try do
        # Enable feature flag
        Application.put_env(:mydia, :features, cardigann_enabled: true)

        config = %{
          type: :cardigann,
          name: "Test Indexer",
          indexer_id: "test-indexer"
        }

        # Should proceed to test connection (Bypass returns 200)
        assert {:ok, info} = Cardigann.test_connection(config)
        assert info.name == "Test Indexer"
      after
        Application.put_env(:mydia, :features, original)
      end
    end
  end

  describe "parsing template context" do
    test "applies keywordsfilters to Keywords before result parsing" do
      parsed = %Parsed{
        id: "kw-parse",
        name: "KW Parse",
        type: "public",
        links: ["https://example.com"],
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [
            %{name: "re_replace", args: ["\\b(19|20)\\d{2}\\b", ""]},
            %{name: "trim"}
          ],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      context =
        TemplateContext.build(parsed,
          query: "The Matrix 1999",
          config: %{"sort" => "seeders"}
        )

      assert context.keywords == "The Matrix"
      assert context.query.series == "The Matrix"
      assert context.config == %{"sort" => "seeders"}
    end
  end
end
