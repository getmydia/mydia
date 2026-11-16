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
end
