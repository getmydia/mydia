defmodule Mydia.Indexers.CardigannSearchEngineTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.Adapter.Error

  describe "build_search_url/2 with a search path that fails to render" do
    test "returns an Adapter.Error rather than the renderer's raw reason" do
      definition = %Parsed{
        id: "broken-path",
        name: "Broken Path",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search/{{ .Keywords "}], inputs: %{}}
      }

      assert {:error, %Error{}} = CardigannSearchEngine.build_search_url(definition, query: "x")
    end
  end

  describe "build_search_url/2" do
    test "keywords are percent-encoded in the definition's charset" do
      definition = %Parsed{
        id: "cp1251-test",
        name: "cp1251",
        links: ["https://example.invalid"],
        encoding: "windows-1251",
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/s/{{ .Keywords }}"}],
          inputs: %{},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, "https://example.invalid/s/%CF%F0%E8%E2%E5%F2"} =
               CardigannSearchEngine.build_search_url(definition, query: "Привет")
    end

    test "literal spaces in a path template are percent-encoded, existing escapes are kept" do
      definition = %Parsed{
        id: "path-test",
        name: "path",
        links: ["https://example.invalid"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "search/node/{{ .Keywords }} type:story%2Fx"}],
          inputs: %{},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, "https://example.invalid/search/node/a%20b%20type:story%2Fx"} =
               CardigannSearchEngine.build_search_url(definition, query: "a b")
    end

    test "characters Mint rejects in a request target are percent-encoded in static text" do
      definition = %Parsed{
        id: "path-unsafe-test",
        name: "path",
        links: ["https://example.invalid"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "s/\"{{ .Keywords }}\"<x>|y?q=1&r=2"}],
          inputs: %{},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, "https://example.invalid/s/%22ab%22%3Cx%3E%7Cy?q=1&r=2"} =
               CardigannSearchEngine.build_search_url(definition, query: "ab")
    end

    test "query inputs carry the definition's charset bytes" do
      definition = %Parsed{
        id: "cp1251-inputs",
        name: "cp1251",
        links: ["https://example.invalid"],
        encoding: "windows-1251",
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/s"}],
          inputs: %{"search" => "{{ .Keywords }}", "cat" => "0"},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, %{query_params: params}} =
               CardigannSearchEngine.build_request_params(definition, query: "Привет")

      assert params["search"] == <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>
      assert params["cat"] == "0"
    end

    test "builds URL with simple keyword substitution" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}/1/"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, url} =
               CardigannSearchEngine.build_search_url(definition, query: "Ubuntu 22.04")

      assert url == "https://example.com/search/Ubuntu%2022.04/1/"
    end

    test "builds URL with multiple template variables" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [
            %{
              path: "/search?q={{ .Keywords }}&cat={{ .Categories }}&season={{ .Query.Season }}"
            }
          ],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      opts = [query: "Breaking Bad", categories: [5000, 5030], season: 1]

      assert {:ok, url} = CardigannSearchEngine.build_search_url(definition, opts)
      assert url =~ "q=Breaking%20Bad"
      assert url =~ "cat=5000,5030"
      assert url =~ "season=1"
    end

    test "selects the first path whose site categories map to the query" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{
          modes: %{},
          categorymappings: [
            %{"id" => "1", "cat" => "Movies"},
            %{"id" => "2", "cat" => "TV"}
          ]
        },
        search: %{
          paths: [
            %{path: "/movies", categories: ["1"]},
            %{path: "/tv", categories: ["2"]},
            %{path: "/all"}
          ],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, "https://example.com/tv"} =
               CardigannSearchEngine.build_search_url(definition, categories: [5000])

      assert {:ok, "https://example.com/movies"} =
               CardigannSearchEngine.build_search_url(definition, categories: [2000])

      # /all has no categories, so it is the only path an unmapped query runs.
      assert {:ok, "https://example.com/all"} =
               CardigannSearchEngine.build_search_url(definition, categories: [8000])

      assert {:ok, [%{path: "/movies"}, %{path: "/all"}]} =
               CardigannSearchEngine.matching_search_paths(definition, categories: [2000])

      assert {:ok, [_, _, _]} = CardigannSearchEngine.matching_search_paths(definition, [])

      assert {:ok, "https://example.com/tv"} =
               CardigannSearchEngine.build_search_url(definition,
                 categories: [2000],
                 search_path: %{path: "/tv"}
               )
    end

    test "handles missing base URL" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: [],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:error, %Error{type: :search_failed}} =
               CardigannSearchEngine.build_search_url(definition, query: "test")
    end

    test "URI-encodes special characters in query" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, url} =
               CardigannSearchEngine.build_search_url(definition, query: "test & query=value")

      assert url == "https://example.com/search/test%20%26%20query%3Dvalue"
    end

    test "uses an absolute path verbatim instead of appending it to the base URL" do
      # The Pirate Bay's definition points its search at apibay.org. Appending
      # that to the site's base URL produced
      # https://thepiratebay.org/https://apibay.org/q.php?... and the site
      # answered with a redirect, surfacing as "Unexpected status: 302".
      definition = %Parsed{
        id: "thepiratebay",
        name: "The Pirate Bay",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://thepiratebay.org"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "https://apibay.org/q.php?q={{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, "https://apibay.org/q.php?q=ubuntu"} =
               CardigannSearchEngine.build_search_url(definition, query: "ubuntu")
    end

    test "still joins a relative path onto the base URL" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}/1/"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, "https://example.com/search/ubuntu/1/"} =
               CardigannSearchEngine.build_search_url(definition, query: "ubuntu")
    end

    test "joins a relative path that merely contains a colon onto the base URL" do
      # URI.parse/1 is lenient: a leading "mailto:someone"-shaped path parses
      # with a scheme but no host. A scheme-only guard would mistake it for
      # an absolute URL and skip the join; the scheme-and-host guard must
      # not.
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "mailto:{{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, "https://example.com/mailto:someone"} =
               CardigannSearchEngine.build_search_url(definition, query: "someone")
    end
  end

  describe "build_request_params/2" do
    defp two_path_definition(paths) do
      %Parsed{
        id: "two-path",
        name: "Two Path",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: paths,
          inputs: %{"q" => "{{ .Keywords }}", "sort" => "seeders"},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }
    end

    test "a path's inputs are added to the search inputs and win on a clash" do
      page2 = %{path: "/s", inputs: %{"page" => "2", "sort" => "date"}}
      definition = two_path_definition([%{path: "/s"}, page2])

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition,
                 query: "Ubuntu",
                 search_path: page2
               )

      assert params.query_params == %{"q" => "Ubuntu", "sort" => "date", "page" => "2"}
    end

    # UNIT3D API definitions send the key as `Authorization: Bearer {{ .Config.apikey }}`.
    test "search headers are rendered with the operator's settings" do
      definition =
        two_path_definition([%{path: "/s"}])
        |> put_in(
          [Access.key(:search), :headers],
          %{"Authorization" => ["Bearer {{ .Config.apikey }}"], "X-Plain" => "fixed"}
        )

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition,
                 query: "x",
                 config: %{"apikey" => "k-123"}
               )

      assert {"Authorization", ["Bearer k-123"]} in params.headers
      assert {"X-Plain", "fixed"} in params.headers
    end

    test "a search header that does not render fails the request instead of being dropped" do
      definition =
        two_path_definition([%{path: "/s"}])
        |> put_in([Access.key(:search), :headers], %{"Authorization" => ["Bearer {{ (( }}"]})

      assert {:error, %Error{type: :search_failed, message: message}} =
               CardigannSearchEngine.build_request_params(definition, query: "x")

      assert message =~ "Authorization"
    end

    test "inherit_inputs false sends the path's inputs alone" do
      page2 = %{path: "/s", inputs: %{"page" => "2"}, inherit_inputs: false}
      definition = two_path_definition([%{path: "/s"}, page2])

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition,
                 query: "Ubuntu",
                 search_path: page2
               )

      assert params.query_params == %{"page" => "2"}
    end

    test "the method comes from the same path as the URL" do
      get_page = %{path: "/one", method: "get"}
      post_page = %{path: "/two", method: "post"}
      definition = two_path_definition([get_page, post_page])

      assert {:ok, %{method: :get}} =
               CardigannSearchEngine.build_request_params(definition, query: "x")

      assert {:ok, %{method: :post}} =
               CardigannSearchEngine.build_request_params(definition,
                 query: "x",
                 search_path: post_page
               )

      assert {:ok, "https://example.com/two"} =
               CardigannSearchEngine.build_search_url(definition,
                 query: "x",
                 search_path: post_page
               )
    end

    test "carries the path's follow_redirect, nil when the path sets none" do
      page2 = %{path: "/s", follow_redirect: false}
      definition = two_path_definition([%{path: "/s"}, page2])

      assert {:ok, %{follow_redirect: nil}} =
               CardigannSearchEngine.build_request_params(definition, query: "x")

      assert {:ok, %{follow_redirect: false}} =
               CardigannSearchEngine.build_request_params(definition,
                 query: "x",
                 search_path: page2
               )
    end

    test "builds basic GET request params" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search", method: "get"}],
          inputs: %{"type" => "search", "limit" => "100"},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition, query: "Ubuntu")

      assert params.method == :get
      assert params.query_params["type"] == "search"
      assert params.query_params["limit"] == "100"
      assert params.headers == []
    end

    test "builds POST request params" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search", method: "post"}],
          inputs: %{"q" => "$raw:{{ .Keywords }}"},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition, query: "Ubuntu")

      assert params.method == :post
      assert params.query_params["q"] == "Ubuntu"
    end

    test "includes custom headers from definition" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          headers: %{"User-Agent" => "MyClient/1.0", "Accept" => "application/json"},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      assert {:ok, params} =
               CardigannSearchEngine.build_request_params(definition, query: "test")

      assert {"User-Agent", "MyClient/1.0"} in params.headers
      assert {"Accept", "application/json"} in params.headers
    end

    test "substitutes template variables in input values" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{
            "q" => "{{ .Keywords }}",
            "cat" => "{{ .Categories }}",
            "type" => "search"
          },
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil
      }

      opts = [query: "Ubuntu", categories: [2000, 5000]]

      assert {:ok, params} = CardigannSearchEngine.build_request_params(definition, opts)

      assert params.query_params["q"] == "Ubuntu"
      assert params.query_params["cat"] == "2000,5000"
      assert params.query_params["type"] == "search"
    end
  end

  describe "allowEmptyInputs" do
    defp parsed_with_inputs(inputs, allow_empty) do
      %Parsed{
        id: "ei",
        name: "EI",
        type: "public",
        links: ["https://example.com"],
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/search"}],
          inputs: inputs,
          headers: nil,
          keywordsfilters: [],
          allow_empty_inputs: allow_empty,
          rows: %{selector: "tr"},
          fields: %{}
        }
      }
    end

    test "keeps empty inputs when allowEmptyInputs is true" do
      parsed = parsed_with_inputs(%{"q" => "{{ .Keywords }}", "cat" => ""}, true)

      assert {:ok, params} = CardigannSearchEngine.build_request_params(parsed, query: "")
      assert Map.has_key?(params.query_params, "cat")
    end

    test "drops empty inputs by default" do
      parsed = parsed_with_inputs(%{"q" => "{{ .Keywords }}", "cat" => ""}, nil)

      assert {:ok, params} = CardigannSearchEngine.build_request_params(parsed, query: "")
      refute Map.has_key?(params.query_params, "cat")
    end
  end

  describe "validate_response/1" do
    test "accepts valid 200 response" do
      response = %{status: 200, body: "<html>...</html>", headers: []}
      assert :ok = CardigannSearchEngine.validate_response(response)
    end

    test "rejects 401 authentication error" do
      response = %{status: 401, body: "Unauthorized", headers: []}

      assert {:error, %Error{type: :connection_failed, message: message}} =
               CardigannSearchEngine.validate_response(response)

      assert message =~ "Authentication failed"
    end

    test "rejects 403 forbidden error" do
      response = %{status: 403, body: "Forbidden", headers: []}

      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.validate_response(response)
    end

    test "rejects 429 rate limit error" do
      response = %{status: 429, body: "Too Many Requests", headers: []}

      assert {:error, %Error{type: :rate_limited, message: message}} =
               CardigannSearchEngine.validate_response(response)

      assert message =~ "Rate limit"
    end

    test "rejects 500 server error" do
      response = %{status: 500, body: "Internal Server Error", headers: []}

      assert {:error, %Error{type: :search_failed, message: message}} =
               CardigannSearchEngine.validate_response(response)

      assert message =~ "Server error"
    end

    test "rejects 404 not found" do
      response = %{status: 404, body: "Not Found", headers: []}

      assert {:error, %Error{type: :search_failed, message: message}} =
               CardigannSearchEngine.validate_response(response)

      assert message =~ "HTTP 404"
    end
  end

  describe "execute_http_request/2" do
    setup do
      # Create a test definition
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://httpbin.org"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/html"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        request_delay: nil,
        follow_redirect: false
      }

      %{definition: definition}
    end

    @tag :external
    test "executes successful GET request", %{definition: definition} do
      params = %{
        query_params: %{},
        headers: [{"Accept", "text/html"}],
        method: :get
      }

      assert {:ok, response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "https://httpbin.org/html",
                 params,
                 %{},
                 %{}
               )

      assert response.status == 200
      assert is_binary(response.body)
      assert response.body =~ "<!DOCTYPE html>"
    end

    @tag :external
    test "handles request timeout gracefully", %{definition: definition} do
      # Use a delay endpoint to simulate timeout
      params = %{
        query_params: %{},
        headers: [],
        method: :get
      }

      # Override receive_timeout to 1ms to force timeout
      definition_with_short_timeout = definition

      # This should timeout quickly
      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.execute_http_request(
                 definition_with_short_timeout,
                 "https://httpbin.org/delay/10",
                 params,
                 %{},
                 %{}
               )
    end

    test "adds cookies from user config", %{definition: definition} do
      params = %{
        query_params: %{},
        headers: [],
        method: :get
      }

      user_config = %{
        cookies: ["session=abc123", "token=xyz789"]
      }

      # We can't easily test the actual cookie sending without mocking,
      # but we can verify the function executes without error
      # In a real scenario, you'd use a mock/stub library
      assert {:error, _} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "https://invalid-domain-for-testing.example",
                 params,
                 user_config,
                 %{}
               )
    end
  end

  describe "rate limiting" do
    test "spaces requests to one definition by request_delay, without delaying the first" do
      definition = %Parsed{
        id: "rate-#{System.unique_integer([:positive])}",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        # 100ms interval
        request_delay: 0.1,
        follow_redirect: false
      }

      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      params = %{query_params: %{}, headers: [], method: :get}

      request = fn ->
        started = System.monotonic_time(:millisecond)

        CardigannSearchEngine.execute_http_request(
          definition,
          "http://localhost:#{bypass.port}/search",
          params,
          %{},
          %{}
        )

        System.monotonic_time(:millisecond) - started
      end

      # The first request is not delayed (a local endpoint answers in a few ms).
      assert request.() < 80
      # The second one waits out the interval since the first.
      assert request.() >= 80
    end
  end

  describe "execute_search/3 integration" do
    test "executes full search flow with valid definition" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        # .test is an RFC 2606 reserved TLD that never resolves, same as
        # "invalid-domain.example" a few tests up in this same file — unlike
        # example.com, which resolves to a real server, so Mydia.RelayGuard
        # correctly refuses it and this test loosely asserts {:error, _}
        # regardless of which failure it is (#530).
        links: ["https://cardigann-search.test"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        request_delay: nil,
        follow_redirect: false
      }

      # This will fail to connect since the host doesn't resolve, but it
      # tests the flow up to the HTTP request.
      assert {:error, _} = CardigannSearchEngine.execute_search(definition, query: "Ubuntu")
    end

    test "handles missing query gracefully" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://cardigann-search.test"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        request_delay: nil,
        follow_redirect: false
      }

      # Should handle empty query by substituting empty string
      assert {:error, _} = CardigannSearchEngine.execute_search(definition, [])
    end
  end

  describe "FlareSolverr integration" do
    setup do
      definition = %Parsed{
        id: "test-flaresolverr",
        name: "Test FlareSolverr",
        description: "Test indexer for FlareSolverr",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        # .test never resolves (RFC 2606), unlike example.com, so
        # Mydia.RelayGuard correctly refuses it rather than letting it
        # through as if it were safe (#530).
        links: ["https://cardigann-search.test"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search/{{ .Keywords }}"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        request_delay: nil,
        follow_redirect: false
      }

      %{definition: definition}
    end

    test "execute_search accepts flaresolverr_opts parameter", %{definition: definition} do
      flaresolverr_opts = %{enabled: false, definition_id: "test-uuid"}

      # Should not error due to invalid flaresolverr_opts
      # It will error due to network, but that's expected
      assert {:error, _} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "test"],
                 %{},
                 flaresolverr_opts
               )
    end

    test "execute_search works without flaresolverr_opts", %{definition: definition} do
      # Should work without passing flaresolverr_opts (backward compatible)
      assert {:error, _} = CardigannSearchEngine.execute_search(definition, [query: "test"], %{})
    end

    # FlareSolverr.enabled?/0 gating (config presence, URL required) is covered in
    # Mydia.Indexers.FlareSolverrTest, which drives the layered runtime config.
  end

  describe "Cloudflare challenge detection" do
    test "detects Cloudflare 403 response with cf-browser-verification" do
      response = %{
        status: 403,
        body: """
        <html><body>
        <div id="cf-browser-verification">Please wait...</div>
        </body></html>
        """,
        headers: []
      }

      # The cloudflare_challenge? function is private, but we can test it indirectly
      # through the validation flow - 403 with Cloudflare content should be detected
      # We test the validate_response function behavior
      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.validate_response(response)
    end

    test "detects Cloudflare 403 response with cf_clearance" do
      response = %{
        status: 403,
        body: """
        <html><body>
        cf_clearance cookie required
        </body></html>
        """,
        headers: []
      }

      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.validate_response(response)
    end

    test "detects DDoS-Guard 403 response" do
      response = %{
        status: 403,
        body: """
        <html><body>
        DDoS-Guard protection
        </body></html>
        """,
        headers: []
      }

      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.validate_response(response)
    end

    test "detects Cloudflare 503 response" do
      response = %{
        status: 503,
        body: """
        <html><body>
        <div>Checking your browser before accessing... Cloudflare</div>
        </body></html>
        """,
        headers: []
      }

      assert {:error, %Error{type: :search_failed}} =
               CardigannSearchEngine.validate_response(response)
    end

    test "regular 403 without Cloudflare markers is still rejected" do
      response = %{
        status: 403,
        body: "Access denied. Login required.",
        headers: []
      }

      # Regular 403 should still fail, just not as Cloudflare
      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.validate_response(response)
    end
  end

  describe "cookie handling in user_config" do
    setup do
      definition = %Parsed{
        id: "test-cookies",
        name: "Test Cookies",
        description: "Test indexer for cookie handling",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://example.com"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          rows: %{selector: "tr"},
          fields: %{title: %{selector: "td.title"}}
        },
        login: nil,
        download: nil,
        request_delay: nil,
        follow_redirect: false
      }

      %{definition: definition}
    end

    test "user_config cookies are included in request", %{definition: definition} do
      params = %{
        query_params: %{},
        headers: [],
        method: :get
      }

      user_config = %{
        cookies: ["session=abc123", "token=xyz789"]
      }

      # This will fail to connect, but we're testing the function accepts cookies
      # In real usage, a mock server would verify the Cookie header
      assert {:error, _} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "https://invalid-domain-for-testing.example",
                 params,
                 user_config,
                 %{}
               )
    end

    test "empty cookies list is handled", %{definition: definition} do
      params = %{
        query_params: %{},
        headers: [],
        method: :get
      }

      user_config = %{
        cookies: []
      }

      assert {:error, _} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "https://invalid-domain-for-testing.example",
                 params,
                 user_config,
                 %{}
               )
    end

    test "missing cookies key is handled", %{definition: definition} do
      params = %{
        query_params: %{},
        headers: [],
        method: :get
      }

      user_config = %{}

      assert {:error, _} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "https://invalid-domain-for-testing.example",
                 params,
                 user_config,
                 %{}
               )
    end

    test "cookies are sent to a loopback host over http", %{definition: definition} do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}
      params = %{query_params: %{}, headers: [], method: :get}
      user_config = %{cookies: ["session=abc123", "token=xyz789"]}

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{bypass.port}/search",
                 params,
                 user_config,
                 %{}
               )

      assert_receive {:cookie_header, ["session=abc123; token=xyz789"]}
    end

    test "FlareSolverr map-shaped cookies are sent as name=value", %{definition: definition} do
      # Older versions wrote FlareSolverr's cookie maps into the same session row
      # CardigannAuth.get_stored_session/1 reads back, so map entries can reach here.
      bypass = Bypass.open()
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}
      params = %{query_params: %{}, headers: [], method: :get}

      user_config = %{
        cookies: [
          %{"name" => "cf_clearance", "value" => "abc123", "domain" => ".example.com"},
          %{"name" => "session", "value" => "xyz789"}
        ]
      }

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{bypass.port}/search",
                 params,
                 user_config,
                 %{}
               )

      assert_receive {:cookie_header, ["cf_clearance=abc123; session=xyz789"]}
    end

    test "unusable cookie entries are dropped rather than crashing", %{definition: definition} do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}
      params = %{query_params: %{}, headers: [], method: :get}
      # Decoded JSON can put a nested object or a number in either field, and
      # interpolating one would raise the error normalization exists to prevent.
      user_config = %{
        cookies: [
          %{"domain" => ".example.com"},
          42,
          %{"name" => %{"nested" => true}, "value" => "x"},
          %{"name" => "n", "value" => ["a", "b"]},
          %{"name" => 7, "value" => 9}
        ]
      }

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{bypass.port}/search",
                 params,
                 user_config,
                 %{}
               )

      assert_receive {:cookie_header, []}
    end

    test "a cookie-bearing request does not follow a redirect", %{definition: definition} do
      # Req carries a manually supplied Cookie header to the redirect target even
      # on a different host, so a followed redirect would leak the session.
      origin = Bypass.open()
      target = Bypass.open()
      test_pid = self()

      Bypass.expect_once(origin, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{target.port}/landing")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.stub(target, "GET", "/landing", fn conn ->
        send(test_pid, :target_was_reached)
        Plug.Conn.resp(conn, 200, "ok")
      end)

      definition = %{
        definition
        | follow_redirect: true,
          links: ["http://localhost:#{origin.port}"]
      }

      params = %{query_params: %{}, headers: [], method: :get}
      user_config = %{cookies: ["session=secret"]}

      assert {:ok, response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{origin.port}/search",
                 params,
                 user_config,
                 %{}
               )

      assert response.status == 302
      refute_receive :target_was_reached
    end

    test "a request without cookies still follows redirects", %{definition: definition} do
      origin = Bypass.open()
      target = Bypass.open()

      Bypass.expect_once(origin, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{target.port}/landing")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(target, "GET", "/landing", fn conn ->
        Plug.Conn.resp(conn, 200, "followed")
      end)

      definition = %{definition | follow_redirect: true}
      params = %{query_params: %{}, headers: [], method: :get}

      assert {:ok, response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{origin.port}/search",
                 params,
                 %{},
                 %{}
               )

      assert response.status == 200
    end

    test "cookies are withheld from a cleartext non-loopback host", %{definition: definition} do
      params = %{query_params: %{}, headers: [], method: :get}
      user_config = %{cookies: ["session=abc123"]}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          CardigannSearchEngine.execute_http_request(
            definition,
            "http://invalid-domain-for-testing.example/search",
            params,
            user_config,
            %{}
          )
        end)

      assert log =~ "withholding session cookies"
    end
  end

  defp scoped_definition(links, paths) do
    %Parsed{
      id: "scoped",
      name: "Scoped",
      description: "",
      language: "en-US",
      type: "private",
      encoding: "UTF-8",
      links: links,
      capabilities: %{modes: %{}},
      search: %{paths: paths, inputs: %{}, rows: %{selector: "tr"}, fields: %{}},
      login: nil,
      download: nil,
      settings: [],
      request_delay: nil,
      follow_redirect: false
    }
  end

  describe "credential scope" do
    test "an absolute search path brings its own host into scope" do
      site = Bypass.open()
      api = Bypass.open()
      test_pid = self()

      Bypass.expect_once(api, "GET", "/q.php", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition =
        scoped_definition(
          ["http://localhost:#{site.port}"],
          [%{path: "http://localhost:#{api.port}/q.php"}]
        )

      params = %{query_params: %{}, headers: [], method: :get}

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{api.port}/q.php",
                 params,
                 %{cookies: ["session=secret"]},
                 %{}
               )

      # The api host IS reachable through the definition's own absolute path, so
      # it is in scope and does receive the session.
      assert_receive {:cookie_header, ["session=secret"]}
    end

    test "cookies are withheld from a host the definition never names" do
      site = Bypass.open()
      evil = Bypass.open()
      test_pid = self()

      Bypass.expect_once(evil, "GET", "/steal", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition = scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])
      params = %{query_params: %{}, headers: [], method: :get}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _response} =
                   CardigannSearchEngine.execute_http_request(
                     definition,
                     "http://localhost:#{evil.port}/steal",
                     params,
                     %{cookies: ["session=secret"]},
                     %{}
                   )
        end)

      assert_receive {:cookie_header, []}
      assert log =~ "withholding session cookies"
    end

    test "cookies are withheld from a legacylinks host but the request still goes out" do
      site = Bypass.open()
      legacy = Bypass.open()
      test_pid = self()

      Bypass.expect_once(legacy, "GET", "/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html><body>ok</body></html>")
      end)

      definition =
        %{
          scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])
          | legacylinks: ["http://localhost:#{legacy.port}"]
        }

      params = %{query_params: %{}, headers: [], method: :get}

      assert {:ok, response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{legacy.port}/search",
                 params,
                 %{cookies: ["session=secret"]},
                 %{}
               )

      assert response.status == 200
      assert_receive {:cookie_header, []}
    end

    test "cookies are sent to a links host" do
      site = Bypass.open()
      test_pid = self()

      Bypass.expect_once(site, "GET", "/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition = scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])
      params = %{query_params: %{}, headers: [], method: :get}

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{site.port}/search",
                 params,
                 %{cookies: ["session=secret"]},
                 %{}
               )

      assert_receive {:cookie_header, ["session=secret"]}
    end

    test "an operator-configured apiurl brings its host into scope" do
      site = Bypass.open()
      api = Bypass.open()
      test_pid = self()

      Bypass.expect_once(api, "GET", "/v1/search", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      definition =
        scoped_definition(
          ["http://localhost:#{site.port}"],
          [%{path: "http://{{ .Config.apiurl }}/v1/search"}]
        )

      params = %{query_params: %{}, headers: [], method: :get}

      assert {:ok, _response} =
               CardigannSearchEngine.execute_http_request(
                 definition,
                 "http://localhost:#{api.port}/v1/search",
                 params,
                 %{cookies: ["session=secret"]},
                 %{"apiurl" => "localhost:#{api.port}"}
               )

      assert_receive {:cookie_header, ["session=secret"]}
    end
  end

  describe "execute_search/4 base URL failover" do
    setup do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)

      Bypass.stub(live, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td>row</td></tr></table></body></html>"
        )
      end)

      {:ok, dead_url: "http://localhost:#{dead.port}", live_url: "http://localhost:#{live.port}"}
    end

    defp parsed_for(links) do
      %Parsed{
        id: "failover-test",
        name: "Failover Test",
        type: "public",
        links: links,
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }
    end

    test "a successful response records the mirror that answered", %{
      dead_url: dead_url,
      live_url: live_url
    } do
      assert {:ok, %{base_url: ^live_url}} =
               CardigannSearchEngine.execute_search(
                 parsed_for([dead_url, live_url]),
                 [query: "x"],
                 %{},
                 %{}
               )
    end

    test "pin_base_url tries only the given mirror", %{dead_url: dead_url, live_url: live_url} do
      assert {:error, %Error{type: :connection_failed}} =
               CardigannSearchEngine.execute_search(
                 parsed_for([dead_url, live_url]),
                 [query: "x", base_url: dead_url, pin_base_url: true],
                 %{},
                 %{}
               )
    end

    test "advances to the next candidate on a transport failure", %{
      dead_url: dead_url,
      live_url: live_url
    } do
      test_pid = self()
      parsed = parsed_for([dead_url, live_url])

      assert {:ok, %{status: 200}} =
               CardigannSearchEngine.execute_search(
                 parsed,
                 [query: "ubuntu", on_promote: fn url -> send(test_pid, {:promoted, url}) end],
                 %{},
                 %{}
               )

      assert_received {:promoted, ^live_url}
    end

    test "does not fail over when the first candidate returns 200 with no rows", %{
      live_url: live_url
    } do
      second = Bypass.open()
      Bypass.stub(second, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 200, "second") end)
      second_url = "http://localhost:#{second.port}"

      test_pid = self()
      parsed = parsed_for([live_url, second_url])

      assert {:ok, %{status: 200, body: body}} =
               CardigannSearchEngine.execute_search(
                 parsed,
                 [query: "ubuntu", on_promote: fn url -> send(test_pid, {:promoted, url}) end],
                 %{},
                 %{}
               )

      refute body == "second"
      refute_received {:promoted, _}
    end

    test "stops after three candidates" do
      dead_urls =
        for _ <- 1..5 do
          b = Bypass.open()
          Bypass.down(b)
          "http://localhost:#{b.port}"
        end

      parsed = parsed_for(dead_urls)

      assert {:error, _} =
               CardigannSearchEngine.execute_search(parsed, [query: "ubuntu"], %{}, %{})
    end

    test "advances to the next candidate on a 404" do
      # YTS proxies answer / with HTML but 404 on /api/v2/list_movies.json, so
      # the homepage probe promotes a mirror whose search does not exist. Ending
      # the search there left five working mirrors untried.
      missing = Bypass.open()
      Bypass.stub(missing, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 404, "") end)

      working = Bypass.open()

      Bypass.stub(working, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td>row</td></tr></table></body></html>"
        )
      end)

      test_pid = self()
      working_url = "http://localhost:#{working.port}"
      parsed = parsed_for(["http://localhost:#{missing.port}", working_url])

      assert {:ok, %{status: 200}} =
               CardigannSearchEngine.execute_search(
                 parsed,
                 [query: "ubuntu", on_promote: fn url -> send(test_pid, {:promoted, url}) end],
                 %{},
                 %{}
               )

      assert_received {:promoted, ^working_url}
    end

    test "advances to the next candidate on an unfollowed redirect" do
      redirecting = Bypass.open()

      Bypass.stub(redirecting, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.test/")
        |> Plug.Conn.resp(302, "")
      end)

      working = Bypass.open()

      Bypass.stub(working, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td>row</td></tr></table></body></html>"
        )
      end)

      working_url = "http://localhost:#{working.port}"

      parsed = %{
        parsed_for(["http://localhost:#{redirecting.port}", working_url])
        | follow_redirect: false
      }

      assert {:ok, %{status: 200}} =
               CardigannSearchEngine.execute_search(parsed, [query: "ubuntu"], %{}, %{})
    end
  end

  describe "keywordsfilters" do
    test "filters the query before template substitution" do
      parsed = %Parsed{
        id: "kw",
        name: "KW",
        type: "public",
        links: ["https://example.com"],
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/search?q={{ .Keywords }}"}],
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

      assert {:ok, url} =
               CardigannSearchEngine.build_search_url(parsed,
                 query: "The Matrix 1999",
                 base_url: "https://example.com"
               )

      assert url =~ "The%20Matrix" or url =~ "The+Matrix"
      refute url =~ "1999"
    end

    test "leaves the query untouched when there are no filters" do
      parsed = %Parsed{
        id: "kw2",
        name: "KW2",
        type: "public",
        links: ["https://example.com"],
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/search?q={{ .Keywords }}"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, url} =
               CardigannSearchEngine.build_search_url(parsed,
                 query: "The Matrix 1999",
                 base_url: "https://example.com"
               )

      assert url =~ "1999"
    end
  end

  describe "direct request headers" do
    setup do
      site = Bypass.open()
      %{site: site, base: "http://localhost:#{site.port}"}
    end

    defp capture_headers(site) do
      test_pid = self()

      Bypass.expect_once(site, "GET", "/search", fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.resp(conn, 200, "<html><body></body></html>")
      end)
    end

    defp header_values(headers, name), do: for({^name, v} <- headers, do: v)

    defp definition_with(links, paths, headers) do
      %Parsed{
        id: "header-test",
        name: "Header Test",
        description: "",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: links,
        legacylinks: [],
        capabilities: %{modes: %{}},
        follow_redirect: false,
        settings: [],
        search: %{
          paths: paths,
          headers: headers,
          inputs: %{},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        },
        login: nil,
        download: nil
      }
    end

    test "sends a browser user-agent, not Req's default", %{site: site, base: base} do
      capture_headers(site)
      definition = definition_with([base], [%{path: "/search"}], %{})
      assert {:ok, _} = CardigannSearchEngine.execute_search(definition, [query: "x"], %{}, %{})
      assert_receive {:headers, headers}
      assert [ua] = header_values(headers, "user-agent")
      assert ua =~ "Mozilla/5.0"
      refute ua =~ "req/"
    end

    test "the definition's own user-agent wins over the default", %{site: site, base: base} do
      capture_headers(site)

      definition =
        definition_with([base], [%{path: "/search"}], %{"User-Agent" => "DefinitionAgent/2"})

      assert {:ok, _} = CardigannSearchEngine.execute_search(definition, [query: "x"], %{}, %{})
      assert_receive {:headers, headers}
      assert header_values(headers, "user-agent") == ["DefinitionAgent/2"]
    end

    test "a cached clearance wins and its cookies merge into the one cookie header",
         %{site: site, base: base} do
      capture_headers(site)

      :ok =
        Mydia.Indexers.FlareSolverr.ClearanceCache.put(
          base <> "/",
          [
            %{
              name: "cf_clearance",
              value: "solved",
              domain: "localhost",
              path: "/",
              expires: -1,
              http_only: true,
              secure: false,
              same_site: nil
            }
          ],
          "SolverAgent/3"
        )

      on_exit(fn -> Mydia.Indexers.FlareSolverr.ClearanceCache.delete(base <> "/") end)

      definition =
        definition_with([base], [%{path: "/search"}], %{
          "User-Agent" => "DefinitionAgent/2",
          "cookie" => "layout=def_wlinks"
        })

      assert {:ok, _} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{cookies: ["session=s1"]},
                 %{}
               )

      assert_receive {:headers, headers}
      assert header_values(headers, "user-agent") == ["SolverAgent/3"]
      assert [cookie] = header_values(headers, "cookie")
      assert cookie =~ "layout=def_wlinks"
      assert cookie =~ "session=s1"
      assert cookie =~ "cf_clearance=solved"
    end

    test "a list-valued cookie header is joined", %{site: site, base: base} do
      capture_headers(site)

      definition =
        definition_with([base], [%{path: "/search"}], %{"cookie" => ["a=1", "b=2"]})

      assert {:ok, _} = CardigannSearchEngine.execute_search(definition, [query: "x"], %{}, %{})
      assert_receive {:headers, headers}
      assert header_values(headers, "cookie") == ["a=1; b=2"]
    end
  end

  describe "cloudflare_challenge?/1" do
    test "a 200 interstitial is a challenge" do
      body = "<html><head><title>Just a moment...</title></head></html>"
      assert CardigannSearchEngine.cloudflare_challenge?(%{status: 200, body: body})
    end

    test "a 403 interstitial without the word Cloudflare is a challenge" do
      body = "<html><head><title>Just a moment...</title></head></html>"
      assert CardigannSearchEngine.cloudflare_challenge?(%{status: 403, body: body})
    end

    test "an ordinary page carrying Cloudflare's challenge-platform script is not" do
      body =
        ~s(<html><head><title>Results</title><script src="/cdn-cgi/challenge-platform/x.js"></script></head></html>)

      refute CardigannSearchEngine.cloudflare_challenge?(%{status: 200, body: body})
    end
  end

  describe "redirect handling" do
    test "a path's followredirect: false overrides the definition's true" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/moved")
        |> Plug.Conn.resp(302, "")
      end)

      parsed = redirecting_definition("http://localhost:#{bypass.port}", true)
      path = %{path: "/search", follow_redirect: false}

      assert {:error, %Error{message: "Redirected (HTTP 302)" <> _}} =
               CardigannSearchEngine.execute_search(
                 parsed,
                 [query: "ubuntu", search_path: path],
                 %{},
                 %{}
               )
    end

    test "follows a redirect by default" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/moved")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(bypass, "GET", "/moved", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td>row</td></tr></table></body></html>"
        )
      end)

      parsed = redirecting_definition("http://localhost:#{bypass.port}", true)

      assert {:ok, %{status: 200}} =
               CardigannSearchEngine.execute_search(parsed, [query: "ubuntu"], %{}, %{})
    end

    test "an unfollowed redirect reports its Location instead of Unexpected status" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.test/blocked")
        |> Plug.Conn.resp(302, "")
      end)

      parsed = redirecting_definition("http://localhost:#{bypass.port}", false)

      assert {:error, %Error{message: message}} =
               CardigannSearchEngine.execute_search(parsed, [query: "ubuntu"], %{}, %{})

      assert message =~ "Redirected (HTTP 302)"
      assert message =~ "https://elsewhere.test/blocked"
      refute message =~ "Unexpected status"
    end

    defp redirecting_definition(link, follow_redirect) do
      %Parsed{
        id: "redirect-test",
        name: "Redirect Test",
        description: "Test indexer",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: [link],
        legacylinks: [],
        capabilities: %{modes: %{}},
        follow_redirect: follow_redirect,
        settings: [],
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        },
        login: nil,
        download: nil
      }
    end
  end

  describe "follow_redirect default" do
    test "a definition without followredirect follows redirects" do
      # No definition in the shipped corpus sets this key, so the old `false`
      # default meant Mydia followed no redirects at all on search.
      yaml = """
      ---
      id: no-followredirect
      name: No Follow Redirect
      description: test
      language: en-US
      type: public
      encoding: UTF-8
      links:
        - https://example.test/
      caps:
        categorymappings:
          - {id: 1, cat: Movies, desc: "Movies"}
        modes:
          search: [q]
      search:
        paths:
          - path: /search
        rows:
          selector: tr
        fields:
          title:
            selector: td
          size:
            selector: td
          seeders:
            selector: td
      """

      assert {:ok, parsed} = Mydia.Indexers.CardigannParser.parse_definition(yaml)
      assert parsed.follow_redirect == true
    end
  end

  describe "build_request_params/2 with a failing input template" do
    test "an input whose template fails to render is omitted, not sent raw" do
      definition = %Parsed{
        id: "input-test",
        name: "input",
        links: ["https://example.invalid"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/"}],
          inputs: %{"q" => "{{ .Keywords }}", "bad" => "{{ if .Keywords"},
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, %{query_params: params}} =
               CardigannSearchEngine.build_request_params(definition, query: "x")

      assert params["q"] == "x"
      refute Map.has_key?(params, "bad")
    end
  end

  describe "block page failover" do
    defp failover_definition(links) do
      %Parsed{
        id: "failover",
        name: "failover",
        description: "",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: links,
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          inputs: %{},
          rows: %{selector: "tr.r"},
          fields: %{}
        },
        login: nil,
        download: nil,
        settings: [],
        request_delay: nil,
        follow_redirect: false
      }
    end

    test "a block page on the first mirror fails over to the second" do
      blocked = Bypass.open()
      live = Bypass.open()

      Bypass.stub(blocked, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, File.read!("test/fixtures/cardigann/block_page/response.html"))
      end)

      Bypass.stub(live, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, ~s(<table><tr class=r><td>Copper Lantern</td></tr></table>))
      end)

      definition =
        failover_definition([
          "http://localhost:#{blocked.port}",
          "http://localhost:#{live.port}"
        ])

      test_pid = self()

      assert {:ok, response} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x", categories: [], on_promote: &send(test_pid, {:promoted, &1})],
                 %{}
               )

      assert response.body =~ "Copper Lantern"
      assert_received {:promoted, "http://localhost:" <> _}
    end

    test "a block page on the only mirror is reported as a blocked page" do
      blocked = Bypass.open()

      Bypass.stub(blocked, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, File.read!("test/fixtures/cardigann/block_page/response.html"))
      end)

      definition = failover_definition(["http://localhost:#{blocked.port}"])

      assert {:error, %{message: "Blocked page: " <> title}} =
               CardigannSearchEngine.execute_search(definition, [query: "x", categories: []], %{})

      assert title =~ "Blocked"
    end
  end

  describe "execute_search/4 with several search paths" do
    test "without :search_path only the first matching path is requested" do
      # The health check and LiveCheck call this way and must stay one request.
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/p1", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td>row</td></tr></table></body></html>"
        )
      end)

      parsed = %Parsed{
        id: "two-pages",
        name: "Two Pages",
        type: "public",
        links: ["http://localhost:#{bypass.port}"],
        legacylinks: [],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/p1"}, %{path: "/p2"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{}
        }
      }

      assert {:ok, %{status: 200}} =
               CardigannSearchEngine.execute_search(parsed, [query: "x"], %{}, %{})
    end
  end
end
