defmodule Mydia.Indexers.CardigannProxyErrorsTest do
  # The proxy config is global (persistent_term), so this cannot run alongside
  # async tests that make HTTP requests.
  use ExUnit.Case, async: false

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Net.Proxy
  alias Mydia.Test.ConnectProxy

  setup do
    previous = Proxy.current()
    on_exit(fn -> Proxy.put_config(previous) end)
    Proxy.put_config(nil)
    :ok
  end

  defp use_proxy(port) do
    {:ok, config} =
      Proxy.effective(%ProxyConfig{url: "http://127.0.0.1:#{port}"}, fn _ -> nil end)

    Proxy.put_config(config)
  end

  defp parsed(link) do
    %Parsed{
      id: "proxytest",
      name: "Proxy Test",
      language: "en-US",
      type: "public",
      encoding: "UTF-8",
      links: [link],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/"}], inputs: %{}, rows: %{selector: "tr"}, fields: %{}},
      follow_redirect: false
    }
  end

  @params %{query_params: %{}, headers: [], method: :get}

  describe "native engine" do
    test "a proxy that wants credentials is named in the error" do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy(proxy.port)

      assert {:error, %Error{type: :connection_failed, message: message}} =
               CardigannSearchEngine.execute_http_request(
                 parsed("https://tracker.example.test/"),
                 "https://tracker.example.test/",
                 @params,
                 %{},
                 %{}
               )

      assert message == "proxy 127.0.0.1:#{proxy.port} requires authentication"
    end

    test "the download path names the proxy too" do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy(proxy.port)

      assert {:error, %Error{message: message}} =
               CardigannSearchEngine.execute_download_request(
                 parsed("https://tracker.example.test/"),
                 "https://tracker.example.test/dl/1",
                 @params,
                 %{},
                 %{}
               )

      assert message == "proxy 127.0.0.1:#{proxy.port} requires authentication"
    end

    test "without a proxy a dead port keeps the original message" do
      assert {:error, %Error{message: "Connection failed: " <> _}} =
               CardigannSearchEngine.execute_http_request(
                 parsed("http://localhost:1/"),
                 "http://localhost:1/",
                 @params,
                 %{},
                 %{}
               )
    end
  end

  describe "health check" do
    test "the homepage probe names the proxy" do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy(proxy.port)

      assert {:error, status} =
               CardigannHealthCheck.probe_candidates(parsed("https://tracker.example.test/"), %{})

      assert [%{"error" => error}] = Map.values(status)
      assert error == "proxy 127.0.0.1:#{proxy.port} requires authentication"
    end
  end
end
