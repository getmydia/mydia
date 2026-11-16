defmodule Mydia.Plugins.Net.GateProxyTest do
  # DataCase: the gate emits an audit event. async: false because the proxy
  # config is global (persistent_term).
  use Mydia.DataCase, async: false

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Net.Gate
  alias Mydia.Test.ConnectProxy

  setup do
    previous = Proxy.current()
    on_exit(fn -> Proxy.put_config(previous) end)
    :ok
  end

  defp use_proxy(port) do
    {:ok, config} =
      Proxy.effective(%ProxyConfig{url: "http://127.0.0.1:#{port}"}, fn _ -> nil end)

    Proxy.put_config(config)
  end

  # 203.0.113.10 is an RFC 5737 documentation address: public as far as the
  # Gate is concerned, and on Mydia.RelayGuard's allowlist, so the pinned
  # request reaches the adapter. The proxy answers 403, so nothing leaves the
  # machine.
  test "gate request is tunnelled to the validated IP" do
    {:ok, proxy} = ConnectProxy.start(respond: {:status, 403})
    use_proxy(proxy.port)

    assert {:error, %Error{}} =
             Gate.request("https://tracker.example.test/",
               allowed_hosts: ["tracker.example.test"],
               resolver: fn _ -> {:ok, [{203, 0, 113, 10}]} end
             )

    assert [first | _] = ConnectProxy.requests(proxy.log)
    assert first == "CONNECT 203.0.113.10:443 HTTP/1.1"
  end

  test "gate still refuses a private target when a proxy is configured" do
    {:ok, proxy} = ConnectProxy.start(respond: :forward)
    use_proxy(proxy.port)

    assert {:error, %Error{type: :blocked}} =
             Gate.request("https://tracker.example.test/",
               allowed_hosts: ["tracker.example.test"],
               resolver: fn _ -> {:ok, [{10, 0, 0, 5}]} end
             )

    assert ConnectProxy.requests(proxy.log) == []
  end
end
