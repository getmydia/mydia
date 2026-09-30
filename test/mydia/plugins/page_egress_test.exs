defmodule Mydia.Plugins.PageEgressTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin

  setup do
    bypass = Bypass.open()
    Bypass.stub(bypass, "POST", "/v1/chat", fn conn -> Plug.Conn.resp(conn, 200, "{}") end)
    {:ok, bypass: bypass}
  end

  defp plugin(granted),
    do: %Plugin{slug: "egress", name: "E", granted_capabilities: granted, enabled: true}

  # Every name resolves to loopback, so the private-range check is what decides.
  defp resolver, do: fn _host -> {:ok, [{127, 0, 0, 1}]} end

  defp request(port),
    do: %{"url" => "http://lan-box:#{port}/v1/chat", "method" => "POST", "body" => "{}"}

  test "a net:private host may resolve to a private address", %{bypass: bypass} do
    p = plugin(%{"net:http" => ["lan-box"], "net:private" => ["lan-box"]})

    assert {:ok, %{"status" => 200}} =
             HostFunctions.http_request(p, request(bypass.port), resolver: resolver())
  end

  test "a net:http host without net:private is still blocked", %{bypass: bypass} do
    p = plugin(%{"net:http" => ["lan-box"]})

    assert {:error, %{type: :blocked}} =
             HostFunctions.http_request(p, request(bypass.port), resolver: resolver())
  end

  test "net:private for another host does not exempt this one", %{bypass: bypass} do
    p = plugin(%{"net:http" => ["lan-box"], "net:private" => ["other-box"]})

    assert {:error, %{type: :blocked}} =
             HostFunctions.http_request(p, request(bypass.port), resolver: resolver())
  end

  test "page_http_opts uses the page budget" do
    assert HostFunctions.page_http_opts() == [timeout: 90_000, max_bytes: 4_194_304]
  end
end
