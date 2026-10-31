defmodule Mydia.Indexers.Cardigann.Wasm.HostHttpTest do
  # DataCase: one test asserts that no audit event reaches the database.
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.Cardigann.Wasm.HostHttp

  setup do
    bypass = Bypass.open()

    ctx = %{
      definition_id: "def-#{System.unique_integer([:positive])}",
      request_delay_ms: 0,
      flaresolverr: nil,
      # Bypass listens on loopback. Link-local (the metadata address) stays refused.
      gate_opts: [allow_private_except_link_local: true]
    }

    {:ok, bypass: bypass, ctx: ctx, base: "http://localhost:#{bypass.port}"}
  end

  defp req(method, url, headers \\ [], body \\ nil),
    do: %{
      method: method,
      url: url,
      headers: Enum.map(headers, fn {n, v} -> %{name: n, value: v} end),
      body: body
    }

  describe "exchange/2" do
    test "performs one exchange and passes headers through", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["ProwlarrTest/1.0"]
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, %{status: 200, body: "ok"}} =
               HostHttp.exchange(
                 ctx,
                 req("GET", base <> "/search", [{"User-Agent", "ProwlarrTest/1.0"}])
               )
    end

    test "a login watch flags only the login URL on the tracker's own host", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.stub(bypass, "GET", "/login.php", &Plug.Conn.resp(&1, 200, "form"))
      Bypass.stub(bypass, "GET", "/browse/login.php", &Plug.Conn.resp(&1, 200, "rows"))

      hit = :atomics.new(1, [])
      watched = %{URI.parse(base) | path: "/login.php"}
      other_host = %{watched | port: watched.port + 1}

      ctx = Map.put(ctx, :login_watch, %{targets: [watched], hit: hit})

      HostHttp.exchange(ctx, req("GET", base <> "/browse/login.php"))
      assert :atomics.get(hit, 1) == 0

      HostHttp.exchange(
        %{ctx | login_watch: %{targets: [other_host], hit: hit}},
        req("GET", base <> "/login.php")
      )

      assert :atomics.get(hit, 1) == 0

      # Same port and path, another host.
      HostHttp.exchange(
        %{ctx | login_watch: %{targets: [%{watched | host: "other.invalid"}], hit: hit}},
        req("GET", base <> "/login.php")
      )

      assert :atomics.get(hit, 1) == 0

      HostHttp.exchange(ctx, req("GET", base <> "/login.php?returnto=%2F"))
      assert :atomics.get(hit, 1) == 1
    end

    test "never follows redirects", %{bypass: bypass, ctx: ctx, base: base} do
      Bypass.expect_once(bypass, "GET", "/a", fn conn ->
        conn |> Plug.Conn.put_resp_header("location", base <> "/b") |> Plug.Conn.resp(302, "")
      end)

      assert {:ok, %{status: 302, headers: headers}} =
               HostHttp.exchange(ctx, req("GET", base <> "/a"))

      assert %{name: "location", value: base <> "/b"} in headers
    end

    test "keeps every set-cookie value as its own lower-cased header", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect_once(bypass, "GET", "/c", fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([{"set-cookie", "a=1"}, {"set-cookie", "b=2"}])
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, %{headers: headers}} = HostHttp.exchange(ctx, req("GET", base <> "/c"))
      assert %{name: "set-cookie", value: "a=1"} in headers
      assert %{name: "set-cookie", value: "b=2"} in headers
      assert Enum.all?(headers, &(&1.name == String.downcase(&1.name)))
    end

    test "sends a POST body verbatim", %{bypass: bypass, ctx: ctx, base: base} do
      Bypass.expect_once(bypass, "POST", "/login", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "username=reader&password=secret"
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, %{status: 200}} =
               HostHttp.exchange(
                 ctx,
                 req(
                   "POST",
                   base <> "/login",
                   [{"Content-Type", "application/x-www-form-urlencoded"}],
                   "username=reader&password=secret"
                 )
               )
    end

    test "returns a binary body untouched (no decoding)", %{bypass: bypass, ctx: ctx, base: base} do
      json = ~s({"a":1})

      Bypass.expect_once(bypass, "GET", "/j", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, json)
      end)

      assert {:ok, %{body: ^json}} = HostHttp.exchange(ctx, req("GET", base <> "/j"))
    end

    test "inflates a gzip body the server sent unasked and drops its encoding headers", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      html = "<html>" <> String.duplicate("row ", 500) <> "</html>"
      gz = :zlib.gzip(html)

      Bypass.expect_once(bypass, "GET", "/z", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, gz)
      end)

      assert {:ok, %{body: ^html, headers: headers}} =
               HostHttp.exchange(ctx, req("GET", base <> "/z"))

      refute Enum.any?(headers, &(&1.name in ["content-encoding", "content-length"]))
      assert Enum.any?(headers, &(&1.name == "content-type"))
    end

    test "passes a body through whose gzip is corrupt", %{bypass: bypass, ctx: ctx, base: base} do
      Bypass.expect_once(bypass, "GET", "/bad", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.resp(200, "not gzip at all")
      end)

      assert {:ok, %{body: "not gzip at all", headers: headers}} =
               HostHttp.exchange(ctx, req("GET", base <> "/bad"))

      assert %{name: "content-encoding", value: "gzip"} in headers
    end

    test "gives a request the 100 s Prowlarr's HTTP client allows" do
      # archive.org takes 30 to 50 s to answer Prowlarr's requests; a shorter
      # deadline made the wasm engine return nothing where Prowlarr succeeds.
      assert HostHttp.default_timeout_ms() == 100_000
    end

    test "blocks egress the gate refuses", %{ctx: ctx} do
      assert {:error, {:blocked, _}} =
               HostHttp.exchange(ctx, req("GET", "http://169.254.169.254/latest/meta-data"))

      assert {:error, {:blocked, _}} =
               HostHttp.exchange(
                 Map.delete(ctx, :gate_opts),
                 req("GET", "http://127.0.0.1:9/x")
               )
    end

    test "folds duplicate request header names case-insensitively", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect_once(bypass, "GET", "/h", fn conn ->
        assert Plug.Conn.get_req_header(conn, "cookie") == ["a=1; b=2"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["text/html, application/json"]
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, %{status: 200}} =
               HostHttp.exchange(
                 ctx,
                 req("GET", base <> "/h", [
                   {"Cookie", "a=1"},
                   {"cookie", "b=2"},
                   {"Accept", "text/html"},
                   {"accept", "application/json"}
                 ])
               )
    end

    test "maps a URL the gate rejects as malformed to :blocked", %{ctx: ctx} do
      assert {:error, {:blocked, _}} = HostHttp.exchange(ctx, req("GET", "ftp://example.test/x"))

      assert {:error, {:blocked, _}} =
               HostHttp.exchange(ctx, req("GET", "http://user:pw@example.test/x"))
    end

    test "writes no audit event, so a query-string apikey never reaches the database", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect_once(bypass, "GET", "/q", fn conn -> Plug.Conn.resp(conn, 200, "") end)

      assert {:ok, _} = HostHttp.exchange(ctx, req("GET", base <> "/q?apikey=SECRETKEY"))

      events = Mydia.Events.list_events(category: "plugin", type: "plugin.http_request")
      refute Enum.any?(events, &(&1.actor_id == "cardigann"))
      refute Enum.any?(events, &(inspect(&1.metadata) =~ "SECRETKEY"))
    end

    test "maps a refused connection to :connect", %{bypass: bypass, ctx: ctx, base: base} do
      Bypass.down(bypass)
      assert {:error, {:connect, _}} = HostHttp.exchange(ctx, req("GET", base <> "/x"))
    end

    test "maps an unsupported method to :other", %{ctx: ctx, base: base} do
      assert {:error, {:other, _}} = HostHttp.exchange(ctx, req("BREW", base <> "/x"))
    end

    test "honours request_delay_ms between calls for one definition", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect(bypass, "GET", "/x", fn conn -> Plug.Conn.resp(conn, 200, "") end)
      ctx = %{ctx | request_delay_ms: 300}

      HostHttp.exchange(ctx, req("GET", base <> "/x"))
      {us, _} = :timer.tc(fn -> HostHttp.exchange(ctx, req("GET", base <> "/x")) end)
      assert us >= 280_000
    end

    test "adds the exchange's wall-clock microseconds to the network counter", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect(bypass, "GET", "/slow", fn conn ->
        Process.sleep(50)
        Plug.Conn.resp(conn, 200, "")
      end)

      network = :atomics.new(2, [])
      ctx = Map.put(ctx, :network, network)

      HostHttp.exchange(ctx, req("GET", base <> "/slow"))
      assert :atomics.get(network, 1) >= 45_000
      assert :atomics.get(network, 2) == 0
    end
  end

  describe "Wasmex value-shape conversion" do
    test "decode_request/1 accepts atom or string keys and option bodies" do
      atom_keys = %{
        method: "POST",
        url: "http://h/",
        headers: [%{name: "A", value: "b"}],
        body: {:some, [104, 105]}
      }

      string_keys = %{
        "method" => "POST",
        "url" => "http://h/",
        "headers" => [%{"name" => "A", "value" => "b"}],
        "body" => {:some, "hi"}
      }

      expected = %{
        method: "POST",
        url: "http://h/",
        headers: [%{name: "A", value: "b"}],
        body: "hi"
      }

      assert HostHttp.decode_request(atom_keys) == expected
      assert HostHttp.decode_request(string_keys) == expected
    end

    test "decode_request/1 maps :none to a nil body and accepts iodata" do
      assert %{body: nil} =
               HostHttp.decode_request(%{method: "GET", url: "u", headers: [], body: :none})

      assert %{body: "ab"} =
               HostHttp.decode_request(%{
                 method: "GET",
                 url: "u",
                 headers: [],
                 body: {:some, ["a", [98]]}
               })
    end

    test "encode_result/1 turns the body into a list of integers" do
      assert {:ok, %{status: 200, headers: [%{name: "x", value: "y"}], body: [111, 107]}} =
               HostHttp.encode_result(
                 {:ok, %{status: 200, headers: [%{name: "x", value: "y"}], body: "ok"}}
               )

      assert {:ok, %{body: []}} =
               HostHttp.encode_result({:ok, %{status: 204, headers: [], body: ""}})
    end

    test "encode_result/1 keeps http-error variants as {case, message}" do
      for kind <- [:timeout, :connect, :blocked, :other] do
        assert {:error, {^kind, "msg"}} = HostHttp.encode_result({:error, {kind, "msg"}})
      end
    end

    test "imports/1 exposes http-request and log under the host namespace", %{ctx: ctx} do
      assert %{"mydia:cardigann/host@1.0.0" => %{"http-request" => {:fn, f}, "log" => {:fn, l}}} =
               HostHttp.imports(ctx)

      assert is_function(f, 1)
      assert is_function(l, 2)
      assert l.(2, "hello") == :ok
    end

    test "the http-request import round-trips Wasmex shapes", %{
      bypass: bypass,
      ctx: ctx,
      base: base
    } do
      Bypass.expect_once(bypass, "POST", "/p", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.resp(conn, 201, String.upcase(body))
      end)

      %{"mydia:cardigann/host@1.0.0" => %{"http-request" => {:fn, f}}} = HostHttp.imports(ctx)

      assert {:ok, %{status: 201, body: [72, 73]}} =
               f.(%{
                 method: "POST",
                 url: base <> "/p",
                 headers: [],
                 body: {:some, [104, 105]}
               })
    end
  end
end
