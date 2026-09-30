defmodule Mydia.Plugins.BundledManifestRoundtripTest do
  # async: false — activates the real bundled plugins under the app-wide registries.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "plex"

  setup do
    Registry.clear()
    original_runtime = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:mydia, :runtime_config, original_runtime)
      else
        Application.delete_env(:mydia, :runtime_config)
      end

      Enum.each(Registry.list(), &Host.stop_plugin(&1.slug))
      Registry.clear()
    end)

    :ok
  end

  defp assert_plex_descriptor do
    assert :ok = Plugins.register_plugins()
    assert {:ok, plugin} = Registry.lookup(@slug)
    assert plugin.setup
    assert plugin.multi_instance
    assert plugin.category == "media_server"
    assert plugin.delivery == :durable
    assert plugin.connection["type"] == "none"
    assert Mydia.Plugins.Manifest.auth_header(plugin.connection) == {"X-Plex-Token", "{token}"}
  end

  test "a freshly seeded bundled plugin keeps its 1.5 fields when activated from the row" do
    assert :ok = Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug(@slug)
    assert config.manifest["setup"] == true
    assert config.manifest["multi_instance"] == true
    assert config.manifest["category"] == "media_server"

    assert_plex_descriptor()
  end

  test "a stale bundled row is refreshed from the shipped manifest" do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Plex",
        version: "0.0.1",
        source_url: "bundled",
        enabled: true,
        granted_capabilities: %{},
        settings: %{"delivery" => "inline"},
        manifest: %{
          "slug" => @slug,
          "name" => "Plex",
          "version" => "0.0.1",
          "capabilities" => %{"events:subscribe" => ["media_file.imported"]}
        }
      })

    assert :ok = Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug(@slug)
    assert config.manifest["setup"] == true
    assert config.settings["delivery"] == "durable"

    assert_plex_descriptor()
  end
end
