defmodule Mydia.Net.ProxyAdapterTest do
  # The proxy config is global (persistent_term), so these tests cannot run
  # alongside async tests that make HTTP requests.
  use ExUnit.Case, async: false

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy
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
end
