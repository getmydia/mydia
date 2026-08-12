defmodule Mydia.Plugins.ServiceEndpointIntegrationTest do
  # async: false — starts a real pool under the app-wide PoolRegistry and seeds
  # rows the connected invocation reads (Postgres sandbox rule).
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.Connect
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "endpoint_fixture"

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "support",
             "fixtures",
             "plugins",
             "endpoint_fixture.wasm"
           ])

  defp guest_wasm, do: File.read!(@fixture)

  defp install_and_start!(grants) do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Endpoint Fixture",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => "Endpoint Fixture",
          "version" => "1.0.0",
          "capabilities" => %{
            "users:connections" => [],
            "surfaces:write" => ["connections"]
          }
        },
        granted_capabilities: grants,
        enabled: true
      })

    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Endpoint Fixture",
        granted_capabilities: grants,
        enabled: true
      })

    on_exit(fn -> Registry.unregister(@slug) end)

    imports =
      HostFunctions.imports_for(@slug,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
        probe: fn _ -> :ok end
      )

    {:ok, _pid} = Host.start_plugin(@slug, guest_wasm(), imports: imports)
    on_exit(fn -> Host.stop_plugin(@slug) end)

    :ok
  end

  test "on_event reaches a private Bypass through a relative URL without net:http" do
    install_and_start!(%{"users:connections" => []})

    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "GET", "/ping", fn conn ->
      send(test_pid, {:ping_headers, Plug.Conn.get_req_header(conn, "x-test-token")})
      Plug.Conn.resp(conn, 200, "")
    end)

    {:ok, _conn} =
      Connections.upsert(@slug, %{
        scope: "instance",
        label: "srv",
        base_urls: ["http://127.0.0.1:#{bypass.port}"],
        access_token: "discovered-token",
        auth_kind: "header",
        auth_key: "X-Test-Token"
      })

    assert {:ok, %{"hits" => 1}} =
             Host.call(@slug, "handle", %{"event" => "probe", "metadata" => %{}})

    assert_received {:ping_headers, ["discovered-token"]}
  end

  test "on_event is denied without users:connections" do
    install_and_start!(%{"events:subscribe" => ["media_item.added"]})

    assert {:error, %Error{type: :guest_error, message: msg}} =
             Host.call(@slug, "handle", %{"event" => "probe", "metadata" => %{}})

    assert msg =~ "capability_denied" or msg =~ "users:connections"
  end

  test "Connect.start then Connect.poll upserts an instance connection" do
    install_and_start!(%{
      "users:connections" => [],
      "surfaces:write" => ["connections"]
    })

    assert {:ok, pending} = Connect.start(@slug)
    assert pending.status == :pending
    assert pending.code == "TEST-CODE"

    assert {:ok, done} = Connect.poll(pending.id)
    assert done.status == :done
    assert done.message == "Connected"

    conn = Connections.get_by_label(@slug, nil, "Discovered")
    assert conn.base_urls == ["http://10.0.0.9:9999"]
    assert conn.access_token == "discovered-token"
  end

  test "connection-upsert is denied without surfaces:write connections" do
    install_and_start!(%{"users:connections" => []})

    assert {:ok, pending} = Connect.start(@slug)

    assert {:error, %Error{type: :guest_error, message: msg}} = Connect.poll(pending.id)
    assert msg =~ "capability_denied" or msg =~ "connections"
    refute Connections.get_by_label(@slug, nil, "Discovered")
  end
end
