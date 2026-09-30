defmodule Mydia.Plugins.EndpointsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Endpoints
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @slug "endpoints_tester"

  setup do
    {:ok, _config} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: @slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => @slug,
          "version" => "1.0.0",
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["plex.tv"]
          },
          "settings_schema" => [
            %{"key" => "url", "label" => "URL", "type" => "url", "grants_host" => true},
            %{"key" => "note", "label" => "Note", "type" => "string"}
          ]
        },
        granted_capabilities: %{"net:http" => ["plex.tv"]},
        enabled: true
      })

    plugin = %Plugin{
      slug: @slug,
      name: @slug,
      enabled: true,
      granted_capabilities: %{"net:http" => ["plex.tv"]}
    }

    {:ok, plugin: plugin}
  end

  describe "from_url/1" do
    test "fills the scheme's default port" do
      assert {:ok, %{"scheme" => "https", "host" => "plex.tv", "port" => 443}} =
               Endpoints.from_url("https://plex.tv/api")
    end

    test "keeps an explicit port and downcases the host" do
      assert {:ok, %{"scheme" => "http", "host" => "plex.lan", "port" => 32400}} =
               Endpoints.from_url("http://PLEX.lan:32400")
    end

    test "rejects non-http schemes and garbage" do
      assert :error = Endpoints.from_url("ftp://plex.lan")
      assert :error = Endpoints.from_url("not a url")
    end
  end

  describe "effective/2 and gate_opts/2" do
    test "with no instance only the granted hosts apply", %{plugin: plugin} do
      assert Endpoints.effective(plugin, nil) == []

      assert Endpoints.gate_opts(plugin, nil) ==
               [allowed_hosts: ["plex.tv"], approved_endpoints: []]
    end

    test "unions approved endpoints with the instance's host-granting settings",
         %{plugin: plugin} do
      {:ok, instance} =
        Instances.create(@slug, %{
          name: "Living room",
          settings: %{"url" => "http://192.168.1.20:32400", "note" => "http://ignored.test"}
        })

      {:ok, instance} =
        Instances.approve_endpoints(instance, [
          %{"scheme" => "https", "host" => "1-2-3-4.abc.plex.direct", "port" => 32400}
        ])

      endpoints = Endpoints.effective(plugin, instance)

      assert %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400} in endpoints

      assert %{"scheme" => "https", "host" => "1-2-3-4.abc.plex.direct", "port" => 32400} in endpoints

      refute Enum.any?(endpoints, &(&1["host"] == "ignored.test"))

      assert Keyword.fetch!(Endpoints.gate_opts(plugin, instance), :allowed_hosts) == ["plex.tv"]
    end

    test "another instance's endpoints are not included", %{plugin: plugin} do
      {:ok, a} =
        Instances.create(@slug, %{name: "A", settings: %{"url" => "http://10.0.0.5:32400"}})

      {:ok, b} = Instances.create(@slug, %{name: "B", settings: %{}})

      assert Endpoints.effective(plugin, b) == []
      assert [%{"host" => "10.0.0.5"}] = Endpoints.effective(plugin, a)
    end
  end
end
