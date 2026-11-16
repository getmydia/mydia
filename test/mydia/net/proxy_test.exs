defmodule Mydia.Net.ProxyTest do
  use ExUnit.Case, async: false

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy

  @bypass "example.org,.corp.test,203.0.113.7,198.51.100.0/24,fd00::/8"

  defp getenv(env), do: fn name -> Map.get(env, name) end

  defp build(url, bypass \\ nil, env \\ %{}) do
    {:ok, config} = Proxy.effective(%ProxyConfig{url: url, bypass: bypass}, getenv(env))
    config
  end

  setup do
    on_exit(fn -> Proxy.put_config(nil) end)
  end

  describe "effective/2 url precedence" do
    test "layered url beats every standard variable" do
      env = %{"HTTPS_PROXY" => "http://env:1"}
      config = build("http://cfg:2", nil, env)
      assert config.endpoint == "cfg:2"
      assert config.url_from == :config
    end

    test "HTTPS_PROXY > https_proxy > HTTP_PROXY > http_proxy" do
      all = %{
        "HTTPS_PROXY" => "http://a:1",
        "https_proxy" => "http://b:1",
        "HTTP_PROXY" => "http://c:1",
        "http_proxy" => "http://d:1"
      }

      for {drop, expected} <- [
            {[], "a:1"},
            {["HTTPS_PROXY"], "b:1"},
            {["HTTPS_PROXY", "https_proxy"], "c:1"},
            {["HTTPS_PROXY", "https_proxy", "HTTP_PROXY"], "d:1"}
          ] do
        config = build(nil, nil, Map.drop(all, drop))
        assert config.endpoint == expected
        assert config.url_from == :standard_env
      end
    end

    test "empty values are treated as unset" do
      config = build("", nil, %{"HTTPS_PROXY" => "", "http_proxy" => "http://d:1"})
      assert config.endpoint == "d:1"
    end

    test "nothing set gives nil" do
      assert {:ok, nil} = Proxy.effective(%ProxyConfig{}, getenv(%{}))
      assert {:ok, nil} = Proxy.effective(nil, getenv(%{}))
    end
  end

  describe "effective/2 bypass precedence" do
    test "layered beats NO_PROXY beats no_proxy" do
      env = %{"NO_PROXY" => "env.test", "no_proxy" => "lower.test"}
      c = build("http://p:1", "cfg.test", env)
      assert c.bypass_from == :config
      assert c.bypass == [{:domain, "cfg.test"}]

      c = build("http://p:1", nil, env)
      assert c.bypass_from == :standard_env
      assert c.bypass == [{:domain, "env.test"}]

      c = build("http://p:1", nil, %{"no_proxy" => "lower.test"})
      assert c.bypass == [{:domain, "lower.test"}]
      assert c.bypass_from == :standard_env
    end

    test "none when neither is set" do
      c = build("http://p:1")
      assert c.bypass_from == :none
      assert c.bypass == []
    end
  end

  describe "effective/2 url parsing" do
    test "default ports" do
      assert build("http://prizrak").proxy == {:http, "prizrak", 80, []}
      assert build("https://p").proxy == {:https, "p", 443, []}
    end

    test "credentials become a header and are masked" do
      c = build("http://u:p%40ss@h:1")
      assert c.proxy == {:http, "h", 1, []}
      assert c.headers == [{"proxy-authorization", "Basic " <> Base.encode64("u:p@ss")}]
      assert c.display_url == "http://u:****@h:1"
      assert c.endpoint == "h:1"
    end

    test "no credentials means no headers" do
      c = build("http://h:1")
      assert c.headers == []
      assert c.display_url == "http://h:1"
    end

    test "a user without a password is shown bare, with no mask" do
      assert build("http://u@h:1").display_url == "http://u@h:1"
      assert build("http://u:@h:1").display_url == "http://u@h:1"
    end

    test "unsupported scheme in a standard variable is an error naming the variable" do
      assert {:error, "unsupported proxy URL in HTTP_PROXY: socks5 is not supported"} =
               Proxy.effective(%ProxyConfig{}, getenv(%{"HTTP_PROXY" => "socks5://x:1"}))
    end

    test "errors never leak credentials" do
      assert {:error, msg} =
               Proxy.effective(
                 %ProxyConfig{},
                 getenv(%{"HTTP_PROXY" => "socks5://u:secret@x:1"})
               )

      refute msg =~ "secret"

      assert {:error, msg} =
               Proxy.effective(%ProxyConfig{}, getenv(%{"HTTP_PROXY" => "http://u:secret@:1"}))

      refute msg =~ "secret"

      assert {:error, msg} =
               Proxy.effective(%ProxyConfig{}, getenv(%{"HTTP_PROXY" => "u:secret@x:1"}))

      refute msg =~ "secret"
      refute msg =~ "u:"
      refute msg =~ "not supported"
    end

    test "a schemeless URL gets the generic message" do
      assert {:error,
              "invalid proxy URL in HTTP_PROXY: expected http://host:port or https://host:port"} =
               Proxy.effective(%ProxyConfig{}, getenv(%{"HTTP_PROXY" => "host:3128"}))
    end

    # URI.parse/1 turns these into port nil, the default port, or the wrong host.
    test "a bad port is an error, never a silent default" do
      for url <- [
            "http://proxy:99999",
            "http://proxy:abc",
            "http://proxy:0",
            "http://proxy:",
            "http://user:p#ss@proxy:3128"
          ] do
        assert {:error, msg} = Proxy.effective(%ProxyConfig{}, getenv(%{"HTTP_PROXY" => url})),
               url

        assert msg ==
                 "invalid proxy URL in HTTP_PROXY: the port must be a number from 1 to 65535"
      end
    end
  end

  describe "parse_url/1" do
    test "accepts http and https, with or without port and credentials" do
      assert {:ok, %URI{scheme: "http", host: "p", port: 3128}} = Proxy.parse_url("http://p:3128")
      assert {:ok, %URI{scheme: "https", host: "p", port: 443}} = Proxy.parse_url("https://p")

      assert {:ok, %URI{host: "::1", port: 8080}} = Proxy.parse_url("http://[::1]:8080")
      assert {:ok, %URI{host: "::1", port: 80}} = Proxy.parse_url("http://[::1]")

      assert {:ok, %URI{host: "h", port: 1, userinfo: "u:p%40ss"}} =
               Proxy.parse_url("http://u:p%40ss@h:1")
    end

    test "classifies what is wrong" do
      assert Proxy.parse_url("socks5://p:1080") == {:error, {:unsupported_scheme, "socks5"}}
      assert Proxy.parse_url("host:3128") == {:error, :invalid}
      assert Proxy.parse_url("http://") == {:error, :invalid}
      assert Proxy.parse_url("http://proxy:99999") == {:error, :invalid_port}
      assert Proxy.parse_url("http://[::1]:x") == {:error, :invalid_port}
    end
  end

  describe "refresh/2" do
    import ExUnit.CaptureLog

    defp schema(proxy), do: %Mydia.Config.Schema{proxy: proxy}

    test "an unusable standard variable goes direct, is logged, and is reported" do
      log =
        capture_log(fn ->
          assert :ok =
                   Proxy.refresh(
                     schema(%ProxyConfig{}),
                     getenv(%{"HTTPS_PROXY" => "socks5://u:secret@p:1080"})
                   )
        end)

      assert log =~ "Ignoring outbound proxy"
      refute log =~ "secret"
      assert Proxy.current() == nil
      assert Proxy.config_error() == {"HTTPS_PROXY", "socks5 is not supported"}

      assert :ok = Proxy.refresh(schema(%ProxyConfig{}), getenv(%{"HTTPS_PROXY" => "http://p:1"}))
      assert Proxy.current().endpoint == "p:1"
      assert Proxy.config_error() == nil
    end

    test "put_config/1 clears a stored error" do
      capture_log(fn ->
        Proxy.refresh(schema(nil), getenv(%{"HTTP_PROXY" => "http://p:99999"}))
      end)

      assert {"HTTP_PROXY", "the port must be a number from 1 to 65535"} = Proxy.config_error()
      Proxy.put_config(nil)
      assert Proxy.config_error() == nil
    end

    test "the default getenv comes from the :proxy_getenv application env" do
      previous = Application.fetch_env(:mydia, :proxy_getenv)

      on_exit(fn ->
        case previous do
          {:ok, fun} -> Application.put_env(:mydia, :proxy_getenv, fun)
          :error -> Application.delete_env(:mydia, :proxy_getenv)
        end
      end)

      Application.put_env(:mydia, :proxy_getenv, getenv(%{"HTTPS_PROXY" => "http://injected:1"}))
      assert :ok = Proxy.refresh(schema(%ProxyConfig{}))
      assert Proxy.current().endpoint == "injected:1"
    end

    test "the test environment hides the developer's proxy variables" do
      getenv = Proxy.getenv()

      for var <- ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy
                    MYDIA_PROXY_URL MYDIA_PROXY_BYPASS) do
        assert getenv.(var) == nil
      end

      assert getenv.("PATH") == System.get_env("PATH")
    end
  end

  describe "route/2" do
    setup do
      {:ok, config: build("http://prizrak:7890", @bypass)}
    end

    test "proxied hosts", %{config: c} do
      for host <- [
            "tracker.example.com",
            "nas.local",
            "notexample.org",
            "198.51.101.1",
            "93.184.216.34"
          ] do
        assert {:proxy, opts} = Proxy.route(host, c), host
        assert opts[:proxy] == {:http, "prizrak", 7890, []}
      end
    end

    test "direct hosts", %{config: c} do
      for host <- [
            "localhost",
            "jellyfin",
            "JELLYFIN.",
            "192.168.1.5",
            "10.0.0.1",
            "100.64.0.1",
            "127.0.0.1",
            "::1",
            "[fd12::1]",
            "example.org",
            "www.EXAMPLE.org",
            "a.corp.test",
            "corp.test",
            "203.0.113.7",
            "198.51.100.42",
            nil
          ] do
        assert Proxy.route(host, c) == :direct, inspect(host)
      end
    end

    test "nil config is always direct" do
      assert Proxy.route("tracker.example.com", nil) == :direct
    end

    test "wildcard bypass is always direct" do
      c = build("http://prizrak:7890", "*")
      assert Proxy.route("tracker.example.com", c) == :direct
    end

    test "proxy_headers included only when present" do
      {:proxy, opts} = Proxy.route("tracker.example.com", build("http://u:p@h:1"))
      assert [{"proxy-authorization", _}] = opts[:proxy_headers]

      {:proxy, opts} = Proxy.route("tracker.example.com", build("http://h:1"))
      refute Keyword.has_key?(opts, :proxy_headers)
    end
  end

  describe "put_config/1 and current/0" do
    test "round trip" do
      assert Proxy.current() == nil
      c = build("http://h:1")
      assert :ok = Proxy.put_config(c)
      assert Proxy.current() == c
    end
  end

  describe "describe_error/2,3" do
    setup do
      {:ok, config: build("http://prizrak:7890")}
    end

    test "407 and other statuses, for both exception types", %{config: c} do
      for mod <- [Req.HTTPError, Mint.HTTPError] do
        e407 = struct(mod, reason: {:proxy, {:unexpected_status, 407}})
        e502 = struct(mod, reason: {:proxy, {:unexpected_status, 502}})

        assert Proxy.describe_error(e407, "tracker.example.com", c) ==
                 "proxy prizrak:7890 requires authentication"

        assert Proxy.describe_error(e502, "tracker.example.com", c) ==
                 "proxy prizrak:7890 refused the tunnel (HTTP 502)"

        assert Proxy.describe_error(e407, "jellyfin", c) == nil
      end
    end

    test "transport errors", %{config: c} do
      e = %Req.TransportError{reason: :econnrefused}

      assert Proxy.describe_error(e, "tracker.example.com", c) ==
               "connection through proxy prizrak:7890 failed: econnrefused"

      assert Proxy.describe_error(e, "localhost", c) == nil
    end

    test "nil config and unrelated exceptions give nil" do
      e = %Req.TransportError{reason: :econnrefused}
      assert Proxy.describe_error(e, "tracker.example.com", nil) == nil

      assert Proxy.describe_error(
               %RuntimeError{message: "x"},
               "tracker.example.com",
               build("http://h:1")
             ) == nil
    end

    test "2-arity uses the current config", %{config: c} do
      e = %Req.TransportError{reason: :econnrefused}
      assert Proxy.describe_error(e, "tracker.example.com") == nil
      Proxy.put_config(c)

      assert Proxy.describe_error(e, "tracker.example.com") ==
               "connection through proxy prizrak:7890 failed: econnrefused"
    end
  end

  describe "test_connection/1" do
    alias Mydia.Test.ConnectProxy

    defp use_proxy(port, userinfo \\ "") do
      config = build("http://#{userinfo}127.0.0.1:#{port}")
      Proxy.put_config(config)
      config
    end

    test "without a proxy it says so" do
      Proxy.put_config(nil)

      assert Proxy.test_connection("http://tracker.example.test/health") ==
               {:error, "No proxy is configured"}
    end

    test "reports the status and latency through the proxy" do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "GET", "/health", &Plug.Conn.resp(&1, 200, "ok"))
      {:ok, proxy} = ConnectProxy.start(respond: :forward)
      use_proxy(proxy.port)

      assert {:ok, %{status: 200, ms: ms}} =
               Proxy.test_connection("http://tracker.example.test:#{bypass.port}/health")

      assert is_integer(ms) and ms >= 0
      assert [_ | _] = ConnectProxy.requests(proxy.log)
    end

    test "forces the proxy even for a host routing would send direct" do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "GET", "/health", &Plug.Conn.resp(&1, 200, "ok"))
      {:ok, proxy} = ConnectProxy.start(respond: :forward)
      use_proxy(proxy.port)

      assert {:ok, %{status: 200}} =
               Proxy.test_connection("http://localhost:#{bypass.port}/health")

      assert [_ | _] = ConnectProxy.requests(proxy.log)
    end

    test "a 407 tunnel answer is described without credentials" do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy(proxy.port, "user:hunter2@")

      assert {:error, message} = Proxy.test_connection("https://tracker.example.test/health")
      assert message == "proxy 127.0.0.1:#{proxy.port} requires authentication"
      refute message =~ "hunter2"
    end

    test "a 407 answer to a plain-http request is described the same way" do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy(proxy.port)

      assert Proxy.test_connection("http://tracker.example.test/health") ==
               {:error, "proxy 127.0.0.1:#{proxy.port} requires authentication"}
    end

    # The listener never accepts, so the kernel completes the TCP handshake and
    # the CONNECT request sits unanswered. Mint's own tunnel timeout is 30s.
    test "an unresponsive proxy fails within the test's timeout" do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(socket) end)
      {:ok, port} = :inet.port(socket)
      use_proxy(port)

      task = Task.async(fn -> Proxy.test_connection("https://tracker.example.test/health") end)

      assert {:ok, {:error, message}} = Task.yield(task, 8_000) || Task.shutdown(task)
      assert message == "proxy 127.0.0.1:#{port} did not answer"
    end

    test "a refused proxy port is described" do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      use_proxy(port)

      assert Proxy.test_connection("http://tracker.example.test/health") ==
               {:error, "connection through proxy 127.0.0.1:#{port} failed: econnrefused"}
    end
  end
end
