defmodule Mydia.Net.ProxyAdapterTest do
  # The proxy config is global (persistent_term), so these tests cannot run
  # alongside async tests that make HTTP requests.
  use ExUnit.Case, async: false

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy
  alias Mydia.Net.ProxyAdapter
  alias Mydia.Test.ConnectProxy

  @no_env &__MODULE__.no_env/1

  def no_env(_name), do: nil

  setup do
    previous = Proxy.current()
    on_exit(fn -> Proxy.put_config(previous) end)
    Proxy.put_config(nil)
    {:ok, bypass: Bypass.open()}
  end

  defp use_proxy(port) do
    {:ok, config} = Proxy.effective(%ProxyConfig{url: "http://127.0.0.1:#{port}"}, @no_env)
    Proxy.put_config(config)
    config
  end

  defp expect_ok(bypass) do
    Bypass.expect(bypass, "GET", "/x", &Plug.Conn.resp(&1, 200, "from target"))
  end

  test "sends a public host through the proxy", %{bypass: bypass} do
    {:ok, proxy} = ConnectProxy.start(respond: :forward)
    use_proxy(proxy.port)
    expect_ok(bypass)

    assert {:ok, %Req.Response{status: 200, body: "from target"}} =
             Req.get("http://tracker.example.test:#{bypass.port}/x", retry: false)

    assert [first | _] = ConnectProxy.requests(proxy.log)
    assert first == "GET http://tracker.example.test:#{bypass.port}/x HTTP/1.1"
  end

  test "leaves a single-label host direct", %{bypass: bypass} do
    {:ok, proxy} = ConnectProxy.start(respond: :forward)
    use_proxy(proxy.port)
    expect_ok(bypass)

    assert {:ok, %Req.Response{status: 200}} =
             Req.get("http://localhost:#{bypass.port}/x", retry: false)

    assert ConnectProxy.requests(proxy.log) == []
  end

  test "respects a caller-set connect_options proxy", %{bypass: bypass} do
    {:ok, configured} = ConnectProxy.start(respond: :forward)
    {:ok, callers} = ConnectProxy.start(respond: :forward)
    use_proxy(configured.port)
    expect_ok(bypass)

    assert {:ok, %Req.Response{status: 200}} =
             Req.get("http://tracker.example.test:#{bypass.port}/x",
               retry: false,
               connect_options: [proxy: {:http, "127.0.0.1", callers.port, []}]
             )

    assert ConnectProxy.requests(configured.log) == []
    assert [_ | _] = ConnectProxy.requests(callers.log)
  end

  describe "redirects" do
    # The first hop goes to a proxied name and 302s to a loopback address,
    # which routes direct. Req builds the second hop from the same request, so
    # the adapter must not leave the proxy it injected on it.
    defp redirect_to_loopback(bypass, target) do
      Bypass.expect_once(bypass, "GET", "/x", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:#{target.port}/y")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(target, "GET", "/y", &Plug.Conn.resp(&1, 200, "landed"))
    end

    test "re-routes the redirected request instead of reusing the injected proxy",
         %{bypass: bypass} do
      {:ok, proxy} = ConnectProxy.start(respond: :forward)
      use_proxy(proxy.port)
      target = Bypass.open()
      redirect_to_loopback(bypass, target)

      assert {:ok, %Req.Response{status: 200, body: "landed"}} =
               Req.get("http://tracker.example.test:#{bypass.port}/x", retry: false)

      assert ConnectProxy.requests(proxy.log) == [
               "GET http://tracker.example.test:#{bypass.port}/x HTTP/1.1"
             ]
    end

    test "keeps a caller-set proxy on every hop", %{bypass: bypass} do
      {:ok, configured} = ConnectProxy.start(respond: :forward)
      {:ok, callers} = ConnectProxy.start(respond: :forward)
      use_proxy(configured.port)
      target = Bypass.open()
      redirect_to_loopback(bypass, target)

      assert {:ok, %Req.Response{status: 200, body: "landed"}} =
               Req.get("http://tracker.example.test:#{bypass.port}/x",
                 retry: false,
                 connect_options: [proxy: {:http, "127.0.0.1", callers.port, []}]
               )

      assert ConnectProxy.requests(configured.log) == []
      assert length(ConnectProxy.requests(callers.log)) == 2
    end
  end

  test "a 407 surfaces as a proxy authentication error" do
    {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
    use_proxy(proxy.port)

    assert {:error, err} = Req.get("https://tracker.example.test/", retry: false)

    assert Proxy.describe_error(err, "tracker.example.test") ==
             "proxy 127.0.0.1:#{proxy.port} requires authentication"
  end

  test "a config refresh takes effect on the next request", %{bypass: bypass} do
    {:ok, proxy} = ConnectProxy.start(respond: :forward)
    url = "http://tracker.example.test:#{bypass.port}/x"

    # No proxy: the reserved name does not resolve, and nothing reaches the proxy.
    assert {:error, _} = Req.get(url, retry: false)
    assert ConnectProxy.requests(proxy.log) == []

    config = %Mydia.Config.Schema{
      proxy: %ProxyConfig{url: "http://127.0.0.1:#{proxy.port}"}
    }

    assert :ok = Proxy.refresh(config, @no_env)
    expect_ok(bypass)

    assert {:ok, %Req.Response{status: 200}} = Req.get(url, retry: false)
    assert [_] = ConnectProxy.requests(proxy.log)
  end

  describe "apply_proxy/2 with a pinned IP and :hostname" do
    defp pinned(ip, hostname) do
      Req.new(url: "http://#{ip}:32400/", connect_options: [hostname: hostname])
    end

    defp connect_options(request, config) do
      request
      |> ProxyAdapter.apply_proxy(config)
      |> Map.fetch!(:options)
      |> Map.get(:connect_options)
    end

    test "a private or loopback pinned IP goes direct even for a dotted name" do
      {:ok, config} = Proxy.effective(%ProxyConfig{url: "http://proxy.test:3128"}, @no_env)

      for ip <- ["192.168.1.5", "127.0.0.1", "10.0.0.5", "[fd00::5]"] do
        request = pinned(ip, "plex.home.example")
        assert connect_options(request, config) == [hostname: "plex.home.example"]
      end
    end

    test "a public pinned IP is proxied, and bypass still matches the hostname" do
      {:ok, config} =
        Proxy.effective(
          %ProxyConfig{url: "http://proxy.test:3128", bypass: ".bypassed.test"},
          @no_env
        )

      proxied = connect_options(pinned("203.0.113.10", "a.example.test"), config)
      assert proxied[:proxy] == {:http, "proxy.test", 3128, []}

      assert connect_options(pinned("203.0.113.10", "x.bypassed.test"), config) ==
               [hostname: "x.bypassed.test"]
    end

    test "a proxied pinned request drops :hostname for http and keeps it for https" do
      {:ok, config} = Proxy.effective(%ProxyConfig{url: "http://proxy.test:3128"}, @no_env)

      plain = connect_options(pinned("203.0.113.10", "a.example.test"), config)
      refute Keyword.has_key?(plain, :hostname)

      tls =
        Req.new(url: "https://203.0.113.10/", connect_options: [hostname: "a.example.test"])
        |> connect_options(config)

      assert tls[:hostname] == "a.example.test"
      assert tls[:proxy] == {:http, "proxy.test", 3128, []}
    end
  end
end
