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

  describe "credential key shape" do
    # `definition.config` is a JsonMapType, so anything that has been through the
    # database comes back string-keyed, and the admin form supplies string keys
    # too. Reading only atom keys authenticated every private indexer with empty
    # credentials, which made the login fail and the probe report a failure the
    # tracker never caused.
    setup do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"

      yaml = """
      id: private-indexer
      name: Private Indexer
      description: A private test indexer
      language: en-US
      type: private
      encoding: UTF-8
      links:
        - #{base_url}
      caps:
        modes:
          search: {search-type: q}
        categories:
          5000: TV
      login:
        path: /login.php
        method: form
        inputs:
          username: "{{ .Config.username }}"
          password: "{{ .Config.password }}"
        test:
          selector: "a[href*=logout]"
      search:
        path: /search
        rows:
          selector: "table.results tr"
          after: 1
        fields:
          title:
            selector: "td.title a"
          size:
            selector: "td.size"
          seeders:
            selector: "td.seeders"
      """

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "private-indexer",
          name: "Private Indexer",
          description: "A private test indexer",
          language: "en-US",
          type: "private",
          encoding: "UTF-8",
          links: %{"0" => base_url},
          capabilities: %{modes: %{"search" => %{}}, categories: %{"5000" => "TV"}},
          definition: yaml,
          schema_version: "v11",
          enabled: true,
          # String keys, exactly as the database and the admin form supply them.
          config: %{"username" => "stringuser", "password" => "stringpass"},
          last_synced_at: DateTime.utc_now()
        })
        |> Repo.insert()

      %{bypass: bypass, private_definition: definition}
    end

    test "string-keyed credentials reach a form login", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:login_params, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=abc123; Path=/")
        |> Plug.Conn.resp(200, "<html><body><a href='/logout'>Logout</a></body></html>")
      end)

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(
          200,
          "<html><body><table class=\"results\"><tr><th>Header</th></tr></table></body></html>"
        )
      end)

      config = %{
        type: :cardigann,
        name: "Private Indexer",
        indexer_id: "private-indexer",
        user_settings: %{"username" => "stringuser", "password" => "stringpass"}
      }

      assert {:ok, _results} = Cardigann.search(config, "query")

      assert_receive {:login_params, params}
      assert params["username"] == "stringuser"
      assert params["password"] == "stringpass"
    end
  end

  describe "operator config override reaches the login request" do
    # Regression: get_or_create_session/3 built the credentials map passed to
    # CardigannAuth.authenticate/3 from config.user_settings alone, never from
    # definition.config. A login.path templated as {{ .Config.apiurl }} always
    # rendered to the setting's schema default, so an operator's override was
    # silently ignored and a login could be established against the wrong
    # host while a search (which does read definition.config) used the right
    # one. Two Bypasses stand in for "wrong host" (the setting default) and
    # "right host" (the operator override); the test proves which one the
    # login actually reached.
    test "a login-path setting's operator override, not its schema default, receives the login" do
      site = Bypass.open()
      override = Bypass.open()
      site_base_url = "http://localhost:#{site.port}"

      yaml = """
      id: login-override-indexer
      name: Login Override Indexer
      description: A private indexer whose login path is templated
      language: en-US
      type: private
      encoding: UTF-8
      links:
        - #{site_base_url}
      caps:
        modes:
          search: {search-type: q}
        categories:
          5000: TV
      settings:
        - name: apiurl
          type: text
          label: API URL
          default: localhost:1
      login:
        path: http://{{ .Config.apiurl }}/login.php
        method: form
        inputs:
          username: "{{ .Config.username }}"
          password: "{{ .Config.password }}"
        test:
          selector: "a[href*=logout]"
      search:
        path: /search
        rows:
          selector: "table.results tr"
          after: 1
        fields:
          title:
            selector: "td.title a"
          size:
            selector: "td.size"
          seeders:
            selector: "td.seeders"
      """

      {:ok, _definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "login-override-indexer",
          name: "Login Override Indexer",
          description: "A private indexer whose login path is templated",
          language: "en-US",
          type: "private",
          encoding: "UTF-8",
          links: %{"0" => site_base_url},
          capabilities: %{modes: %{"search" => %{}}, categories: %{"5000" => "TV"}},
          definition: yaml,
          schema_version: "v11",
          enabled: true,
          # String keys, exactly as the database and the admin form supply
          # them. apiurl deliberately does not match the setting's default
          # (localhost:1), so the rendered login URL can only hit `override`
          # if the adapter actually threads this map into the login render.
          config: %{
            "username" => "stringuser",
            "password" => "stringpass",
            "apiurl" => "localhost:#{override.port}"
          },
          last_synced_at: DateTime.utc_now()
        })
        |> Repo.insert()

      test_pid = self()

      Bypass.expect_once(override, "POST", "/login.php", fn conn ->
        send(test_pid, :login_hit)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=granted; Path=/")
        |> Plug.Conn.resp(200, "<html><body><a href='/logout'>Logout</a></body></html>")
      end)

      Bypass.stub(site, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(
          200,
          "<html><body><table class=\"results\"><tr><th>Header</th></tr></table></body></html>"
        )
      end)

      config = %{
        type: :cardigann,
        name: "Login Override Indexer",
        indexer_id: "login-override-indexer"
      }

      # The point of this test is which host received the login, not what
      # Cardigann.search/2 returns. If the login never reaches `override`,
      # Bypass.expect_once fails the test on exit regardless of this result.
      Cardigann.search(config, "query")

      assert_receive :login_hit
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

  describe "on_promote credential scope" do
    test "a legacy mirror that wins search failover does not become active_link when credentials are configured" do
      # Mirrors the health check's "a legacy mirror that answers is not
      # promoted" regression, but through the real search/2 path: the first
      # candidate (an in-scope links entry) is unreachable, execute_search
      # fails over to the second candidate (a legacylinks entry, out of
      # scope), and on_promote fires for it. With a credential configured on
      # the definition, that promotion must be withheld.
      dead = Bypass.open()
      Bypass.down(dead)

      legacy = Bypass.open()

      Bypass.stub(legacy, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(
          200,
          "<html><body><table class=\"results\"><tr><th>Header</th></tr></table></body></html>"
        )
      end)

      dead_url = "http://localhost:#{dead.port}"
      legacy_url = "http://localhost:#{legacy.port}"

      yaml = """
      id: legacy-promo
      name: Legacy Promo
      description: d
      language: en-US
      type: private
      encoding: UTF-8
      links:
        - #{dead_url}
      legacylinks:
        - #{legacy_url}
      caps:
        categories:
          2000: Movies
      settings: []
      search:
        paths:
          - path: /search
        rows:
          selector: tr
        fields:
          title:
            selector: td.title
          size:
            selector: td.size
          seeders:
            selector: td.seeders
          download:
            selector: a
            attribute: href
      """

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "legacy-promo",
          name: "Legacy Promo",
          type: "private",
          links: %{"0" => dead_url},
          capabilities: %{},
          schema_version: "v11",
          config: %{"username" => "me", "password" => "secret"},
          definition: yaml,
          enabled: true
        })
        |> Repo.insert()

      config = %{type: :cardigann, name: "Legacy Promo", indexer_id: "legacy-promo"}

      assert {:ok, _results} = Cardigann.search(config, "query")

      reloaded = Repo.reload!(definition)
      refute reloaded.active_link == legacy_url
      assert reloaded.active_link == nil
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
