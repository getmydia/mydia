defmodule Mydia.Plugins.HostFunctionsEndpointsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @slug "endpoint_host_tester"

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: @slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => @slug,
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["media_item.added"], "net:http" => []}
        },
        granted_capabilities: %{"net:http" => []},
        enabled: true
      })

    plugin = %Plugin{
      slug: @slug,
      name: @slug,
      enabled: true,
      granted_capabilities: %{"net:http" => []}
    }

    {:ok, instance} = Instances.create(@slug, %{name: "Den"})
    {:ok, plugin: plugin, instance: instance, bypass: Bypass.open()}
  end

  defp loopback, do: fn _ -> {:ok, [{127, 0, 0, 1}]} end

  test "http_request reaches an approved private endpoint of its own instance",
       %{plugin: plugin, instance: instance, bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    {:ok, instance} =
      Instances.approve_endpoints(instance, [
        %{"scheme" => "http", "host" => "plex.lan", "port" => bypass.port}
      ])

    assert {:ok, %{"status" => 200}} =
             HostFunctions.http_request(
               plugin,
               %{"url" => "http://plex.lan:#{bypass.port}/library/sections"},
               instance: instance,
               resolver: loopback()
             )
  end

  test "http_request without the instance is denied", %{plugin: plugin, bypass: bypass} do
    assert {:error, %Error{type: :capability_denied}} =
             HostFunctions.http_request(
               plugin,
               %{"url" => "http://plex.lan:#{bypass.port}/library/sections"},
               resolver: loopback()
             )
  end

  test "an endpoint approved on a sibling instance does not leak",
       %{plugin: plugin, instance: instance, bypass: bypass} do
    {:ok, other} = Instances.create(@slug, %{name: "Office"})

    {:ok, _} =
      Instances.approve_endpoints(other, [
        %{"scheme" => "http", "host" => "plex.lan", "port" => bypass.port}
      ])

    assert {:error, %Error{type: :capability_denied}} =
             HostFunctions.http_request(
               plugin,
               %{"url" => "http://plex.lan:#{bypass.port}/"},
               instance: instance,
               resolver: loopback()
             )
  end
end
