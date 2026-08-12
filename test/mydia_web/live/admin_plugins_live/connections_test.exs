defmodule MydiaWeb.AdminPluginsLive.ConnectionsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Config.Schema
  alias Mydia.Plugins.Connections
  alias Mydia.Settings

  defp inject_runtime_connections(connections) do
    base = Schema.defaults()

    install =
      struct(Schema.PluginInstall, %{
        slug: "srv",
        name: "Srv",
        version: "1.0.0",
        connections: Enum.map(connections, &struct(Schema.PluginInstall.PluginConnection, &1))
      })

    config = %{base | plugin_installs: [install]}
    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)

    :ok
  end

  setup %{conn: conn} do
    admin = admin_user_fixture()

    {:ok, plugin} =
      Settings.create_plugin_config(%{
        slug: "srv",
        name: "Srv",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => "srv",
          "name" => "Srv",
          "version" => "1.0.0",
          "capabilities" => %{"users:connections" => []},
          "connection" => %{
            "type" => "service_endpoint",
            "scope" => "instance",
            "fields" => [
              %{"key" => "url", "label" => "Server URL"},
              %{"key" => "token", "label" => "API token", "secret" => true}
            ],
            "auth" => %{"kind" => "header", "key" => "X-Emby-Token"}
          }
        },
        granted_capabilities: %{"users:connections" => []},
        enabled: true
      })

    %{conn: log_in_user(conn, admin), plugin: plugin}
  end

  test "renders the connections section for an endpoint plugin", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    assert has_element?(view, "#plugin-connections")
    assert has_element?(view, "#connection-add")
  end

  test "adds a connection through the modal form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    view |> element("#connection-add") |> render_click()
    assert has_element?(view, "#connection-form")

    view
    |> form("#connection-form", %{
      "connection" => %{"label" => "Living room", "url" => "http://10.0.0.5:8096", "token" => "t"}
    })
    |> render_submit()

    assert [conn_row] = Connections.list_instance_for_plugin("srv")
    assert conn_row.label == "Living room"
    assert conn_row.base_urls == ["http://10.0.0.5:8096"]
    assert conn_row.auth_key == "X-Emby-Token"
  end

  test "lists an existing connection with a status badge", %{conn: conn} do
    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "Basement",
        base_urls: ["http://10.0.0.6:8096"],
        access_token: "t",
        status: "error"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    assert has_element?(view, "#connection-row-basement")
    assert has_element?(view, "#connection-row-basement .badge-error")
  end

  test "removes a connection", %{conn: conn} do
    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "Basement",
        base_urls: ["http://10.0.0.6:8096"],
        access_token: "t"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    view |> element("#connection-remove-basement") |> render_click()

    assert Connections.list_instance_for_plugin("srv") == []
  end

  test "hides test and edit actions for config-sourced connections", %{conn: conn} do
    inject_runtime_connections([
      %{label: "Living room", url: "http://10.0.0.6:8096", token: "t"}
    ])

    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    assert has_element?(view, "#connection-row-living-room")
    assert render(view) =~ "http://10.0.0.6:8096"
    refute has_element?(view, "#connection-row-living-room button[phx-click=\"connection:test\"]")
    refute has_element?(view, "#connection-row-living-room button[phx-click=\"connection:edit\"]")
    refute has_element?(view, "#connection-remove-living-room")
  end

  test "overlays config url on a stale DB row for display", %{conn: conn} do
    inject_runtime_connections([
      %{label: "Living room", url: "http://10.0.0.6:8096", token: "t"}
    ])

    {:ok, _} =
      Connections.upsert("srv", %{
        scope: "instance",
        label: "Living room",
        base_urls: ["http://old.test"],
        access_token: "old"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/plugins/srv")

    assert render(view) =~ "http://10.0.0.6:8096"
    refute render(view) =~ "http://old.test"
  end
end
