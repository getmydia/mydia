defmodule Mydia.Settings.RuntimeConfigTest do
  use Mydia.DataCase, async: false

  alias Mydia.Config.Schema
  alias Mydia.Plugins.Connections
  alias Mydia.Settings
  alias Mydia.Settings.RuntimeConfig

  defp inject_runtime_plugin_installs(installs) do
    base = Schema.defaults()

    structs =
      Enum.map(installs, fn attrs ->
        connections =
          Enum.map(attrs[:connections] || [], &struct(Schema.PluginInstall.PluginConnection, &1))

        struct(Schema.PluginInstall, Map.put(attrs, :connections, connections))
      end)

    config = %{base | plugin_installs: structs}
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

  describe "get_runtime_plugins/0" do
    test "includes config connections flagged read-only" do
      inject_runtime_plugin_installs([
        %{
          slug: "jellyfin",
          name: "Jellyfin",
          version: "1.0.0",
          connections: [
            %{label: "Living room", url: "http://10.0.0.6:8096", token: "t"}
          ]
        }
      ])

      assert [plugin] = RuntimeConfig.get_runtime_plugins()
      assert [conn] = plugin.connections
      assert conn.label == "Living room"
      assert conn.url == "http://10.0.0.6:8096"
      assert conn.token == "t"
      assert conn.from_config? == true
    end
  end

  describe "instance_connections_for_plugin/1" do
    test "marks config-sourced DB rows read-only and surfaces config-only rows" do
      inject_runtime_plugin_installs([
        %{
          slug: "srv",
          name: "Srv",
          version: "1.0.0",
          connections: [
            %{label: "Living room", url: "http://10.0.0.6:8096", token: "t"},
            %{label: "Bedroom", url: "http://10.0.0.7:8096", token: "t2"}
          ]
        }
      ])

      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "srv",
          name: "Srv",
          version: "1.0.0",
          source_url: "test"
        })

      {:ok, _} =
        Connections.upsert("srv", %{
          scope: "instance",
          label: "Living room",
          base_urls: ["http://old.test"],
          access_token: "old"
        })

      connections = RuntimeConfig.instance_connections_for_plugin("srv")
      assert length(connections) == 2

      living_room = Enum.find(connections, &(&1.label == "Living room"))
      bedroom = Enum.find(connections, &(&1.label == "Bedroom"))

      assert living_room.from_config? == true
      assert living_room.base_urls == ["http://10.0.0.6:8096"]
      assert bedroom.from_config? == true
      assert bedroom.base_urls == ["http://10.0.0.7:8096"]
    end
  end

  describe "sync_plugin_connections_from_config/0" do
    test "upserts config connections for an installed plugin" do
      inject_runtime_plugin_installs([
        %{
          slug: "srv",
          name: "Srv",
          version: "1.0.0",
          connections: [
            %{label: "Living room", url: "http://10.0.0.6:8096", token: "t"}
          ]
        }
      ])

      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "srv",
          name: "Srv",
          version: "1.0.0",
          source_url: "test"
        })

      assert RuntimeConfig.sync_plugin_connections_from_config() == 1

      assert [conn] = Connections.list_instance_for_plugin("srv")
      assert conn.label == "Living room"
      assert conn.base_urls == ["http://10.0.0.6:8096"]
      assert conn.access_token == "t"
    end
  end
end
