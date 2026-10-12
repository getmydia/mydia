defmodule Mydia.Indexers.Cardigann.Wasm.HostHttpFlareSolverrTest do
  # async: false: FlareSolverr settings live in the global :runtime_config env.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.HostHttp
  alias Mydia.Indexers.FlareSolverr.ClearanceCache

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    site = Bypass.open()
    fs = Bypass.open()
    base = "http://localhost:#{site.port}"

    fs_config =
      struct(Mydia.Config.Schema.FlareSolverr,
        enabled: true,
        url: "http://localhost:#{fs.port}",
        max_concurrent_requests: 1
      )

    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | flaresolverr: fs_config
    })

    on_exit(fn -> ClearanceCache.delete(base <> "/") end)

    ctx = %{
      definition_id: "fs-#{System.unique_integer([:positive])}",
      request_delay_ms: 0,
      flaresolverr: %{enabled: true},
      gate_opts: [allow_private_except_link_local: true]
    }

    {:ok, site: site, fs: fs, base: base, ctx: ctx}
  end

  defp req(url, headers \\ []),
    do: %{
      method: "GET",
      url: url,
      headers: Enum.map(headers, fn {n, v} -> %{name: n, value: v} end),
      body: nil
    }

  defp challenge(conn),
    do: Plug.Conn.resp(conn, 403, "<html><head><title>Just a moment...</title></head></html>")

  defp solution(conn, decoded, rendered) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "solution" => %{
          "url" => decoded["url"],
          "status" => 200,
          "response" => rendered,
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

  test "a challenge is solved and the request repeated with the clearance", %{
    site: site,
    fs: fs,
    base: base,
    ctx: ctx
  } do
    test_pid = self()
    hits = :counters.new(1, [])

    Bypass.expect(site, "GET", "/search", fn conn ->
      :counters.add(hits, 1, 1)

      if :counters.get(hits, 1) == 1 do
        challenge(conn)
      else
        send(test_pid, {:repeat_headers, conn.req_headers})
        Plug.Conn.resp(conn, 200, "direct")
      end
    end)

    Bypass.expect_once(fs, "POST", "/v1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      solution(conn, Jason.decode!(body), "rendered")
    end)

    assert {:ok, %{status: 200, body: "direct"}} =
             HostHttp.exchange(ctx, req(base <> "/search", [{"Cookie", "sid=1"}]))

    assert_receive {:repeat_headers, headers}
    assert {"user-agent", "SolverAgent/9"} in headers

    assert Enum.any?(headers, fn {k, v} ->
             k == "cookie" and v =~ "cf_clearance=solved" and v =~ "sid=1"
           end)
  end

  test "a cached clearance is not injected when FlareSolverr is disabled for the definition", %{
    site: site,
    base: base,
    ctx: ctx
  } do
    ClearanceCache.put(
      base <> "/",
      [%{name: "cf_clearance", value: "cached", domain: "localhost", path: "/", expires: -1}],
      "CachedAgent/1"
    )

    test_pid = self()

    Bypass.expect_once(site, "GET", "/search", fn conn ->
      send(test_pid, {:headers, conn.req_headers})
      Plug.Conn.resp(conn, 200, "")
    end)

    ctx = %{ctx | flaresolverr: %{enabled: false}}
    assert {:ok, %{status: 200}} = HostHttp.exchange(ctx, req(base <> "/search"))

    assert_receive {:headers, headers}
    refute {"user-agent", "CachedAgent/1"} in headers
    refute Enum.any?(headers, fn {k, _} -> k == "cookie" end)
  end

  test "a repeat that is still challenged returns the rendered page as 200",
       %{
         site: site,
         fs: fs,
         base: base,
         ctx: ctx
       } do
    Bypass.expect(site, "GET", "/search", &challenge/1)

    Bypass.expect_once(fs, "POST", "/v1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      solution(conn, Jason.decode!(body), "<html>rendered</html>")
    end)

    assert {:ok, %{status: 200, body: "<html>rendered</html>"}} =
             HostHttp.exchange(ctx, req(base <> "/search"))
  end

  test "a challenge passes through untouched when FlareSolverr is not enabled for the definition",
       %{site: site, base: base, ctx: ctx} do
    Bypass.expect_once(site, "GET", "/search", &challenge/1)

    assert {:ok, %{status: 403}} =
             HostHttp.exchange(%{ctx | flaresolverr: nil}, req(base <> "/search"))
  end

  test "a FlareSolverr failure is reported as :other with the operator-facing text", %{
    site: site,
    fs: fs,
    base: base,
    ctx: ctx
  } do
    Bypass.expect_once(site, "GET", "/search", &challenge/1)
    Bypass.down(fs)

    assert {:error, {:other, "FlareSolverr:" <> _}} =
             HostHttp.exchange(ctx, req(base <> "/search"))
  end
end
