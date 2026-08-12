defmodule Mydia.Plugins.BootConfigConnectionsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Config.Schema
  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Settings

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
  end

  defp with_boot_side_effects do
    previous = Application.get_env(:mydia, :start_health_monitors, true)
    Application.put_env(:mydia, :start_health_monitors, true)
    on_exit(fn -> Application.put_env(:mydia, :start_health_monitors, previous) end)
  end

  defp install_srv! do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "srv",
        name: "Srv",
        version: "1.0.0",
        source_url: "test"
      })

    :ok
  end

  defp declare_srv_connection do
    inject_runtime_plugin_installs([
      %{
        slug: "srv",
        name: "Srv",
        version: "1.0.0",
        connections: [%{label: "Living room", url: "http://10.0.0.6:8096", token: "t"}]
      }
    ])
  end

  test "register_plugins/0 seeds config-declared connections into the database" do
    declare_srv_connection()
    install_srv!()
    with_boot_side_effects()

    Plugins.register_plugins()

    assert [conn] = Connections.list_instance_for_plugin("srv")
    assert conn.label == "Living room"
    assert conn.base_urls == ["http://10.0.0.6:8096"]
    assert conn.access_token == "t"
  end

  test "seeding is idempotent across repeated boots" do
    declare_srv_connection()
    install_srv!()
    with_boot_side_effects()

    Plugins.register_plugins()
    Plugins.register_plugins()

    assert length(Connections.list_instance_for_plugin("srv")) == 1
  end

  test "no seeding happens when boot side effects are disabled" do
    declare_srv_connection()
    install_srv!()
    Application.put_env(:mydia, :start_health_monitors, false)

    Plugins.register_plugins()

    assert Connections.list_instance_for_plugin("srv") == []
  end
end
