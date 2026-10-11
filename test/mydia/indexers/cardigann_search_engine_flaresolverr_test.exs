defmodule Mydia.Indexers.CardigannSearchEngineFlareSolverrTest do
  # async: false: these tests inject FlareSolverr settings into the global
  # :runtime_config application env (same as Mydia.Indexers.FlareSolverrTest),
  # which is read across the app. Running them concurrently would race other
  # tests reading the runtime config.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannDefinition.Parsed

  # Snapshot and restore the cached runtime config around every test so the
  # per-test FlareSolverr config we inject never leaks into other tests.
  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  defp scoped_definition(links, paths) do
    %Parsed{
      id: "scoped-flaresolverr",
      name: "Scoped FlareSolverr",
      description: "",
      language: "en-US",
      type: "public",
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

  # FlareSolverr never dials the target itself in these tests; only the JSON
  # body posted to the mocked FlareSolverr endpoint is observed. The solution's
  # `response` field stands in for Chrome's rendered DOM.
  defp solution(conn, decoded, opts \\ []) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "solution" => %{
          "url" => decoded["url"],
          "status" => 200,
          "response" => Keyword.get(opts, :rendered, "<html><body>rendered</body></html>"),
          "cookies" => [
            %{
              "name" => "cf_clearance",
              "value" => "solved",
              "domain" => "localhost",
              "path" => "/",
              "expires" => -1
            }
          ],
          "userAgent" => "SolverAgent/9"
        }
      })
    )
  end

  defp challenge(conn),
    do: Plug.Conn.resp(conn, 403, "<html><head><title>Just a moment...</title></head></html>")

  describe "challenge, solve, repeat directly" do
    setup do
      site = Bypass.open()
      fs = Bypass.open()

      put_flaresolverr_config(
        enabled: true,
        url: "http://localhost:#{fs.port}",
        max_concurrent_requests: 1
      )

      base = "http://localhost:#{site.port}"
      on_exit(fn -> Mydia.Indexers.FlareSolverr.ClearanceCache.delete(base <> "/") end)
      %{site: site, fs: fs, base: base}
    end

    test "FlareSolverr gets no cookies; the repeat carries the solution's cookies and user-agent and is what gets parsed",
         %{site: site, fs: fs, base: base} do
      test_pid = self()
      hits = :counters.new(1, [])

      Bypass.expect(site, "GET", "/search", fn conn ->
        :counters.add(hits, 1, 1)

        if :counters.get(hits, 1) == 1 do
          challenge(conn)
        else
          send(test_pid, {:repeat_headers, conn.req_headers})
          Plug.Conn.resp(conn, 200, "<html><body>direct</body></html>")
        end
      end)

      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:flaresolverr_body, decoded})
        solution(conn, decoded)
      end)

      definition = scoped_definition([base], [%{path: "/search"}])

      assert {:ok, response, [{:flaresolverr_required, true}]} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{cookies: ["session=secret"]},
                 %{enabled: false, definition_id: "d"}
               )

      assert response.body =~ "direct"
      assert_receive {:flaresolverr_body, decoded}
      refute Map.has_key?(decoded, "cookies")
      assert_receive {:repeat_headers, headers}
      assert {"user-agent", "SolverAgent/9"} in headers
      assert Enum.any?(headers, fn {k, v} -> k == "cookie" and v =~ "cf_clearance=solved" end)
    end

    test "a repeat that is still challenged falls back to the rendered page",
         %{site: site, fs: fs, base: base} do
      Bypass.expect(site, "GET", "/search", &challenge/1)

      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        solution(conn, Jason.decode!(body), rendered: "<html><body>rendered</body></html>")
      end)

      definition = scoped_definition([base], [%{path: "/search"}])

      assert {:ok, response, _} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{},
                 %{enabled: false}
               )

      assert response.body =~ "rendered"
      assert Mydia.Indexers.FlareSolverr.ClearanceCache.lookup(base <> "/") == :none
    end

    test "a flagged indexer with a cached clearance goes direct without FlareSolverr",
         %{site: site, fs: fs, base: base} do
      :ok =
        Mydia.Indexers.FlareSolverr.ClearanceCache.put(
          base <> "/",
          [
            %{
              name: "cf_clearance",
              value: "cached",
              domain: "localhost",
              path: "/",
              expires: -1,
              http_only: true,
              secure: false,
              same_site: nil
            }
          ],
          "CachedAgent/1"
        )

      Bypass.expect_once(site, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, "<html>ok</html>")
      end)

      Bypass.down(fs)

      definition = scoped_definition([base], [%{path: "/search"}])

      assert {:ok, %{body: "<html>ok</html>"}} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{},
                 %{enabled: true}
               )
    end

    test "a flagged indexer without a clearance solves first", %{site: site, fs: fs, base: base} do
      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        solution(conn, Jason.decode!(body))
      end)

      Bypass.expect_once(site, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, "<html>after solve</html>")
      end)

      definition = scoped_definition([base], [%{path: "/search"}])

      assert {:ok, %{body: "<html>after solve</html>"}} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{},
                 %{enabled: true}
               )
    end

    test "a FlareSolverr failure surfaces its readable message", %{site: site, fs: fs, base: base} do
      Bypass.expect(site, "GET", "/search", &challenge/1)

      Bypass.expect(fs, "POST", "/v1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          500,
          Jason.encode!(%{
            "status" => "error",
            "message" => "Error: Error solving the challenge. Message: tab crashed\n"
          })
        )
      end)

      definition = scoped_definition([base], [%{path: "/search"}])

      assert {:error, %{message: "FlareSolverr: browser tab crashed" <> _}} =
               CardigannSearchEngine.execute_search(
                 definition,
                 [query: "x"],
                 %{},
                 %{enabled: false}
               )
    end
  end

  ## Helpers: inject FlareSolverr settings into the layered runtime config.
  ## Mirrors Mydia.Indexers.FlareSolverrTest.

  defp put_flaresolverr_config(attrs) do
    fs = struct(Mydia.Config.Schema.FlareSolverr, attrs)
    Application.put_env(:mydia, :runtime_config, %{current_runtime_config() | flaresolverr: fs})
  end

  defp current_runtime_config do
    case Application.get_env(:mydia, :runtime_config) do
      %Mydia.Config.Schema{} = config -> config
      _ -> Mydia.Config.Schema.defaults()
    end
  end
end
