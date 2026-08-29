defmodule Mydia.Indexers.CardigannSearchEngineFlareSolverrTest do
  # async: false: these tests inject FlareSolverr settings into the global
  # :runtime_config application env (same as Mydia.Indexers.FlareSolverrTest),
  # which is read across the app. Running them concurrently would race other
  # tests reading the runtime config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  # FlareSolverr never dials `url` itself in these tests; it is a headless
  # browser proxy, so only the JSON body posted to the mocked FlareSolverr
  # endpoint is observed here. The solution's `response` field stands in for
  # whatever the real target site would have returned.
  defp flaresolverr_ok_response(conn, decoded) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "solution" => %{
          "url" => decoded["url"],
          "status" => 200,
          "response" => "<html></html>",
          "cookies" => [],
          "userAgent" => "test-agent"
        },
        "startTimestamp" => 1000,
        "endTimestamp" => 1001
      })
    )
  end

  describe "execute_search/4 through FlareSolverr (should_use_flaresolverr? path)" do
    test "a request to an out-of-scope origin does not carry the session cookie, and still goes out" do
      site = Bypass.open()
      evil = Bypass.open()
      fs = Bypass.open()
      test_pid = self()

      put_flaresolverr_config(enabled: true, url: "http://localhost:#{fs.port}")

      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:flaresolverr_body, decoded})
        flaresolverr_ok_response(conn, decoded)
      end)

      definition = scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])

      opts = [query: "test", base_url: "http://localhost:#{evil.port}"]
      flaresolverr_opts = %{enabled: true, definition_id: "test-uuid"}
      user_config = %{cookies: ["session=secret"]}

      log =
        capture_log(fn ->
          assert {:ok, _response} =
                   CardigannSearchEngine.execute_search(
                     definition,
                     opts,
                     user_config,
                     flaresolverr_opts
                   )
        end)

      assert_receive {:flaresolverr_body, decoded}
      assert decoded["url"] =~ "localhost:#{evil.port}"
      refute Map.has_key?(decoded, "cookies")
      assert log =~ "withholding session cookies"
    end

    test "a request to an in-scope origin does carry the session cookie" do
      site = Bypass.open()
      fs = Bypass.open()
      test_pid = self()

      put_flaresolverr_config(enabled: true, url: "http://localhost:#{fs.port}")

      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:flaresolverr_body, decoded})
        flaresolverr_ok_response(conn, decoded)
      end)

      definition = scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])

      opts = [query: "test"]
      flaresolverr_opts = %{enabled: true, definition_id: "test-uuid"}
      user_config = %{cookies: ["session=secret"]}

      assert {:ok, _response} =
               CardigannSearchEngine.execute_search(
                 definition,
                 opts,
                 user_config,
                 flaresolverr_opts
               )

      assert_receive {:flaresolverr_body, decoded}
      assert decoded["url"] =~ "localhost:#{site.port}"
      assert decoded["cookies"] == [%{"name" => "session", "value" => "secret"}]
    end
  end

  describe "execute_search/4 through the Cloudflare-challenge FlareSolverr retry" do
    test "the retry withholds the session for the same out-of-scope url the direct request stripped it from" do
      site = Bypass.open()
      evil = Bypass.open()
      fs = Bypass.open()
      test_pid = self()

      put_flaresolverr_config(enabled: true, url: "http://localhost:#{fs.port}")

      Bypass.expect_once(evil, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 403, "<html><body>cf-browser-verification</body></html>")
      end)

      Bypass.expect_once(fs, "POST", "/v1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:flaresolverr_body, decoded})
        flaresolverr_ok_response(conn, decoded)
      end)

      definition = scoped_definition(["http://localhost:#{site.port}"], [%{path: "/search"}])

      opts = [query: "test", base_url: "http://localhost:#{evil.port}"]
      # FlareSolverr disabled per-indexer so the direct Req path runs first and
      # hits the Cloudflare challenge branch, which is the second, previously
      # unguarded, call site.
      flaresolverr_opts = %{enabled: false, definition_id: "test-uuid"}
      user_config = %{cookies: ["session=secret"]}

      log =
        capture_log(fn ->
          assert {:ok, _response, _fs_meta} =
                   CardigannSearchEngine.execute_search(
                     definition,
                     opts,
                     user_config,
                     flaresolverr_opts
                   )
        end)

      assert_receive {:flaresolverr_body, decoded}
      assert decoded["url"] =~ "localhost:#{evil.port}"
      refute Map.has_key?(decoded, "cookies")
      assert log =~ "withholding session cookies"
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
